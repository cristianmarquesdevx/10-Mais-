import 'package:flutter/services.dart';

/// Mantém o app do parceiro **vivo** enquanto ele está ONLINE.
///
/// O problema que isto resolve: o Android congela apps em cache. Um parceiro
/// que deixa o app em segundo plano (tela apagada, celular no bolso, esperando
/// oferta) tinha o heartbeat suspenso pelo sistema — o servidor (Postgres) só
/// considera online quem deu sinal de vida nos últimos 90 s, então o parceiro
/// sumia do radar do passageiro e parava de receber oferta, **sem aviso no
/// painel**.
///
/// O serviço em primeiro plano (Android) impede o congelamento: o processo
/// continua vivo, o isolate do Dart continua rodando e o heartbeat continua
/// batendo. O serviço não publica nada por si — quem publica a presença é o
/// app (`POST /radar/presence`).
///
/// Em web/iOS (e nos testes) não há serviço: o canal não existe, o
/// [start] devolve `false` e o app segue funcionando normalmente — só não há
/// a garantia de sobreviver em segundo plano.
class PresenceKeepAlive {
  PresenceKeepAlive({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(channelName);

  /// Nome do canal (mesmo no lado nativo: `MainActivity.CHANNEL`).
  static const channelName = 'app.dezemais.parceiro/presence';

  final MethodChannel _channel;

  bool _running = false;

  /// O serviço está ligado neste momento?
  bool get running => _running;

  /// Liga o serviço. Devolve `false` quando a plataforma não tem (ou recusou).
  Future<bool> start() async {
    if (_running) return true;
    try {
      final ok = await _channel.invokeMethod<bool>('start');
      _running = ok ?? true;
      return _running;
    } on MissingPluginException {
      // Plataforma sem o serviço (web, iOS, teste): o app segue funcionando.
      return false;
    } catch (_) {
      // Recusa do sistema (ex.: Android 14 sem permissão no momento):
      // a presença continua sendo publicada, só não há garantia de sobreviver
      // em segundo plano.
      return false;
    }
  }

  /// Desliga o serviço. Nunca lança: desligar é sempre seguro.
  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    try {
      await _channel.invokeMethod<bool>('stop');
    } catch (_) {
      // O serviço já morreu com o processo: nada a fazer.
    }
  }
}
