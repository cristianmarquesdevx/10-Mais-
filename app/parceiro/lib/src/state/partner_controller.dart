import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:geolocator/geolocator.dart' show LocationAccuracy;

import '../api/client.dart';
import '../api/presence_api.dart';
import '../api/wallet_source.dart';
import '../location/location_service.dart';
import '../services/presence_keep_alive.dart';

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
    this.heartbeatInterval = const Duration(seconds: 30),
    PresenceApi? presence,
    PresenceKeepAlive? keepAlive,
    LocationService location = const LocationService(),
    WalletBalanceSource? walletSource,
  })  : _presence = presence ?? PresenceApi(),
        _keepAlive = keepAlive ?? PresenceKeepAlive(),
        _location = location,
        _walletSourceOverride = walletSource {
    WidgetsBinding.instance.addObserver(this);
  }

  final ApiClient api;
  final Duration pollInterval;
  final int maxBreakMinutes;

  /// Intervalo do heartbeat de presença. O servidor só mostra quem deu sinal
  /// de vida nos últimos 90 s: 30 s deixa folga para três batidas.
  final Duration heartbeatInterval;

  /// Presença real (radar): status + posição publicados no backend.
  final PresenceApi _presence;

  /// Mantém o app vivo enquanto ONLINE (serviço em primeiro plano no Android).
  final PresenceKeepAlive _keepAlive;
  final LocationService _location;
  final WalletBalanceSource? _walletSourceOverride;

  /// Fonte do saldo da carteira. Poll agora; Realtime (Supabase) depois, sem
  /// mudar a tela.
  WalletBalanceSource get walletSource =>
      _walletSourceOverride ?? ApiWalletBalanceSource(api);

  GeoPoint? _lastPosition;
  Timer? _heartbeat;

  PartnerStatus status = PartnerStatus.offline;
  Me? me;
  Ride? ride; // corrida ativa (EM_CORRIDA)
  List<Offer> offers = [];
  bool busy = false;
  String? lastErrorCode; // decisão de UI por code (problem+json)

  // --- saldo da carteira (leitura contínua) -------------------------------
  //
  // O saldo é do servidor. A tela do painel liga a leitura enquanto está
  // aberta (startWalletLive) e desliga ao sair (stopWalletLive): nada fica
  // consumindo bateria em segundo plano.

  /// Último saldo conhecido (reais). Null enquanto nunca foi lido.
  double? walletBalance;

  /// Momento da última leitura bem-sucedida (relógio do aparelho).
  DateTime? walletUpdatedAt;

  /// Primeira carga em andamento — a tela mostra shimmer, nunca "—".
  bool walletLoading = true;

  /// A última leitura falhou: o valor exibido é o último conhecido.
  bool walletStale = false;

  /// Código do último erro de leitura (a UI decide o aviso discreto).
  String? walletErrorCode;

  Timer? _walletTimer;
  bool _walletLive = false;

  /// Intervalo de leitura: curto online (o saldo muda ao fechar corrida),
  /// longo offline (só para manter o valor fresco na volta).
  static const walletPollOnline = Duration(seconds: 15);
  static const walletPollOffline = Duration(seconds: 60);

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
    } on PresenceProblem catch (p) {
      // O radar (Postgres) recusa com o código do negócio — `kyc_not_approved`
      // é o que leva o parceiro de volta ao cadastro.
      lastErrorCode = _presenceCode(p.code);
    } on ApiProblem catch (p) {
      lastErrorCode = p.code;
    } catch (_) {
      // Resposta inesperada (parse/contrato) não pode derrubar a tela: as
      // chamadas daqui são fire-and-forget (ex.: loadMe no initState).
      lastErrorCode = 'offline';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Código que a tela entende, a partir do que o backend respondeu.
  ///
  /// O Postgres fala em código de negócio (`kyc_not_approved`,
  /// `not_a_partner`); a tela fala em código de UI. O resto vira
  /// `presence_error` — genérico, mas honesto.
  static String _presenceCode(String code) {
    switch (code) {
      case 'kyc_not_approved':
      case 'not_a_partner':
      case 'presence_unconfigured':
      case 'invalid_position':
      case 'location_unavailable':
        return code;
      default:
        return 'presence_error';
    }
  }

  Future<void> loadMe() => _guard(() async {
        me = await api.me();
      });

  // --- saldo da carteira (leitura contínua) -------------------------------
  //
  // O valor é sempre do servidor. A tela do painel liga a leitura enquanto
  // está aberta e desliga ao sair — nada fica consumindo bateria em segundo
  // plano.

  /// Liga a leitura contínua do saldo. Chamar quando a tela que mostra o
  /// saldo entra; desligar com [stopWalletLive] quando sair.
  void startWalletLive() {
    if (_walletLive) return;
    _walletLive = true;
    refreshWallet();
    _scheduleWalletTick(_walletInterval);
  }

  /// Desliga a leitura contínua (a tela saiu).
  void stopWalletLive() {
    _walletLive = false;
    _walletTimer?.cancel();
    _walletTimer = null;
  }

  /// Online o saldo muda com frequência (fim de corrida); offline, basta
  /// manter o valor fresco para a próxima abertura.
  Duration get _walletInterval =>
      status == PartnerStatus.online ? walletPollOnline : walletPollOffline;

  void _scheduleWalletTick(Duration delay) {
    _walletTimer?.cancel();
    if (!_walletLive || _disposed) return;
    _walletTimer = Timer(delay, () async {
      await refreshWallet();
      _scheduleWalletTick(_walletInterval);
    });
  }

  /// Lê o saldo agora. Falha não derruba a tela: o valor continua sendo
  /// exibido, marcado como antigo (stale), com o horário da última leitura.
  Future<void> refreshWallet() async {
    if (_disposed) return;
    try {
      final value = await walletSource.fetchBalance();
      if (_disposed) return;
      walletBalance = value;
      walletUpdatedAt = DateTime.now();
      walletLoading = false;
      walletStale = false;
      walletErrorCode = null;
      notifyListeners();
    } on ApiProblem catch (p) {
      if (_disposed) return;
      walletLoading = false;
      walletStale = true;
      walletErrorCode = p.code;
      notifyListeners();
    } catch (_) {
      if (_disposed) return;
      walletLoading = false;
      walletStale = true;
      walletErrorCode = 'offline';
      notifyListeners();
    }
  }

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
        // Quem publica a presença é o SERVIDOR: com o radar real (Postgres)
        // configurado, é `fn_presence_update` que decide — e pode recusar
        // (KYC pendente). Sem ele (modo demo), é a API de demonstração.
        await _publishOnline(at);
        // O estado local só muda DEPOIS do servidor aceitar: assim um 403
        // não deixa o parceiro "online" na tela e ausente do despacho.
        status = PartnerStatus.online;
        _lastPosition = at;
        _clearBreak(); // encerra qualquer pausa ao voltar online
        // Mantém o processo VIVO: sem isso o Android congela o app em segundo
        // plano, o heartbeat para e o parceiro some do radar em 90 s.
        // Não bloqueia o ONLINE: o serviço é a garantia de sobrevivência, não
        // o que publica a presença (quem publica é o servidor, acima).
        unawaited(_keepAlive.start());
        _startPolling();
        // O heartbeat ANTES da leitura de ofertas: se a leitura falhar, a
        // presença continua batendo (era o que sumia do radar).
        _startHeartbeat();
        await refreshOffers();
      });

  /// Publica o ONLINE no backend de presença.
  ///
  /// Com o radar real: `POST /radar/presence` (Postgres) — é o mesmo dado
  /// que o despacho do passageiro lê. Sem ele (modo demo): a rota
  /// `/partner/online` da API de demonstração.
  Future<void> _publishOnline(GeoPoint at) async {
    if (_presence.configured) {
      await _presence.setStatus('ONLINE_DISPONIVEL', lat: at.lat, lon: at.lon);
      return;
    }
    await api.goOnline(lat: at.lat, lon: at.lon);
  }

  Future<void> goOffline() => _guard(() async {
        if (_presence.configured) {
          await _presence.setStatus('OFFLINE');
        } else {
          await api.goOffline();
        }
        status = PartnerStatus.offline;
        offers = [];
        _lastPosition = null;
        _heartbeat?.cancel();
        _heartbeat = null;
        // Não precisa mais segurar o processo vivo: ninguém está online.
        unawaited(_keepAlive.stop());
        _clearBreak();
        _stopPolling();
      });

  /// Publica status/posição no radar. Falhas **não** são engolidas: quem
  /// chama decide se a falha derruba a operação (ficar online — o servidor
  /// recusou, o app não vira online) ou só vira aviso (heartbeat).
  Future<void> _publishPresence(String status, {GeoPoint? at}) async {
    // Sem backend de presença real não há o que publicar: quem publica é a
    // API de demonstração (rotas `/partner/*`).
    if (!_presence.configured) return;
    await _presence.setStatus(status, lat: at?.lat, lon: at?.lon);
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
    _heartbeat = Timer.periodic(heartbeatInterval, (_) async {
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
      // Presença no servidor: com o radar real é o Postgres que decide se o
      // parceiro continua visível (heartbeat fresco < 90 s). Sem ele, é a
      // rota `/partner/heartbeat` da API de demonstração.
      try {
        if (_presence.configured) {
          await _publishPresence('ONLINE_DISPONIVEL', at: at);
        } else {
          await api.heartbeat([
            {'lat': at.lat, 'lon': at.lon},
          ]);
        }
      } catch (_) {
        // Rede oscilou: o próximo pulso tenta de novo; não derruba o ONLINE.
      }
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
    try {
      await _publishPresence('ONLINE_DISPONIVEL', at: at);
    } catch (_) {
      // Melhor-esforço: o heartbeat seguinte corrige a posição.
    }
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
      DateTime startedAt;
      DateTime expiresAt;
      if (_presence.configured) {
        // Postgres: a pausa é o status PAUSA. O radar não tem "pausa até",
        // então o relógio do servidor é o do próprio heartbeat e a expiração
        // é calculada aqui, respeitando o limite configurado (3 h).
        final at = _lastPosition ?? await _currentPosition();
        if (at == null) {
          lastErrorCode = 'location_unavailable';
          return;
        }
        await _presence.setStatus('PAUSA', lat: at.lat, lon: at.lon);
        startedAt = DateTime.now();
        expiresAt = startedAt.add(Duration(minutes: maxBreakMinutes));
      } else {
        // Modo demo: a API de demonstração é quem manda no relógio da pausa.
        final r = await api.startBreak(minutes: maxBreakMinutes);
        startedAt = r['started_at'] != null
            ? DateTime.parse(r['started_at'] as String)
            : DateTime.now();
        expiresAt = r['expires_at'] != null
            ? DateTime.parse(r['expires_at'] as String)
            : startedAt.add(Duration(minutes: maxBreakMinutes));
      }
      status = PartnerStatus.paused;
      _heartbeat?.cancel();
      _heartbeat = null;
      _breakStartedAt = startedAt;
      _breakExpiresAt = expiresAt;
      _startBreakTimer();
      notifyListeners();
    });
  }

  /// Posição atual do aparelho (ou a última conhecida).
  Future<GeoPoint?> _currentPosition() async {
    final fix = await _location.tryCurrent();
    if (fix != null) return GeoPoint(fix.lat, fix.lon);
    return _lastPosition;
  }

  /// Encerra a pausa antecipadamente e volta para ONLINE.
  Future<void> endBreak() async {
    if (status != PartnerStatus.paused) return;
    await _guard(() async {
      // Com o radar real, encerrar a pausa é voltar a publicar ONLINE — não
      // existe rota de pausa no Postgres além do status.
      if (!_presence.configured) await api.endBreak();
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
      // A presença pode ter expirado enquanto o app estava congelado: o
      // servidor só mostra quem deu sinal de vida nos últimos 90 s. Volta a
      // bater assim que o app volta — antes disso o parceiro sumiria.
      _resumePresence();
    }
    // O saldo só é lido com a tela do painel aberta: em background o timer
    // é suspenso (bateria) e retomado na volta.
    if (state == AppLifecycleState.resumed && _walletLive) {
      refreshWallet();
      _scheduleWalletTick(_walletInterval);
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _walletTimer?.cancel();
      _walletTimer = null;
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
        // A pausa acabou: o parceiro volta a ser visível. No modo real a
        // presença É o status no Postgres — sem republicar ONLINE ele ficaria
        // PAUSA para sempre (e nunca receberia oferta).
        _resumePresence();
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
        // A corrida começou: o parceiro não está disponível para novas
        // chamadas. Falha ao publicar não pode desfazer o aceite.
        try {
          await _publishPresence('OFFLINE');
        } catch (_) {
          // Melhor-esforço: o servidor já sabe da corrida.
        }
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
          // A corrida credita/debita a carteira: o saldo exibido no painel
          // precisa refletir o novo valor imediatamente.
          await refreshWallet();
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
    stopWalletLive();
    // O app morreu: não faz sentido segurar o processo vivo por causa da
    // presença. `stop()` nunca lança.
    _keepAlive.stop();
    super.dispose();
  }
}
