import 'dart:convert';

import 'package:console_operacao/src/api/console_api.dart';
import 'package:console_operacao/src/screens/case_screen.dart';
import 'package:console_operacao/src/screens/queue_screen.dart';
import 'package:console_operacao/src/state/console_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ten_design/ten_design.dart';

/// A fila é a PRIMEIRA tela do console: o que a operação precisa primeiro é
/// saber o que está esperando e o que vence primeiro.
void main() {
  String filaJson() => jsonEncode({
        'cases': [
          {
            'case_id': '11111111-1111-4111-8111-111111111111',
            'partner_user_id': '77777777-7777-4777-8777-777777777777',
            'partner_name': 'Parceiro KYC dev',
            'partner_phone': '+5596990000004',
            'status': 'IN_REVIEW',
            'sla_due_at': DateTime.now()
                .add(const Duration(hours: 2))
                .toUtc()
                .toIso8601String(),
            'created_at': DateTime.now()
                .subtract(const Duration(hours: 1))
                .toUtc()
                .toIso8601String(),
            'position': 1,
            'documents': 2,
          },
        ],
      });

  /// A tela do caso é uma lista: sem viewport alto, os botões de decisão
  /// ficam fora da tela e o `ListView` nem os constrói.
  Future<void> telaAlta(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  /// O celular pequeno de verdade: 360×800 dp.
  Future<void> telaPequena(WidgetTester tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Widget monta(Widget child) => MaterialApp(
        theme: buildLightTheme(),
        home: child,
      );

  /// A tela do console com a FONTE DO SISTEMA em 2.0: é a letra grande que
  /// estoura os layouts (a operação trabalha com o celular na mão, às
  /// vezes com a fonte no máximo por acessibilidade).
  Widget montaComFonteGrande(Widget child) => MaterialApp(
        theme: buildLightTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2.0)),
          child: child!,
        ),
        home: child,
      );

  testWidgets('a fila mostra posição, prazo e documentos', (tester) async {
    await telaAlta(tester);
    final api = ConsoleApi(
      baseUrl: 'http://host/functions/v1/kyc',
      accessToken: () async => 'jwt',
      inner: MockClient((_) async => http.Response(filaJson(), 200)),
    );

    await tester.pumpWidget(
      monta(QueueScreen(
        controller: ConsoleController(api),
        // Sem polling no teste: um timer pendente no fim do teste é falha.
        pollInterval: null,
      )),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('queue-list')), findsOneWidget);
    expect(find.text('#1'), findsOneWidget);
    expect(find.textContaining('2 documentos'), findsOneWidget);
    expect(find.textContaining('vence em'), findsOneWidget);
    expect(find.textContaining('entrou há'), findsOneWidget);
  });

  testWidgets('a fila identifica o parceiro pelo nome e pelo telefone',
      (tester) async {
    await telaAlta(tester);
    final api = ConsoleApi(
      baseUrl: 'http://host/functions/v1/kyc',
      accessToken: () async => 'jwt',
      inner: MockClient((_) async => http.Response(filaJson(), 200)),
    );

    await tester.pumpWidget(
      monta(QueueScreen(
        controller: ConsoleController(api),
        pollInterval: null,
      )),
    );
    await tester.pumpAndSettle();

    // Sem isto a operação via "Parceiro 77777777" e não sabe de quem é o
    // cadastro — nem consegue ligar para o parceiro.
    expect(find.text('Parceiro KYC dev'), findsOneWidget);
    expect(find.text('+5596990000004'), findsOneWidget);
    expect(find.textContaining('Parceiro 77777777'), findsNothing);
  });

  testWidgets('a fila não estoura em 360x800 com a fonte em 2.0',
      (tester) async {
    await telaPequena(tester);
    final api = ConsoleApi(
      baseUrl: 'http://host/functions/v1/kyc',
      accessToken: () async => 'jwt',
      inner: MockClient((_) async => http.Response(filaJson(), 200)),
    );

    await tester.pumpWidget(
      montaComFonteGrande(QueueScreen(
        controller: ConsoleController(api),
        pollInterval: null,
      )),
    );
    await tester.pumpAndSettle();

    // Um overflow é uma exceção de renderização: o teste falha sozinho.
    expect(tester.takeException(), isNull);
    expect(find.text('Parceiro KYC dev'), findsOneWidget);
  });

  testWidgets('fila vazia mostra o estado vazio (não tela em branco)',
      (tester) async {
    await telaAlta(tester);
    final api = ConsoleApi(
      baseUrl: 'http://host/functions/v1/kyc',
      accessToken: () async => 'jwt',
      inner: MockClient(
          (_) async => http.Response(jsonEncode({'cases': []}), 200)),
    );

    await tester.pumpWidget(
      monta(QueueScreen(
        controller: ConsoleController(api),
        // Sem polling no teste: um timer pendente no fim do teste é falha.
        pollInterval: null,
      )),
    );
    await tester.pumpAndSettle();

    expect(find.text('Nenhum cadastro na fila'), findsOneWidget);
    expect(find.byKey(const ValueKey('queue-list')), findsNothing);
  });

  testWidgets('sem permissão mostra a recusa clara, não a fila',
      (tester) async {
    await telaAlta(tester);
    final api = ConsoleApi(
      baseUrl: 'http://host/functions/v1/kyc',
      accessToken: () async => 'jwt',
      inner: MockClient((_) async => http.Response(
            jsonEncode({'title': 'Você não pode ver este caso', 'code': 'forbidden'}),
            403,
          )),
    );

    await tester.pumpWidget(
      monta(QueueScreen(
        controller: ConsoleController(api),
        // Sem polling no teste: um timer pendente no fim do teste é falha.
        pollInterval: null,
      )),
    );
    await tester.pumpAndSettle();

    expect(find.text('Esta conta não é da operação'), findsOneWidget);
    expect(find.byKey(const ValueKey('queue-list')), findsNothing);
  });

  testWidgets('sem rede mostra o erro de conexão', (tester) async {
    await telaAlta(tester);
    final api = ConsoleApi(
      baseUrl: 'http://host/functions/v1/kyc',
      accessToken: () async => 'jwt',
      inner: MockClient((_) async => throw Exception('sem rede')),
    );

    await tester.pumpWidget(
      monta(QueueScreen(
        controller: ConsoleController(api),
        // Sem polling no teste: um timer pendente no fim do teste é falha.
        pollInterval: null,
      )),
    );
    await tester.pumpAndSettle();

    expect(find.text('Sem conexão com o servidor'), findsOneWidget);
  });

  group('decisão', () {
    String casoJson() => jsonEncode({
          'case_id': '11111111-1111-4111-8111-111111111111',
          'status': 'IN_REVIEW',
          'position': 1,
          'partner_user_id': '77777777-7777-4777-8777-777777777777',
          'partner_name': 'Parceiro KYC dev',
          'partner_phone': '+5596990000004',
          'sla': DateTime.now().add(const Duration(hours: 2)).toUtc().toIso8601String(),
          'documents': [
            {
              'doc_type': 'CNH',
              'created_at': DateTime.now().toUtc().toIso8601String(),
              'upload_pending': false,
              'has_file': true,
              'storage_path':
                  'kyc/77777777-7777-4777-8777-777777777777/c-1/CNH_1.jpg',
            },
            {
              'doc_type': 'SELFIE',
              'created_at': DateTime.now().toUtc().toIso8601String(),
              'upload_pending': true,
              'has_file': false,
              'storage_path': '',
            },
          ],
        });

    testWidgets('o detalhe mostra a documentação e o arquivo pendente',
        (tester) async {
    await telaAlta(tester);
      final api = ConsoleApi(
        baseUrl: 'http://host/functions/v1/kyc',
        accessToken: () async => 'jwt',
        inner: MockClient(
            (_) async => http.Response(casoJson(), 200)),
      );

      await tester.pumpWidget(
        monta(
          CaseScreen(caseId: 'c-1', api: api, controller: ConsoleController(api)),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Documentação'), findsOneWidget);
      expect(find.text('CNH (documento com foto)'), findsOneWidget);
      expect(find.text('ARQUIVO OK'), findsOneWidget);
      // O registro honesto: documento sem arquivo é pendente, e a operação
      // precisa ver isso antes de aprovar.
      expect(find.text('ARQUIVO PENDENTE'), findsOneWidget);
      // A operação precisa saber QUEM é o parceiro.
      expect(find.text('Parceiro KYC dev'), findsOneWidget);
      expect(find.text('+5596990000004'), findsOneWidget);
      // E precisa VER o documento: o pedido do arquivo sai para o bucket
      // privado (o teste responde com um corpo que não é imagem, e a tela
      // mostra a falha em vez de fingir que carregou).
      expect(find.byKey(const ValueKey('document-preview')), findsOneWidget);
      expect(find.text('Não foi possível carregar o documento.'), findsOneWidget);
    });

    testWidgets('o detalhe não estoura em 360x800 com a fonte em 2.0',
        (tester) async {
      await telaPequena(tester);
      final api = ConsoleApi(
        baseUrl: 'http://host/functions/v1/kyc',
        accessToken: () async => 'jwt',
        inner: MockClient((_) async => http.Response(casoJson(), 200)),
      );

      await tester.pumpWidget(
        montaComFonteGrande(
          CaseScreen(caseId: 'c-1', api: api, controller: ConsoleController(api)),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });

    testWidgets('aprovar pede confirmação e envia APPROVED', (tester) async {
    await telaAlta(tester);
      final enviados = <Map<String, dynamic>>[];
      final api = ConsoleApi(
        baseUrl: 'http://host/functions/v1/kyc',
        accessToken: () async => 'jwt',
        inner: MockClient((req) async {
          if (req.method == 'POST') {
            enviados.add(jsonDecode(req.body) as Map<String, dynamic>);
            return http.Response(
              jsonEncode({
                'case_id': 'c-1',
                'status': 'APPROVED',
                'partner_kyc_status': 'APPROVED',
              }),
              200,
            );
          }
          return http.Response(casoJson(), 200);
        }),
      );

      await tester.pumpWidget(
        monta(
          CaseScreen(caseId: 'c-1', api: api, controller: ConsoleController(api)),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('approve')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('approve-confirm')));
      await tester.pumpAndSettle();

      expect(enviados.single['decision'], 'APPROVED');
    });

    testWidgets('recusar exige o motivo padronizado', (tester) async {
    await telaAlta(tester);
      final enviados = <Map<String, dynamic>>[];
      final api = ConsoleApi(
        baseUrl: 'http://host/functions/v1/kyc',
        accessToken: () async => 'jwt',
        inner: MockClient((req) async {
          if (req.method == 'POST') {
            enviados.add(jsonDecode(req.body) as Map<String, dynamic>);
            return http.Response(
              jsonEncode({'case_id': 'c-1', 'status': 'REJECTED'}),
              200,
            );
          }
          return http.Response(casoJson(), 200);
        }),
      );

      await tester.pumpWidget(
        monta(
          CaseScreen(caseId: 'c-1', api: api, controller: ConsoleController(api)),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('reject')));
      await tester.pumpAndSettle();

      // Sem motivo, a folha não deixa confirmar.
      await tester.tap(find.byKey(const ValueKey('decision-confirm')));
      await tester.pumpAndSettle();
      expect(enviados, isEmpty);
      expect(find.byKey(const ValueKey('decision-error')), findsOneWidget);

      // Com o motivo escolhido, a decisão sai.
      await tester.tap(find.byKey(const ValueKey('decision-reason')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('CNH ilegível ou com reflexo').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('decision-confirm')));
      await tester.pumpAndSettle();

      expect(enviados.single['decision'], 'REJECTED');
      expect(enviados.single['rejection_code'], 'CNH_ILEGIVEL');
    });

    testWidgets('pedir reenvio manda RESUBMIT com o motivo', (tester) async {
    await telaAlta(tester);
      final enviados = <Map<String, dynamic>>[];
      final api = ConsoleApi(
        baseUrl: 'http://host/functions/v1/kyc',
        accessToken: () async => 'jwt',
        inner: MockClient((req) async {
          if (req.method == 'POST') {
            enviados.add(jsonDecode(req.body) as Map<String, dynamic>);
            return http.Response(
              jsonEncode({'case_id': 'c-1', 'status': 'RESUBMIT'}),
              200,
            );
          }
          return http.Response(casoJson(), 200);
        }),
      );

      await tester.pumpWidget(
        monta(
          CaseScreen(caseId: 'c-1', api: api, controller: ConsoleController(api)),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('resubmit')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('decision-reason')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Documentação incompleta').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('decision-confirm')));
      await tester.pumpAndSettle();

      expect(enviados.single['decision'], 'RESUBMIT');
      expect(enviados.single['rejection_code'], 'DOC_INCOMPLETO');
    });
  });
}
