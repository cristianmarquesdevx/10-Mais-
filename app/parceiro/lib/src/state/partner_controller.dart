import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:geolocator/geolocator.dart' show LocationAccuracy;

import '../api/client.dart';
import '../api/presence_api.dart';
import '../location/location_service.dart';

/// Estado operacional do parceiro (SPECS §5.3): OFFLINE | ONLINE | PAUSED | EM_CORRIDA.
/// PAUSADO: motorista indisponível para novas ofertas, por tempo limitado (máx. 3h,
/// configurável), com tempo baseado no relógio do servidor (A7).
enum PartnerStatus { offline, online, paused, emCorrida }

/// Máquina de estado do parceiro: fonte única para P2 (painel), P3 (oferta)
/// e P4 (em corrida). Realtime é o canal primário de ofertas/estado; o poll
/// é fallback (contrato: /offers/mine "pull fallback") — nunca polling de
/// ETA (SPECS §4).
class PartnerController extends ChangeNotifier with WidgetsBindingObserver {
  PartnerController(
    this.api, {
    this.pollInterval = const Duration(seconds: 5),
    this.maxBreakMinutes = 180, // pausa máxima: 3 horas (configurável)
    PresenceApi? presence,
    LocationService location = const LocationService(),
  })  : _presence = presence ?? PresenceApi(),
        _location = location {
    WidgetsBinding.instance.addObserver(this);
  }

  final ApiClient api;
  final Duration pollInterval;
  final int maxBreakMinutes;

  /// Presença real (radar): status + posição publicados no backend.
  final PresenceApi _presence;
  final LocationService _location;
  GeoPoint? _lastPosition;
  Timer? _heartbeat;

  PartnerStatus status = PartnerStatus.offline;
  Me? me;
  Ride? ride; // corrida ativa (EM_CORRIDA)
  List<Offer> offers = [];
  bool busy = false;
  String? lastErrorCode; // decisão de UI por code (problem+json)

  // --- pausa ---
  DateTime? _breakStartedAt; // horário de início da pausa (relógio do servidor)
  DateTime? _breakExpiresAt; // horário de expiração da pausa (servidor)

  Timer? _poll;
  Timer? _breakTimer; // atualiza o cronômetro de pausa localmente
  int _backoffStep = 0;

  bool get kycApproved => me?.partner?.canGoOnline ?? false;
  String? get mode => me?.partner?.monetizationMode;

  /// Tipos de solicitação ligados ("Configurar solicitações"). Começa com o
  /// mesmo default do servidor até a primeira leitura.
  Set<String> servicePrefs = {'MOTO', 'MOTO_NEGOCIA'};

  /// Piso por corrida: o despacho não envia oferta abaixo deste valor.
  double minFare = 0;
  bool prefsLoaded = false;

  Future<void> loadPreferences() => _guard(() async {
        final prefs = await api.partnerPreferences();
        servicePrefs = prefs.services;
        minFare = prefs.minFare;
        prefsLoaded = true;
      });

  /// Grava a escolha inteira (PUT substitui a lista). Devolve false se o
  /// servidor recusou — a tela reverte o switch e mostra o motivo.
  /// [minFare] só vai quando alterado; ligar/desligar um tipo preserva o piso.
  Future<bool> savePreferences(Set<String> services, {double? minFare}) async {
    var ok = false;
    await _guard(() async {
      final prefs = await api.savePartnerPreferences(services, minFare: minFare);
      servicePrefs = prefs.services;
      this.minFare = prefs.minFare;
      ok = true;
    });
    return ok;
  }

  /// Motorista em pausa ativa?
  bool get isPaused => status == PartnerStatus.paused;

  /// Tempo decorrido da pausa (segundos), baseado no _breakStartedAt do servidor.
  /// Retorna null se não houver pausa ativa.
  int? get breakElapsedSeconds {
    if (_breakStartedAt == null) return null;
    return DateTime.now().difference(_breakStartedAt!).inSeconds;
  }

