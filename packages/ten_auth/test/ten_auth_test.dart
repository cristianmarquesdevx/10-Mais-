import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ten_auth/ten_auth.dart';

/// A fonte única do login é o pacote `ten_auth`: os três apps (passageiro,
/// parceiro e console da operação) consomem ESTE arquivo. Estes testes
/// existem para que uma mudança no fluxo de autenticação quebre aqui, e não
/// em três apps ao mesmo tempo.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('telefone', () {
    test('normaliza para E.164', () {
      // +55 (2) + DDD (2) + celular de 9 dígitos (9) = 13 dígitos.
      expect(AuthService.normalizePhone('69999999999'), '+5569999999999');
      expect(AuthService.normalizePhone('(69) 99999-9999'), '+5569999999999');
      expect(AuthService.normalizePhone('+55 69 99999 9999'), '+5569999999999');
      expect(AuthService.normalizePhone('069999999999'), '+5569999999999');
      // Fixo de 8 dígitos também é válido (DDD + número): 12 dígitos.
      expect(AuthService.normalizePhone('69 3333-4444'), '+556933334444');
    });

    test('número curto não vira telefone válido', () async {
      // `normalizePhone` só normaliza o formato; quem VALIDA é o pedido de
      // código (o GoTrue também recusa). O número curto sai com o prefixo
      // mas nunca chega à rede.
      expect(AuthService.normalizePhone('abc'), '');
      final auth = AuthService(
        baseUrl: 'http://auth.local/auth/v1',
        anonKey: 'anon',
        client: MockClient((_) async => http.Response('{}', 200)),
      );
      await expectLater(
        auth.sendPhoneCode('123'),
        throwsA(isA<AuthException>()
            .having((e) => e.failure, 'failure', AuthFailure.rejected)),
      );
    });
  });

  group('sessão', () {
    test('sobrevive ao round-trip do JSON', () {
      final s = AuthSession(
        accessToken: 'access',
        refreshToken: 'refresh',
        userId: 'u-1',
        email: 'a@b.com',
        expiresAt: DateTime.now().add(const Duration(hours: 1)),
      );
      final back = AuthSession.fromJson(
          jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>);
      expect(back, isNotNull);
      expect(back!.accessToken, 'access');
      expect(back.refreshToken, 'refresh');
      expect(back.userId, 'u-1');
      expect(back.email, 'a@b.com');
      expect(back.isExpired, isFalse);
    });

    test('sessão sem token é recusada', () {
      expect(AuthSession.fromJson({'email': 'a@b.com'}), isNull);
    });

    test('vence antes do prazo (margem de 60 s)', () {
      final s = AuthSession(
        accessToken: 'a',
        refreshToken: 'r',
        userId: 'u',
        email: 'a@b.com',
        expiresAt: DateTime.now().add(const Duration(seconds: 30)),
      );
      expect(s.isExpired, isTrue);
    });

    test('identidade: e-mail tem precedence; telefone é o plano B', () {
      AuthSession mk(String email, String phone) => AuthSession(
            accessToken: 'a',
            refreshToken: 'r',
            userId: 'u',
            email: email,
            phone: phone,
            expiresAt: DateTime.now().add(const Duration(hours: 1)),
          );
      expect(mk('a@b.com', '+556999999999').identity, 'a@b.com');
      expect(mk('', '+556999999999').identity, '+556999999999');
      expect(mk('', '+556999999999').isPhone, isTrue);
    });
  });

  group('fluxo por e-mail', () {
    test('e-mail inválido é recusado antes da rede', () async {
      final auth = AuthService(
        baseUrl: 'http://auth.local/auth/v1',
        anonKey: 'anon',
        role: 'AGENT',
        client: MockClient((_) async => http.Response('{}', 200)),
      );
      await expectLater(
        auth.sendCode('nao-e-email'),
        throwsA(isA<AuthException>()
            .having((e) => e.failure, 'failure', AuthFailure.rejected)),
      );
    });

    test('pede o código com o papel do app no cadastro', () async {
      http.Request? seen;
      final auth = AuthService(
        baseUrl: 'http://auth.local/auth/v1',
        anonKey: 'anon-key',
        role: 'AGENT',
        client: MockClient((req) async {
          seen = req;
          return http.Response('{}', 200);
        }),
      );

      await auth.sendCode('Cris@Dezemais.Local ');

      expect(seen, isNotNull);
      expect(seen!.method, 'POST');
      expect(seen!.url.path, '/auth/v1/otp');
      expect(seen!.headers['apikey'], 'anon-key');
      final body = jsonDecode(seen!.body) as Map<String, dynamic>;
      expect(body['email'], 'cris@dezemais.local');
      expect(body['create_user'], isTrue);
      expect((body['data'] as Map<String, dynamic>)['role'], 'AGENT');
    });

    test('createUser: false não cadastra conta nova', () async {
      // O console da operação só aceita conta que JÁ existe: o cadastro
      // público nunca cria papel de agente.
      http.Request? seen;
      final auth = AuthService(
        baseUrl: 'http://auth.local/auth/v1',
        anonKey: 'anon',
        role: 'AGENT',
        client: MockClient((req) async {
          seen = req;
          return http.Response('{}', 200);
        }),
      );

      await auth.sendCode('cris@dezemais.local', createUser: false);

      final body = jsonDecode(seen!.body) as Map<String, dynamic>;
      expect(body['create_user'], isFalse);
    });

    test('withRole: false não manda o papel no pedido', () async {
      // Entrar numa conta que já existe não pode mexer no papel dela.
      http.Request? seen;
      final auth = AuthService(
        baseUrl: 'http://auth.local/auth/v1',
        anonKey: 'anon',
        role: 'AGENT',
        client: MockClient((req) async {
          seen = req;
          return http.Response('{}', 200);
        }),
      );

      await auth.sendCode('cris@dezemais.local',
          createUser: false, withRole: false);

      final body = jsonDecode(seen!.body) as Map<String, dynamic>;
      expect(body.containsKey('data'), isFalse);
    });

    test('conta inexistente vira "conta não encontrada"', () async {
      final auth = AuthService(
        baseUrl: 'http://auth.local/auth/v1',
        anonKey: 'anon',
        client: MockClient((_) async => http.Response(
              jsonEncode({'code': 'user_not_found', 'msg': 'User not found'}),
              404,
            )),
      );
      await expectLater(
        auth.sendCode('ninguem@dezemais.local', createUser: false),
        throwsA(isA<AuthException>()
            .having((e) => e.failure, 'failure', AuthFailure.rejected)
            .having((e) => e.message, 'message', contains('não encontrada'))),
      );
    });

    test('código com ≠ 6 dígitos é recusado', () async {
      final auth = AuthService(
        baseUrl: 'http://auth.local/auth/v1',
        anonKey: 'anon',
        client: MockClient((_) async => http.Response('{}', 200)),
      );
      await expectLater(
        auth.verifyCode('a@b.com', '123'),
        throwsA(isA<AuthException>()
            .having((e) => e.failure, 'failure', AuthFailure.rejected)),
      );
    });

    test('verificar o código abre a sessão e a persiste', () async {
      final auth = AuthService(
        baseUrl: 'http://auth.local/auth/v1',
        anonKey: 'anon',
        role: 'AGENT',
        client: MockClient((req) async {
          if (req.url.path.endsWith('/verify')) {
            return http.Response(
              jsonEncode({
                'access_token': 'access-1',
                'refresh_token': 'refresh-1',
                'expires_in': 3600,
                'user': {'id': 'u-9', 'email': 'cris@dezemais.local'},
              }),
              200,
            );
          }
          return http.Response('{}', 200);
        }),
      );

      await auth.verifyCode('cris@dezemais.local', '123 456');

      expect(auth.isSignedIn, isTrue);
      expect(auth.userId, 'u-9');
      expect(await auth.accessToken(), 'access-1');

      // A sessão sobrevive ao fechamento do app.
      final outro = AuthService(
        baseUrl: 'http://auth.local/auth/v1',
        anonKey: 'anon',
        client: MockClient((_) async => http.Response('{}', 200)),
      );
      await outro.restore();
      expect(outro.isSignedIn, isTrue);
      expect(outro.email, 'cris@dezemais.local');
    });

    test('token vencido é renovado antes de devolver', () async {
      final auth = AuthService(
        baseUrl: 'http://auth.local/auth/v1',
        anonKey: 'anon',
        client: MockClient((req) async {
          if (req.url.path.endsWith('/verify')) {
            return http.Response(
              jsonEncode({
                'access_token': 'access-1',
                'refresh_token': 'refresh-1',
                'expires_in': 1,
                'user': {'id': 'u-9', 'email': 'cris@dezemais.local'},
              }),
              200,
            );
          }
          if (req.url.query.contains('grant_type=refresh_token')) {
            return http.Response(
              jsonEncode({
                'access_token': 'access-2',
                'refresh_token': 'refresh-2',
                'expires_in': 3600,
                'user': {'id': 'u-9', 'email': 'cris@dezemais.local'},
              }),
              200,
            );
          }
          return http.Response('{}', 200);
        }),
      );

      await auth.verifyCode('cris@dezemais.local', '123456');
      // `expires_in: 1` já passa da margem de 60 s: o token nasce vencido.
      expect(await auth.accessToken(), 'access-2');
    });
  });

  group('erros do servidor de acesso', () {
    Future<AuthException> falha(http.Response resp) async {
      final auth = AuthService(
        baseUrl: 'http://auth.local/auth/v1',
        anonKey: 'anon',
        client: MockClient((_) async => resp),
      );
      try {
        await auth.sendCode('a@b.com');
      } on AuthException catch (e) {
        return e;
      }
      fail('devia ter lançado AuthException');
    }

    test('429 vira rateLimited', () async {
      final e = await falha(http.Response('{}', 429));
      expect(e.failure, AuthFailure.rateLimited);
    });

    test('401 vira codeInvalid', () async {
      final e = await falha(http.Response('{}', 401));
      expect(e.failure, AuthFailure.codeInvalid);
    });

    test('servidor fora do ar vira offline', () async {
      final auth = AuthService(
        baseUrl: 'http://auth.local/auth/v1',
        anonKey: 'anon',
        client: MockClient((_) async => throw const SocketishError()),
      );
      await expectLater(
        auth.sendCode('a@b.com'),
        throwsA(isA<AuthException>()
            .having((e) => e.failure, 'failure', AuthFailure.offline)),
      );
    });
  });

  group('sair', () {
    test('apaga a sessão local', () async {
      final auth = AuthService(
        baseUrl: 'http://auth.local/auth/v1',
        anonKey: 'anon',
        client: MockClient((req) async {
          if (req.url.path.endsWith('/verify')) {
            return http.Response(
              jsonEncode({
                'access_token': 'a',
                'refresh_token': 'r',
                'expires_in': 3600,
                'user': {'id': 'u', 'email': 'a@b.com'},
              }),
              200,
            );
          }
          return http.Response('{}', 200);
        }),
      );
      await auth.verifyCode('a@b.com', '123456');
      expect(auth.isSignedIn, isTrue);

      await auth.signOut();
      expect(auth.isSignedIn, isFalse);
      expect(await auth.accessToken(), isNull);
    });
  });
}

/// Falha de transporte genérica (sem `dart:io` no pacote, para não puxar a
/// plataforma no web).
class SocketishError implements Exception {
  const SocketishError();
  @override
  String toString() => 'SocketishError: conexão recusada';
}
