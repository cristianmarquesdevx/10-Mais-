import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parceiro/src/api/client.dart';
import 'package:parceiro/src/api/kyc_storage.dart';
import 'package:parceiro/src/api/supabase_urls.dart';

/// O upload REAL do arquivo do KYC (F9) e o registro do documento.
///
/// O caminho do arquivo é CONTRATO: bucket privado + a pasta do DONO. O
/// servidor confere as duas coisas (dono e existência do objeto), e a RLS do
/// bucket confere de novo. Se o app escrever no lugar errado, o upload é
/// recusado — por isso o teste confere a URL byte a byte.
void main() {
  const uid = '77777777-7777-4777-8777-777777777777';
  const casoId = '11111111-1111-4111-8111-111111111111';

  ApiClient apiCom(
    MockClient mock, {
    String? storageBase = 'http://real.local',
    String? userId = uid,
  }) =>
      ApiClient(
        baseUrl: 'http://demo.local/functions/v1/v1',
        kycBase: 'http://real.local/functions/v1/kyc',
        storageBase: storageBase,
        userId: userId == null ? null : () => userId,
        accessToken: () => 'jwt-do-parceiro',
        inner: mock,
      );

  group('caminho do objeto', () {
    test('o caminho é a pasta do DONO, com o prefixo do contrato', () {
      final path = kycStoragePath(
        userId: uid,
        docType: 'CNH',
        millis: 1700000000000,
      );

      expect(path, 'kyc/$uid/pending/CNH_1700000000000.jpg');
      expect(path.startsWith('$kycStoragePathPrefix/$uid/'), isTrue);
    });

    test('a raiz do projeto sai da base do GoTrue', () {
      expect(
        supabaseProjectRoot('http://10.0.2.2:54321/auth/v1'),
        'http://10.0.2.2:54321',
      );
      expect(
        supabaseProjectRoot('http://10.0.2.2:54321/auth/v1/'),
        'http://10.0.2.2:54321',
      );
      // Base fora do formato: devolvida como está (melhor tentar do host
      // errado do que não tentar).
      expect(
        supabaseProjectRoot('https://projeto.supabase.co'),
        'https://projeto.supabase.co',
      );
    });
  });

  group('upload do arquivo', () {
    test('sobe no bucket privado, na pasta do dono, com o token', () async {
      late http.Request seen;
      final api = apiCom(MockClient((req) async {
        seen = req;
        return http.Response(
          jsonEncode({'Key': 'kyc-docs/kyc/$uid/pending/CNH_1.jpg'}),
          200,
        );
      }));

      final path = await api.uploadKycDocument(
        docType: 'CNH',
        bytes: const [0xFF, 0xD8, 0xFF, 0xD9],
      );

      expect(seen.method, 'PUT');
      expect(
        seen.url.toString(),
        matches(RegExp(
          '^http://real\\.local/storage/v1/object/kyc-docs/kyc/'
          '$uid/pending/CNH_\\d+\\.jpg\$',
        )),
      );
      expect(path, seen.url.path.split('/object/kyc-docs/').last);
      expect(seen.headers['authorization'], 'Bearer jwt-do-parceiro');
      expect(seen.headers['content-type'], 'image/jpeg');
      expect(seen.bodyBytes, [0xFF, 0xD8, 0xFF, 0xD9]);
    });

    test('sem backend de Storage a tela sabe que não subiu', () async {
      final api = apiCom(
        MockClient((_) async => http.Response('{}', 200)),
        storageBase: null,
      );

      await expectLater(
        api.uploadKycDocument(docType: 'CNH', bytes: const [1]),
        throwsA(isA<ApiProblem>()
            .having((e) => e.code, 'code', 'storage_not_configured')),
      );
    });

    test('sem sessão não há upload (o caminho precisa do dono)', () async {
      final api = apiCom(
        MockClient((_) async => http.Response('{}', 200)),
        userId: null,
      );

      await expectLater(
        api.uploadKycDocument(docType: 'CNH', bytes: const [1]),
        throwsA(isA<ApiProblem>()
            .having((e) => e.code, 'code', 'not_authenticated')),
      );
    });

    test('recusa do Storage vira ApiProblem com o código', () async {
      final api = apiCom(MockClient((_) async => http.Response(
            jsonEncode({
              'statusCode': '400',
              'error': 'InvalidRequest',
              'message': 'Bucket not found',
            }),
            400,
          )));

      await expectLater(
        api.uploadKycDocument(docType: 'CNH', bytes: const [1]),
        throwsA(isA<ApiProblem>().having((e) => e.status, 'status', 400)),
      );
    });

    test('sem rede vira offline (não exceção crua)', () async {
      final api = apiCom(MockClient((_) async => throw Exception('sem rede')));

      await expectLater(
        api.uploadKycDocument(docType: 'CNH', bytes: const [1]),
        throwsA(isA<ApiProblem>()
            .having((e) => e.code, 'code', 'offline')),
      );
    });
  });

  group('registro do documento', () {
    test('manda o path e as flags de qualidade', () async {
      late http.Request seen;
      final api = apiCom(MockClient((req) async {
        seen = req;
        return http.Response(
          jsonEncode({'case_id': casoId, 'status': 'IN_REVIEW'}),
          201,
        );
      }));

      final c = await api.registerKycDocument(
        casoId,
        docType: 'CNH',
        storagePath: 'kyc/$uid/pending/CNH_1.jpg',
        qualityFlags: const {'blur': false, 'blur_score': 900},
      );

      expect(seen.method, 'POST');
      expect(
        seen.url.path,
        '/functions/v1/kyc/cases/$casoId/documents',
      );
      expect(seen.headers['Idempotency-Key'], isNotNull);
      final body = jsonDecode(seen.body) as Map<String, dynamic>;
      expect(body['doc_type'], 'CNH');
      expect(body['storage_path'], 'kyc/$uid/pending/CNH_1.jpg');
      expect((body['quality_flags'] as Map)['blur_score'], 900);
      expect(c?.caseId, casoId);
    });

    test('sem path o registro honesto continua possível (PENDENTE)', () async {
      late http.Request seen;
      final api = apiCom(MockClient((req) async {
        seen = req;
        return http.Response(
          jsonEncode({'case_id': casoId, 'status': 'IN_REVIEW'}),
          201,
        );
      }));

      await api.registerKycDocument(casoId, docType: 'SELFIE');

      final body = jsonDecode(seen.body) as Map<String, dynamic>;
      expect(body.containsKey('storage_path'), isFalse);
      expect(body.containsKey('quality_flags'), isFalse);
    });
  });
}