  /// Tempo restante da pausa (segundos), baseado no _breakExpiresAt do servidor.
  /// Retorna null se não houver pausa ativa ou se já expirou.
  int? get breakRemainingSeconds {
    if (_breakExpiresAt == null) return null;
    final remaining = _breakExpiresAt!.difference(DateTime.now()).inSeconds;
    return remaining > 0 ? remaining : 0;
  }

  /// Tempo máximo de pausa em segundos.
  int get breakLimitSeconds => maxBreakMinutes * 60;

  Future<void> _guard(Future<void> Function() action) async {
    busy = true;
    lastErrorCode = null;
    notifyListeners();
    try {
      await action();
    } on ApiProblem catch (p) {
      lastErrorCode = p.code;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> loadMe() => _guard(() async {
        me = await api.me();
      });

  /// P2 → ONLINE. 403 kyc_not_approved vira lastErrorCode (tela leva ao
  /// onboarding); servidor manda (nunca confiar no gate local).
  Future<void> goOnline({GeoPoint? position}) => _guard(() async {
        // Sem posição real o parceiro não pode ser encontrado pelo radar;
        // a tela mostra "localização indisponível" em vez de fingir online.
        var at = position;
        if (at == null) {
          final fix = await _location.tryCurrent();
          if (fix == null) {
            lastErrorCode = 'location_unavailable';
            return;
          }
          at = GeoPoint(fix.lat, fix.lon);
        }
        final r = await api.goOnline(
          lat: at.lat,
          lon: at.lon,
        );
        status = PartnerStatus.online;
        _lastPosition = at;
        _clearBreak(); // encerra qualquer pausa ao voltar online
        if (me?.partner != null) {
          final p = me!.partner!;
          me = Me(
            userId: me!.userId,
            role: me!.role,
            partner: PartnerInfo(
              kycStatus: p.kycStatus,
              monetizationMode: (r['mode'] as String?) ?? p.monetizationMode,
              passExpiresAt: r['pass_expires_at'] != null
                  ? DateTime.parse(r['pass_expires_at'] as String)
                  : p.passExpiresAt,
              walletBalance: p.walletBalance,
              debtCents: p.debtCents,
            ),
          );
        }
        _startPolling();
        await refreshOffers();
        // Só depois do sucesso da API: publica a presença que o radar lê.
        await _publishPresence('ONLINE_DISPONIVEL', at: at);
        _startHeartbeat();
      });

  Future<void> goOffline() => _guard(() async {
        await _publishPresence('OFFLINE');
        await api.goOffline();
        status = PartnerStatus.offline;
        offers = [];
        _lastPosition = null;
        _heartbeat?.cancel();
        _heartbeat = null;
        _clearBreak();
        _stopPolling();
      });

  /// Publica status/posição no radar. Falhas não derrubam a operação, mas
  /// deixam um code na tela — o parceiro precisa saber que pode não aparecer.
  Future<bool> _publishPresence(String status, {GeoPoint? at}) async {
    // A presença principal já vai no POST /partner/online (com lat/lon), que
    // é o que o radar do passageiro lê. A Edge Function dedicada (RADAR_BASE)
    // é opcional: sem ela não é erro, e a tela não mostra código cru.
    if (!_presence.configured) return true;
    try {
      await _presence.setStatus(status, lat: at?.lat, lon: at?.lon);
      return true;
    } on PresenceProblem catch (p) {
      lastErrorCode = p.code == 'presence_unconfigured'
          ? 'presence_unconfigured'
          : 'presence_error';
      return false;
    } catch (_) {
      lastErrorCode = 'presence_error';
      return false;
    }
  }

  /// Heartbeat de 30 s (SPECS: PRM-hb.intervalo + grace de 90 s no servidor).
  /// Sem posição nova, o servidor deixa de mostrar o parceiro no radar.
  ///
  /// O POST /partner/heartbeat é o que mantém a presença fresca: o
  /// `/partner/online` marca o instante da conexão, mas o despacho só considera
  /// quem deu sinal de vida nos últimos 90 s. Sem este envio o parceiro
  /// desaparece do radar e para de receber ofertas em ~1,5 min.
  void _startHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(const Duration(seconds: 30), (_) async {
      if (_disposed || status != PartnerStatus.online) return;
      final fix = await _location.tryCurrent(
        timeout: const Duration(seconds: 6),
        accuracy: LocationAccuracy.medium,
      );
      // Sem leitura nova (GPS parado/instável) vale a última posição: o
      // parceiro continua online no lugar onde estava — o que expira em 90 s
      // é o sinal de vida, não a coordenada.
      final at = fix != null
          ? GeoPoint(fix.lat, fix.lon)
          : _lastPosition;
      if (at == null) return;
      _lastPosition = at;
      // Presença no servidor principal (obrigatória) e, quando configurada,
      // a Edge Function opcional do radar.
      try {
        await api.heartbeat([
          {'lat': at.lat, 'lon': at.lon},
        ]);
      } catch (_) {
        // Rede oscilou: o próximo pulso tenta de novo; não derruba o ONLINE.
      }
      await _publishPresence('ONLINE_DISPONIVEL', at: at);
    });
  }

  /// Volta ao radar com uma leitura fresca (após pausa ou fim de corrida).
  Future<void> _resumePresence() async {
    final fix = await _location.tryCurrent(
      timeout: const Duration(seconds: 6),
      accuracy: LocationAccuracy.medium,
    );
    final at = fix != null ? GeoPoint(fix.lat, fix.lon) : _lastPosition;
    if (at == null) return;
    _lastPosition = at;
    await _publishPresence('ONLINE_DISPONIVEL', at: at);
    _startHeartbeat();
  }

  /// Inicia uma pausa de até [maxBreakMinutes] (default 3h).
  /// O servidor é a fonte oficial do horário de início e expiração (A7).
  Future<void> startBreak() async {
    if (!kycApproved) {
      lastErrorCode = 'kyc_not_approved';
      notifyListeners();
      return;
    }
    if (status == PartnerStatus.emCorrida) {
      lastErrorCode = 'em_corrida';
      notifyListeners();
      return;
    }
    await _guard(() async {
      final r = await api.startBreak(minutes: maxBreakMinutes);
      status = PartnerStatus.paused;
      _heartbeat?.cancel();
      _heartbeat = null;
      await _publishPresence('PAUSA', at: _lastPosition);
      _breakStartedAt = r['started_at'] != null
          ? DateTime.parse(r['started_at'] as String)
          : DateTime.now();
      _breakExpiresAt = r['expires_at'] != null
          ? DateTime.parse(r['expires_at'] as String)
          : _breakStartedAt!.add(Duration(minutes: maxBreakMinutes));
      _startBreakTimer();
      notifyListeners();
    });
  }

  /// Encerra a pausa antecipadamente e volta para ONLINE.
  Future<void> endBreak() async {
    if (status != PartnerStatus.paused) return;
    await _guard(() async {
      await api.endBreak();
      status = PartnerStatus.online;
      _clearBreak();
      _startPolling();
      await refreshOffers();
      await _resumePresence();
      notifyListeners();
    });
  }

  /// Limpa o estado de pausa (chamado ao ir offline ou online).
  void _clearBreak() {
    _breakStartedAt = null;
    _breakExpiresAt = null;
    _breakTimer?.cancel();
    _breakTimer = null;
  }

  bool _disposed = false;
  static const _maxPoll = Duration(seconds: 30);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // App voltou ao foreground: o Android pode ter suspenso o timer. Recarrega
    // ofertas e religa o poll para não perder a janela de 15 s da oferta.
    if (state == AppLifecycleState.resumed && status == PartnerStatus.online) {
      refreshOffers();
      _startPolling();
    }
  }

