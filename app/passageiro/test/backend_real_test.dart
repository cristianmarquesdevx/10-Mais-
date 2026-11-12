import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:passageiro/src/api/client.dart';
import 'package:passageiro/src/screens/screens.dart';
import 'package:ten_auth/ten_auth.dart';

/// O app fala com DOIS backends: o ciclo de corrida no Postgres (Edge
/// Function `rides`) e o que ainda não migrou (perfil, suporte, convites).
///
/// Estes testes travam a division: a rota decide o destino, e um token
/// assíncrono (a sessão renova o token sozinha) tem que funcionar.
void main() {
  late List<http.Request> seen;

  /// Resposta que serve para qualquer rota: a cotação volta com o contrato
  /// mínimo, o resto com um objeto vazio.
  http.Response answer(http.Request req) {
    if (req.url.path.endsWith('/quote')) {
      return http.Response(
        jsonEncode({
          'quote_id': '11111111-1111-4111-8111-111111111111',
          'fare_total': 9.4,
          'expires_in': 90,
          'currency': 'BRL',
        }),
        200,
      );
    }
    return http.Response('{}', 200);
  }

  ApiClient clientWith(
    MockClient handler, {
    String? ridesBase,
    FutureOr<String> Function()? token,
  }) {
    seen = [];
    return ApiClient(
      baseUrl: 'http://demo.local/functions/v1/v1',
      ridesBase: ridesBase,
      accessToken: token ?? () => 'jwt-test',
      inner: handler,
    );
  }

  test('o ciclo de corrida vai para a base real (ridesBase)', () async {
    final api = clientWith(
      MockClient((req) async {
        seen.add(req);
        return answer(req);
      }),
      ridesBase: 'http://real.local/functions/v1/rides',
    );

    await api.quote(
      origin: const GeoPoint(-8.7607, -63.9039),
      destination: const GeoPoint(-8.7647, -63.8969),
    );
    expect(seen.single.url.host, 'real.local');
    expect(seen.single.url.path, '/functions/v1/rides/quote');
  });

  test('o perfil do passageiro também vem do backend real', () async {
    final api = clientWith(
      MockClient((req) async {
        seen.add(req);
        return http.Response(
          jsonEncode({
            'user_id': '11111111-1111-4111-8111-111111111111',
            'role': 'PASSENGER',
            'full_name': 'Passageiro dev',
          }),
          200,
        );
      }),
      ridesBase: 'http://real.local/functions/v1/rides',
    );

    final me = await api.me();
    expect(me.userId, '11111111-1111-4111-8111-111111111111');
    expect(seen.single.url.path, '/functions/v1/rides/me',
        reason: 'a identidade vem do token (auth.uid), não da demo');
  });

  test('o que ainda não migrou continua na base de demonstração', () async {
    final api = clientWith(
      MockClient((req) async {
        seen.add(req);
        return http.Response('{}', 200);
      }),
      ridesBase: 'http://real.local/functions/v1/rides',
    );

    await api.openTicket(priority: 'EMERGENCY');
    expect(seen.single.url.host, 'demo.local');
    expect(seen.single.url.path, '/functions/v1/v1/support/tickets');
  });

  test('sem ridesBase configurado tudo fica na base de demonstração',
      () async {
    final api = clientWith(
      MockClient((req) async {
        seen.add(req);
        return http.Response('{}', 200);
      }),
    );

    await api.createRide(
      origin: const GeoPoint(0, 0),
      destination: const GeoPoint(1, 1),
      mode: PricingMode.tariff,
    );
    expect(seen.single.url.host, 'demo.local');
    expect(seen.single.url.path, '/functions/v1/v1/rides');
  });

  test('token assíncrono (sessão que renova) vira header bearer', () async {
    final api = clientWith(
      MockClient((req) async {
        seen.add(req);
        return answer(req);
      }),
      token: () async {
        await Future<void>.delayed(const Duration(milliseconds: 1));
        return 'jwt-renovado';
      },
    );

    await api.quote(
      origin: const GeoPoint(0, 0),
      destination: const GeoPoint(1, 1),
    );
    expect(seen.single.headers['authorization'], 'Bearer jwt-renovado');
  });

  _loginTests();
}

/// Serviço de auth de mentira: registra o que a tela pediu.
class _FakeAuth extends AuthService {
  _FakeAuth() : super(baseUrl: 'http://auth.local/auth/v1', anonKey: 'anon');

  String? sentEmail;
  String? verifiedCode;
  String? attachedPhone;

  @override
  Future<void> sendCode(
    String email, {
    bool createUser = true,
    bool withRole = true,
  }) async =>
      sentEmail = email;

  @override
  Future<void> verifyCode(String email, String code) async =>
      verifiedCode = code;

  @override
  Future<bool> attachPhone(String input) async {
    attachedPhone = input;
    return true;
  }
}

/// A tela de login com autenticação real: o código é pedido ao servidor
/// ANTES da etapa do OTP e conferido nele depois.
void _loginTests() {
  testWidgets('login real: pede o código, confere o OTP e entra',
      (tester) async {
    final auth = _FakeAuth();
    var entrou = false;
    await tester.pumpWidget(MaterialApp(
      home: LoginScreen(onDone: () => entrou = true, auth: auth),
    ));

    await tester.enterText(
      find.byKey(const ValueKey('login-phone')),
      '69999999999',
    );
    await tester.tap(find.text('CONTINUAR'));
    await tester.pump();
    await tester.pump();

    await tester.enterText(
      find.byKey(const ValueKey('login-email')),
      'e2e@dezemais.app',
    );
    await tester.tap(find.text('CONTINUAR'));
    await tester.pump();
    await tester.pump();

    expect(auth.sentEmail, 'e2e@dezemais.app',
        reason: 'o código só é pedido quando o e-mail é válido');
    expect(find.text('Código de verificação'), findsOneWidget);

    // O código real tem 6 dígitos: menos que isso não é código.
    await tester.enterText(find.byKey(const ValueKey('login-otp')), '123');
    await tester.tap(find.text('ENTRAR'));
    await tester.pump();
    expect(find.textContaining('6 dígitos'), findsOneWidget);
    expect(auth.verifiedCode, isNull);

    await tester.enterText(find.byKey(const ValueKey('login-otp')), '123456');
    await tester.tap(find.text('ENTRAR'));
    await tester.pump();
    await tester.pump();

    expect(auth.verifiedCode, '123456');
    expect(auth.attachedPhone, '69999999999',
        reason: 'o telefone é registrado depois do login');
    expect(entrou, isTrue);
  });

  testWidgets('modo dev (sem serviço de auth) aceita 4 dígitos',
      (tester) async {
    var entrou = false;
    await tester.pumpWidget(MaterialApp(
      home: LoginScreen(onDone: () => entrou = true),
    ));

    await tester.enterText(
      find.byKey(const ValueKey('login-phone')),
      '69999999999',
    );
    await tester.tap(find.text('CONTINUAR'));
    await tester.pump();
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('login-email')),
      'e2e@dezemais.app',
    );
    await tester.tap(find.text('CONTINUAR'));
    await tester.pump();
    await tester.pump();

    await tester.enterText(find.byKey(const ValueKey('login-otp')), '1234');
    await tester.tap(find.text('ENTRAR'));
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump();

    expect(entrou, isTrue,
        reason: 'sem servidor de acesso o app segue (modo dev)');
  });
}
