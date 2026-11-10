import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parceiro/src/api/client.dart';
import 'package:parceiro/src/auth/auth_service.dart';
import 'package:parceiro/src/screens/screens.dart';

/// O app do parceiro fala com DOIS backends: o ciclo de corrida no Postgres
/// (Edge Function `rides`) e o que ainda não migrou (KYC, passe, carteira,
/// desempenho). Estes testes travam a divisão e o token assíncrono.
void main() {
  late List<http.Request> seen;

  http.Response answer(http.Request req) {
    if (req.url.path.endsWith('/offers/mine')) {
      return http.Response(
        jsonEncode({
          'offers': [
            {
              'offer_id': 'aaaaaaaa-1111-4111-8111-111111111111',
              'ride_id': 'bbbbbbbb-1111-4111-8111-111111111111',
              'amount': 18.5,
              'timeout_at': '2026-11-10T14:00:00Z',
            },
          ],
        }),
        200,
      );
    }
    if (req.url.path.endsWith('/partner/wallet')) {
      return http.Response(
        jsonEncode({'balance': 42.0, 'debt_cents': 0, 'statement': []}),
        200,
      );
    }
    if (req.url.path.endsWith('/me')) {
      return http.Response(
        jsonEncode({
          'user_id': '22222222-2222-4222-8222-222222222222',
          'role': 'PARTNER',
          'partner': {
            'kyc_status': 'APPROVED',
            'monetization_mode': 'COMISSAO',
            'wallet_balance': 96.65,
            'debt_cents': 0,
          },
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

  test('as ofertas vão para a base real (ridesBase)', () async {
    final api = clientWith(
      MockClient((req) async {
        seen.add(req);
        return answer(req);
      }),
      ridesBase: 'http://real.local/functions/v1/rides',
    );

    final offers = await api.myOffers();
    expect(offers, hasLength(1));
    expect(seen.single.url.host, 'real.local');
    expect(seen.single.url.path, '/functions/v1/rides/offers/mine');
  });

  test('o perfil do parceiro vem do backend real (identidade do token)',
      () async {
    final api = clientWith(
      MockClient((req) async {
        seen.add(req);
        return answer(req);
      }),
      ridesBase: 'http://real.local/functions/v1/rides',
    );

    final me = await api.me();
    expect(me.userId, '22222222-2222-4222-8222-222222222222');
    expect(me.partner?.kycStatus, 'APPROVED');
    expect(me.partner?.walletBalance, 96.65);
    expect(seen.single.url.path, '/functions/v1/rides/me');
  });

  test('a carteira (ainda não migrada) continua na demonstração', () async {
    final api = clientWith(
      MockClient((req) async {
        seen.add(req);
        return answer(req);
      }),
      ridesBase: 'http://real.local/functions/v1/rides',
    );

    final wallet = await api.wallet();
    expect(wallet.balance, 42.0);
    expect(seen.single.url.host, 'demo.local');
    expect(seen.single.url.path, '/functions/v1/v1/partner/wallet');
  });

  test('sem ridesBase configurado tudo fica na base de demonstração',
      () async {
    final api = clientWith(
      MockClient((req) async {
        seen.add(req);
        return answer(req);
      }),
    );

    await api.myOffers();
    expect(seen.single.url.host, 'demo.local');
    expect(seen.single.url.path, '/functions/v1/v1/offers/mine');
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

    await api.myOffers();
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
  Future<void> sendCode(String email) async => sentEmail = email;

  @override
  Future<void> verifyCode(String email, String code) async =>
      verifiedCode = code;

  @override
  Future<bool> attachPhone(String input) async {
    attachedPhone = input;
    return true;
  }
}

/// O login do parceiro tem a etapa de e-mail (o piloto não tem provedor de
/// SMS: o código chega por e-mail) e o código tem 6 dígitos.
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

    // A etapa de e-mail existe antes do código.
    expect(find.byKey(const ValueKey('login-email')), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('login-email')),
      'parceiro@dezemais.local',
    );
    await tester.tap(find.text('CONTINUAR'));
    await tester.pump();
    await tester.pump();

    expect(auth.sentEmail, 'parceiro@dezemais.local');
    expect(find.text('Código de verificação'), findsOneWidget);

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
    expect(auth.attachedPhone, '69999999999');
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
      'parceiro@dezemais.local',
    );
    await tester.tap(find.text('CONTINUAR'));
    await tester.pump();
    await tester.pump();

    await tester.enterText(find.byKey(const ValueKey('login-otp')), '1234');
    await tester.tap(find.text('ENTRAR'));
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump();

    expect(entrou, isTrue);
  });
}
