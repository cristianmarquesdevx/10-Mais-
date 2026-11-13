import 'dart:async';
import 'dart:convert';

import 'package:console_operacao/src/api/console_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// O contrato do console com a Edge Function `kyc`.
///
/// A base aponta para a FUNÇÃO (`.../functions/v1/kyc`) e a rota do contrato
/// é `/kyc/...`: o prefixo NÃO pode ser repetido (foi exatamente o defeito
/// que o app do parceiro teve com `/kyc/kyc/cases`).
void main() {
  String urlDe(http.Request r) => r.url.toString();

  ConsoleApi apiCom(
    MockClient client, {
    String base = 'http://host:54321/functions/v1/kyc',
  }) =>
      ConsoleApi(
        baseUrl: base,
        accessToken: () async => 'jwt-da-operacao',
        inner: client,
      );

  group('endereço das rotas', () {
    test('a fila vai para .../functions/v1/kyc/queue (sem /kyc/kyc)',
        () async {
      late String url;
      final api = apiCom(MockClient((req) async {
        url = urlDe(req);
        return http.Response(jsonEncode({'cases': []}), 200);
      }));

      await api.queue();

      expect(url, 'http://host:54321/functions/v1/kyc/queue?limit=50');
    });

    test('o detalhe vai para .../kyc/cases/{id}', () async {
      late String url;
      final api = apiCom(MockClient((req) async {
        url = urlDe(req);
        return http.Response(
          jsonEncode({'case_id': 'c-1', 'status': 'IN_REVIEW', 'documents': []}),
          200,
        );
      }));

      await api.caseDetail('c-1');

      expect(url, 'http://host:54321/functions/v1/kyc/cases/c-1');
    });

    test('a decisão vai para .../kyc/cases/{id}/review', () async {
      late String url;
      final api = apiCom(MockClient((req) async {
        url = urlDe(req);
        return http.Response(
          jsonEncode({
            'case_id': 'c-1',
            'status': 'APPROVED',
            'partner_kyc_status': 'APPROVED',
          }),
          200,
        );
      }));

      await api.review('c-1', decision: 'APPROVED');

      expect(url, 'http://host:54321/functions/v1/kyc/cases/c-1/review');
    });

    test('base que já vem sem barra não ganha barra', () async {
      late String url;
      final api = apiCom(
        MockClient((req) async {
          url = urlDe(req);
          return http.Response(jsonEncode({'cases': []}), 200);
        }),
        base: 'http://host:54321/functions/v1/kyc/',
      );

      await api.queue();

      expect(url, 'http://host:54321/functions/v1/kyc/queue?limit=50');
    });
  });

  group('fila', () {
    test('lê posição, prazo e contagem de documentos', () async {
      final api = apiCom(MockClient((_) async => http.Response(
            jsonEncode({
              'cases': [
                {
                  'case_id': '11111111-1111-4111-8111-111111111111',
                  'partner_user_id': '77777777-7777-4777-8777-777777777777',
                  'status': 'IN_REVIEW',
                  'sla_due_at': '2026-11-11T18:00:00Z',
                  'created_at': '2026-11-11T10:00:00Z',
                  'position': 1,
                  'documents': 2,
                },
              ],
            }),
            200,
          )));

      final fila = await api.queue();

      expect(fila, hasLength(1));
      final c = fila.single;
      expect(c.position, 1);
      expect(c.documents, 2);
      expect(c.status, 'IN_REVIEW');
      expect(c.partnerUserId, '77777777-7777-4777-8777-777777777777');
      expect(c.slaDueAt, isNotNull);
    });

    test('fila vazia não é erro', () async {
      final api = apiCom(MockClient(
          (_) async => http.Response(jsonEncode({'cases': []}), 200)));

      expect(await api.queue(), isEmpty);
    });

    test('o token da sessão vai no cabeçalho', () async {
      late http.Request seen;
      final api = apiCom(MockClient((req) async {
        seen = req;
        return http.Response(jsonEncode({'cases': []}), 200);
      }));

      await api.queue();

      expect(seen.headers['authorization'], 'Bearer jwt-da-operacao');
    });
  });

  group('decisão', () {
    test('envia decisão, motivo e nota', () async {
      late Map<String, dynamic> body;
      final api = apiCom(MockClient((req) async {
        body = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({
            'case_id': 'c-1',
            'status': 'REJECTED',
            'partner_kyc_status': 'REJECTED',
          }),
          200,
        );
      }));

      final r = await api.review(
        'c-1',
        decision: 'REJECTED',
        rejectionCode: 'CNH_ILEGIVEL',
        note: 'Refaça a foto sem flash',
      );

      expect(body['decision'], 'REJECTED');
      expect(body['rejection_code'], 'CNH_ILEGIVEL');
      expect(body['note'], 'Refaça a foto sem flash');
      expect(r.status, 'REJECTED');
      expect(r.partnerKycStatus, 'REJECTED');
    });

    test('motivo vazio não vai no corpo', () async {
      late Map<String, dynamic> body;
      final api = apiCom(MockClient((req) async {
        body = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({'case_id': 'c-1', 'status': 'APPROVED'}),
          200,
        );
      }));

      await api.review('c-1', decision: 'APPROVED', rejectionCode: '   ');

      expect(body.containsKey('rejection_code'), isFalse);
      expect(body.containsKey('note'), isFalse);
    });
  });

  group('erros', () {
    test('problem+json vira ApiProblem com o código', () async {
      final api = apiCom(MockClient((_) async => http.Response(
            jsonEncode({
              'title': 'Informe o motivo da recusa',
              'status': 422,
              'code': 'rejection_code_required',
            }),
            422,
          )));

      await expectLater(
        api.review('c-1', decision: 'REJECTED'),
        throwsA(isA<ApiProblem>()
            .having((e) => e.status, 'status', 422)
            .having((e) => e.code, 'code', 'rejection_code_required')),
      );
    });

    test('403 forbidden é recusado como forbidden', () async {
      final api = apiCom(MockClient((_) async => http.Response(
            jsonEncode({'title': 'Você não pode ver este caso', 'code': 'forbidden'}),
            403,
          )));

      await expectLater(
        api.queue(),
        throwsA(isA<ApiProblem>()
            .having((e) => e.code, 'code', 'forbidden')),
      );
    });

    test('servidor fora do ar vira offline (não exceção crua)', () async {
      final api = apiCom(MockClient((_) async => throw Exception('sem rede')));

      await expectLater(
        api.queue(),
        throwsA(isA<ApiProblem>()
            .having((e) => e.code, 'code', 'offline')
            .having((e) => e.status, 'status', 0)),
      );
    });

    test('console sem backend diz isso em vez de chamar alguém', () async {
      var chamou = false;
      final api = ConsoleApi(
        baseUrl: '',
        accessToken: () async => 'jwt',
        inner: MockClient((_) async {
          chamou = true;
          return http.Response('{}', 200);
        }),
      );

      expect(api.isConfigured, isFalse);
      await expectLater(
        api.queue(),
        throwsA(isA<ApiProblem>()
            .having((e) => e.code, 'code', 'not_configured')),
      );
      expect(chamou, isFalse);
    });

    test('token que nunca chega vira offline (não trava a tela)', () async {
      // A sessão pode precisar renovar o token: se essa espera travar,
      // o `finally` do controller nunca roda e o spinner fica preso para
      // sempre. O token tem prazo como a requisição.
      final api = ConsoleApi(
        baseUrl: 'http://host:54321/functions/v1/kyc',
        accessToken: () async {
          await Completer<void>().future;
          return 'jwt';
        },
        requestTimeout: const Duration(milliseconds: 50),
        inner: MockClient((_) async => http.Response('{}', 200)),
      );

      await expectLater(
        api.queue(),
        throwsA(isA<ApiProblem>()
            .having((e) => e.code, 'code', 'offline')),
      );
    });
  });

  group('identidade do parceiro', () {
    test('a fila traz nome e telefone do parceiro', () async {
      final api = apiCom(MockClient((_) async => http.Response(
            jsonEncode({
              'cases': [
                {
                  'case_id': 'c-1',
                  'partner_user_id': '77777777-7777-4777-8777-777777777777',
                  'partner_name': 'Parceiro KYC dev',
                  'partner_phone': '+5596990000004',
                  'status': 'IN_REVIEW',
                  'created_at': '2026-11-11T10:00:00Z',
                  'position': 1,
                  'documents': 1,
                },
              ],
            }),
            200,
          )));

      final c = (await api.queue()).single;

      expect(c.partnerName, 'Parceiro KYC dev');
      expect(c.partnerPhone, '+5596990000004');
      expect(c.displayName, 'Parceiro KYC dev');
    });

    test('sem nome no banco, a fila não mostra "Parceiro " vazio', () async {
      final api = apiCom(MockClient((_) async => http.Response(
            jsonEncode({
              'cases': [
                {
                  'case_id': 'c-1',
                  'partner_user_id': '77777777-7777-4777-8777-777777777777',
                  'partner_name': '   ',
                  'status': 'IN_REVIEW',
                  'created_at': '2026-11-11T10:00:00Z',
                  'position': 1,
                },
              ],
            }),
            200,
          )));

      final c = (await api.queue()).single;

      expect(c.displayName, 'Parceiro 77777777');
    });

    test('o detalhe traz o nome, o telefone e o caminho do arquivo',
        () async {
      final api = apiCom(MockClient((_) async => http.Response(
            jsonEncode({
              'case_id': 'c-1',
              'status': 'IN_REVIEW',
              'partner_user_id': '77777777-7777-4777-8777-777777777777',
              'partner_name': 'Parceiro KYC dev',
              'partner_phone': '+5596990000004',
              'documents': [
                {
                  'doc_type': 'CNH',
                  'created_at': '2026-11-11T10:00:00Z',
                  'upload_pending': false,
                  'has_file': true,
                  'storage_path':
                      'kyc/77777777-7777-4777-8777-777777777777/c-1/CNH_1.jpg',
                },
              ],
            }),
            200,
          )));

      final d = await api.caseDetail('c-1');

      expect(d.partnerName, 'Parceiro KYC dev');
      expect(d.partnerPhone, '+5596990000004');
      final doc = d.documents.single;
      expect(doc.hasFile, isTrue);
      expect(doc.storagePath,
          'kyc/77777777-7777-4777-8777-777777777777/c-1/CNH_1.jpg');
      expect(doc.isViewable, isTrue);
    });

    test('documento sem arquivo não vira "visualizável"', () async {
      final api = apiCom(MockClient((_) async => http.Response(
            jsonEncode({
              'case_id': 'c-1',
              'status': 'IN_REVIEW',
              'documents': [
                {
                  'doc_type': 'SELFIE',
                  'created_at': '2026-11-11T10:00:00Z',
                  'upload_pending': true,
                  'has_file': false,
                  'storage_path': '',
                },
              ],
            }),
            200,
          )));

      final doc = (await api.caseDetail('c-1')).documents.single;

      expect(doc.isViewable, isFalse);
      expect(doc.uploadPending, isTrue);
    });
  });

  group('o documento no bucket privado', () {
    test('baixa do bucket com o PRÓPRIO token da operação (sem service role)',
        () async {
      late http.Request seen;
      final api = apiCom(MockClient((req) async {
        seen = req;
        return http.Response.bytes([0xFF, 0xD8, 0xFF, 0xE0], 200);
      }));

      final bytes = await api.documentBytes(
          'kyc/77777777-7777-4777-8777-777777777777/c-1/CNH_1.jpg');

      expect(bytes, isNotNull);
      expect(seen.url.toString(),
          'http://host:54321/storage/v1/object/kyc-docs/'
          'kyc/77777777-7777-4777-8777-777777777777/c-1/CNH_1.jpg');
      expect(seen.headers['authorization'], 'Bearer jwt-da-operacao');
    });

    test('o Storage vem do build quando ele é informado', () async {
      late String url;
      final api = ConsoleApi(
        baseUrl: 'http://host:54321/functions/v1/kyc',
        storageBase: 'http://outro:54321/storage/v1',
        accessToken: () async => 'jwt',
        inner: MockClient((req) async {
          url = req.url.toString();
          return http.Response.bytes([0xFF, 0xD8, 0xFF], 200);
        }),
      );

      await api.documentBytes('kyc/u/c-1/CNH_1.jpg');

      expect(url, startsWith('http://outro:54321/storage/v1/object/kyc-docs/'));
    });

    test('o servidor recusa o download: devolve null, não bytes', () async {
      final api = apiCom(MockClient((_) async => http.Response('{}', 403)));

      expect(await api.documentBytes('kyc/u/c-1/CNH_1.jpg'), isNull);
    });

    test('sem rede: null (a tela mostra o estado de erro)', () async {
      final api = apiCom(MockClient((_) async => throw Exception('sem rede')));

      expect(await api.documentBytes('kyc/u/c-1/CNH_1.jpg'), isNull);
    });

    test('servidor mudo no download: null em vez de travar para sempre',
        () async {
      // O download tem prazo próprio: sem ele, o preview ficava pendurado
      // para sempre (sem botão de recuperar, porque o `finally` nunca
      // rodava).
      final api = ConsoleApi(
        baseUrl: 'http://host:54321/functions/v1/kyc',
        accessToken: () async => 'jwt',
        downloadTimeout: const Duration(milliseconds: 50),
        inner: MockClient((_) async {
          await Completer<void>().future;
          return http.Response.bytes([0xFF], 200);
        }),
      );

      expect(await api.documentBytes('kyc/u/c-1/CNH_1.jpg'), isNull);
    });

    test('token que nunca chega no download: null (não trava)', () async {
      final api = ConsoleApi(
        baseUrl: 'http://host:54321/functions/v1/kyc',
        accessToken: () async {
          await Completer<void>().future;
          return 'jwt';
        },
        downloadTimeout: const Duration(milliseconds: 50),
        inner: MockClient((_) async => http.Response.bytes([0xFF], 200)),
      );

      expect(await api.documentBytes('kyc/u/c-1/CNH_1.jpg'), isNull);
    });
  });

  group('quem está logado', () {
    test('lê o papel e se é da operação', () async {
      final api = apiCom(MockClient((_) async => http.Response(
            jsonEncode({
              'user_id': '66666666-6666-4666-8666-666666666666',
              'email': 'agente@dezemais.local',
              'role': 'AGENT',
              'is_agent': true,
            }),
            200,
          )));

      final me = await api.me();

      expect(me.isAgent, isTrue);
      expect(me.role, 'AGENT');
      expect(me.email, 'agente@dezemais.local');
    });
  });
}
