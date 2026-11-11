import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parceiro/src/services/presence_keep_alive.dart';

/// O serviço de presença (primeiro plano) é o que impede o Android de
/// congelar o app do parceiro em segundo plano — e foi exatamente esse
/// congelamento que fazia o parceiro sumir do radar depois de 90 s.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('app.dezemais.parceiro/presence');
  final calls = <MethodCall>[];

  void mock({bool? answer}) {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    if (answer == null) {
      // Sem handler: o canal não existe (web/iOS) → MissingPluginException.
      messenger.setMockMethodCallHandler(channel, null);
      return;
    }
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return answer;
    });
  }

  setUp(() {
    calls.clear();
    mock(answer: true);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('ligar e desligar o serviço', () async {
    final keep = PresenceKeepAlive(channel: channel);

    expect(await keep.start(), isTrue);
    expect(keep.running, isTrue);

    await keep.stop();
    expect(keep.running, isFalse);
    expect(calls.map((c) => c.method), ['start', 'stop']);
  });

  test('plataforma sem o serviço não derruba o app', () async {
    // Web/iOS: o canal não existe. O app segue funcionando (só não há a
    // garantia de sobreviver em segundo plano).
    mock();
    final keep = PresenceKeepAlive(channel: channel);

    expect(await keep.start(), isFalse);
    expect(keep.running, isFalse);
    await keep.stop(); // não lança
  });

  test('recusa do sistema não derruba o app', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'presence_service_start');
    });
    final keep = PresenceKeepAlive(channel: channel);

    expect(await keep.start(), isFalse);
    expect(keep.running, isFalse);
  });
}
