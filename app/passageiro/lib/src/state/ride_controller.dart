import 'dart:async';

import 'package:flutter/widgets.dart';

import '../api/client.dart';

/// Estado da corrida do passageiro: fonte única para as telas C2–C8.
/// Realtime é o canal primário; o poll (GET /rides/{id}) é só fallback com
/// backoff — nunca polling de ETA (SPECS §4 / R1).
class RideController extends ChangeNotifier with WidgetsBindingObserver {
  RideController(this.api, {this.pollInterval = const Duration(seconds: 5)}) {
    WidgetsBinding.instance.addObserver(this);
  }

  final ApiClient api;
  final Duration pollInterval;

  Ride? ride;
  String? lastErrorCode; // decisão de UI por code (problem+json)
  bool busy = false;
  double? proposedAmount; // espelho da última negociação aberta

  Timer? _poll;
  int _backoffStep = 0;
  RideStatus? _seenStatus;

  /// Teto do backoff: uma espera longa não pode virar minutos sem atualizar.
  static const _maxPoll = Duration(seconds: 30);

  Future<void> _guard(Future<void> Function() action, {String? code}) async {
    busy = true;
    lastErrorCode = null;
    notifyListeners();
    try {
      await action();
    } on ApiProblem catch (p) {
      lastErrorCode = p.code;
    } catch (_) {
      // Rede caiu / app voltou do background: não deixa a exceção matar o
      // poll nem travar a UI. O próximo tick tenta de novo (ADX-UX-3).
      lastErrorCode = 'offline';
    } finally {
      busy = false;
      notifyListeners();
    }
    assert(code == null || lastErrorCode == null || lastErrorCode == code);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Ao voltar ao foreground, o timer pode ter sido suspenso pelo Android.
    // Recarrega a corrida e religa o poll se ela ainda estiver aberta.
    if (state == AppLifecycleState.resumed) {
      refresh();
      if (ride != null && ride!.status.isOpen && _poll == null) {
        _startPolling();
      }
    }
  }

  Future<void> requestRide({
    required GeoPoint origin,
    required GeoPoint destination,
    required PricingMode mode,
    double? proposedAmount,
    String? quoteId,
    double? quotedFare,
    String? originAddress,
    String? destinationAddress,
  }) =>
      _guard(() async {
        await api.createRide(
          origin: origin,
          destination: destination,
          mode: mode,
          proposedAmount: proposedAmount,
          quoteId: quoteId,
          quotedFare: quotedFare,
          originAddress: originAddress,
          destinationAddress: destinationAddress,
        );
        this.proposedAmount = proposedAmount;
        await refresh();
        _startPolling();
      });

  Future<void> refresh() async {
    await _guard(() async {
      final active = await api.activeRide();
      if (active != null) {
        ride = active;
      } else if (ride != null && ride!.status.isOpen) {
        // A corrida saiu do conjunto "ativa" mas o cache ainda diz aberta:
        // o estado terminal só vem por GET /rides/{id} (contrato: poll
        // fallback). Sem isto o poll nunca vê FINALIZADA e a UI trava.
        ride = await api.ride(ride!.rideId);
      }
    });
    // Abrir o app com corrida em andamento (deep link F4) também precisa de
    // poll: o `refresh()` do initState não passa por `requestRide`.
    if (ride != null && ride!.status.isOpen && _poll == null) _startPolling();
  }

  /// Cancela a corrida/busca. Retorna true se o cancelamento foi processado
  /// com sucesso (incluindo se a corrida já estava cancelada pelo servidor —
  /// idempotência contra condições de corrida).
  Future<bool> cancel(String reason) async {
    _stopPolling();
    if (ride == null) return true;
    try {
      await api.cancelRide(ride!.rideId, reason);
      ride = null;
      notifyListeners();
      return true;
    } on ApiProblem catch (p) {
      lastErrorCode = p.code;
      notifyListeners();
      if (p.code == 'ride_already_closed') {
        ride = null;
        notifyListeners();
        return true;
      }
      return false;
    }
  }

  Future<void> propose(double amount) => _guard(() async {
        if (ride == null) return;
        await api.negotiate(ride!.rideId, amount: amount, kind: 'PROPOSE');
        proposedAmount = amount;
        await refresh();
      });

  Future<void> counter(double amount) => _guard(() async {
        if (ride == null) return;
        await api.negotiate(ride!.rideId, amount: amount, kind: 'COUNTER');
        proposedAmount = amount;
        await refresh();
      });

  Future<Uri?> share() async {
    if (ride == null) return null;
    try {
      return await api.shareRide(ride!.rideId);
    } on ApiProblem catch (p) {
      lastErrorCode = p.code;
      notifyListeners();
      return null;
    }
  }

  Future<void> rate({required int stars, String? comment}) => _guard(() async {
        if (ride == null) return;
        await api.rateRide(ride!.rideId, stars: stars, comment: comment);
      });

  /// Inicia o pagamento e devolve o payload do PSP (PIX: qr/copia-e-cola).
  Future<Map<String, dynamic>?> pay(String method) async {
    Map<String, dynamic>? payload;
    await _guard(() async {
      if (ride == null) return;
      payload = await api.startRidePayment(ride!.rideId, method);
    });
    return payload;
  }

  /// Confirma o pagamento no servidor (PIX: o PSP é a fonte da verdade).
  /// Só devolve true quando o backend responde `payment_status=CONFIRMED`.
  Future<bool> confirmPayment() async {
    var confirmed = false;
    await _guard(() async {
      if (ride == null) return;
      final updated = await api.confirmRidePayment(ride!.rideId);
      ride = updated;
      confirmed = updated.paymentStatus == 'CONFIRMED';
    });
    return confirmed && lastErrorCode == null;
  }

  Future<void> sos() =>
      _guard(() => api.openTicket(priority: 'EMERGENCY', rideId: ride?.rideId));

  // --- poll de fallback (backoff exponencial até 30 s; Realtime manda) ----
  //
  // Um único Timer encadeado: cada tick agenda o próximo. A versão anterior
  // se cancelava dentro do próprio callback (Timer.periodic + cancel + novo
  // timer) e o poll morria no primeiro tick — a tela ficava "Procurando
  // parceiro" para sempre mesmo com a corrida já ACEITA ou FINALIZADA.
  void _startPolling() {
    _stopPolling();
    _backoffStep = 0;
    _seenStatus = ride?.status;
    _scheduleTick(pollInterval);
  }

  void _scheduleTick(Duration delay) {
    _poll?.cancel();
    _poll = Timer(delay, () async {
      if (ride == null || !ride!.status.isOpen) return _stopPolling();
      try {
        await refresh();
      } catch (_) {
        // Mantém o ciclo vivo: uma falha de rede não pode congelar a tela.
      }
      if (ride == null || !ride!.status.isOpen) return _stopPolling();
      final status = ride!.status;
      if (status != _seenStatus) {
        // Fase mudou: reage rápido de novo em vez de continuar no backoff.
        _seenStatus = status;
        _backoffStep = 0;
      } else {
        _backoffStep = (_backoffStep + 1).clamp(0, 3);
      }
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
    WidgetsBinding.instance.removeObserver(this);
    _stopPolling();
    super.dispose();
  }
}