  /// Atualiza o cronômetro de pausa a cada segundo (apenas UI local; o
  /// servidor continua sendo a fonte oficial).
  void _startBreakTimer() {
    _breakTimer?.cancel();
    _breakTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_disposed) return;
      if (status != PartnerStatus.paused) {
        _breakTimer?.cancel();
        _breakTimer = null;
        return;
      }
      // Se expirou conforme o servidor, volta para online automaticamente.
      if (_breakExpiresAt != null && DateTime.now().isAfter(_breakExpiresAt!)) {
        status = PartnerStatus.online;
        _clearBreak();
        _startPolling();
        notifyListeners();
      } else {
        notifyListeners();
      }
    });
  }

  Future<void> refreshOffers() => _guard(() async {
        if (status != PartnerStatus.online) return;
        offers = await api.myOffers();
      });

  /// P3 → aceita (primeiro a aceitar vence, atomic no servidor) → EM_CORRIDA.
  Future<void> accept(String offerId, {required String rideId}) =>
      _guard(() async {
        await api.acceptOffer(offerId);
        offers = [];
        status = PartnerStatus.emCorrida;
        ride = await api.ride(rideId);
        _stopPolling(); // sem ofertas em corrida; estado via transições
        _clearBreak();
        // Em corrida o parceiro não está disponível para novas chamadas.
        _heartbeat?.cancel();
        _heartbeat = null;
        _lastPosition = null;
        await _publishPresence('OFFLINE');
      });

  /// Recusa: devolve o que foi perdido (valor congelado + aceite antes/depois)
  /// para a tela explicar a consequência. `null` se o servidor não informar.
  Future<OfferLoss?> decline(String offerId) async {
    OfferLoss? loss;
    await _guard(() async {
      loss = await api.declineOffer(offerId);
      offers = offers.where((o) => o.offerId != offerId).toList();
    });
    return loss;
  }

  /// Fechamento de uma oferta que sumiu da lista (timeout de 15 s).
  Future<OfferLoss?> offerOutcome(String offerId) async {
    try {
      return await api.offerOutcome(offerId);
    } on ApiProblem {
      return null; // sem explicação, a tela só volta ao painel
    }
  }

  /// P4/P5 — única via de transição (0002: função de domínio). Sucesso
  /// refaz o estado no servidor; 409 illegal_transition fica no code.
  Future<void> transition({
    required String to,
    double? fareTotal,
    bool? cashDeclared,
  }) =>
      _guard(() async {
        if (ride == null) return;
        await api.transition(
          rideId: ride!.rideId,
          to: to,
          fareTotal: fareTotal,
          cashDeclared: cashDeclared,
        );
        ride = await api.ride(ride!.rideId);
        if (ride!.status == RideStatus.finalizada || !ride!.status.isOpen) {
          status = PartnerStatus.online;
          ride = null;
          _startPolling();
          await _resumePresence();
        }
      });

  // --- poll de fallback (backoff só em erro; Realtime manda) --------------
  //
  // Um Timer encadeado: o sucesso mantém o intervalo curto (a oferta dura
  // 15 s no servidor — backoff em sucesso faria o parceiro perder ofertas),
  // e só falhas de rede aumentam a espera. Uma exceção nunca mata o ciclo.
  void _startPolling() {
    _stopPolling();
    _backoffStep = 0;
    _scheduleTick(pollInterval);
  }

  void _scheduleTick(Duration delay) {
    _poll?.cancel();
    _poll = Timer(delay, () async {
      if (_disposed || status != PartnerStatus.online) return _stopPolling();
      var failed = false;
      try {
        offers = await api.myOffers();
        lastErrorCode = null;
      } on ApiProblem catch (p) {
        lastErrorCode = p.code;
        failed = true;
      } catch (_) {
        lastErrorCode = 'offline'; // banner ADX-UX-3
        failed = true;
      }
      if (_disposed || status != PartnerStatus.online) return _stopPolling();
      notifyListeners();
      _backoffStep = failed ? (_backoffStep + 1).clamp(0, 3) : 0;
      final next = pollInterval * (1 << _backoffStep);
      _scheduleTick(next > _maxPoll ? _maxPoll : next);
    });
  }

  void _stopPolling() {
    _poll?.cancel();
    _poll = null;
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _stopPolling();
    _heartbeat?.cancel();
    _breakTimer?.cancel();
    super.dispose();
  }
}
