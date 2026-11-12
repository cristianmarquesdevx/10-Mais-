import 'dart:async';
import 'dart:convert';

import 'package:console_operacao/src/api/console_api.dart';
import 'package:console_operacao/src/state/console_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// O controller da fila: quem lê, quem perde, e o que acontece quando DUAS
/// leituras se cruzam.
void main() {
  String filaDe(String caseId) => jsonEncode({
        'cases': [
          {
            'case_id': caseId,
            'partner_user_id': '77777777-7777-4777-8777-777777777777',
            'partner_name': 'Parceiro KYC dev',
            'status': 'IN_REVIEW',
            'created_at': '2026-11-11T10:00:00Z',
            'position': 1,
          },
        ],
      });

  test('a fila lida aparece no estado', () async {
    final api = ConsoleApi(
      baseUrl: 'http://host/functions/v1/kyc',
      accessToken: () async => 'jwt',
      inner: MockClient((_) async => http.Response(filaDe('c-1'), 200)),
    );
    final controller = ConsoleController(api);

    await controller.load();

    expect(controller.queue.single.caseId, 'c-1');
    expect(controller.error, isNull);
    expect(controller.loadedAt, isNotNull);
  });

  test('a leitura antiga NÃO sobrescreve a nova (polling x puxar)',
      () async {
    // Duas leituras se cruzam: a primeira (lenta) responde DEPOIS da
    // segunda. Sem a guarda, a fila mostraria um retrato VELHO — a pessoa
    // da operação decidiria sobre um caso que já saiu da fila.
    final primeiraLiberada = Completer<void>();
    var chamadas = 0;
    final api = ConsoleApi(
      baseUrl: 'http://host/functions/v1/kyc',
      accessToken: () async => 'jwt',
      inner: MockClient((_) async {
        chamadas++;
        if (chamadas == 1) {
          await primeiraLiberada.future;
          return http.Response(filaDe('c-VELHO'), 200);
        }
        return http.Response(filaDe('c-NOVO'), 200);
      }),
    );
    final controller = ConsoleController(api);

    final lenta = controller.load();
    final rapida = controller.load();
    await rapida;
    expect(controller.queue.single.caseId, 'c-NOVO');

    // Agora a velha chega por último.
    primeiraLiberada.complete();
    await lenta;

    // A fila continua com a leitura mais nova: a velha foi descartada.
    expect(controller.queue.single.caseId, 'c-NOVO');
    expect(controller.error, isNull);
  });

  test('a falha conta UMA vez por erro (o aviso não se repete)', () async {
    final api = ConsoleApi(
      baseUrl: 'http://host/functions/v1/kyc',
      accessToken: () async => 'jwt',
      inner: MockClient((_) async => http.Response(
            jsonEncode({'title': 'Você não pode ver este caso', 'code': 'forbidden'}),
            403,
          )),
    );
    final controller = ConsoleController(api);

    await controller.load();

    expect(controller.error, 'forbidden');
    expect(controller.errorCount, 1);
  });

  test('a fila antiga continua visível quando o refresh falha', () async {
    var chamadas = 0;
    final api = ConsoleApi(
      baseUrl: 'http://host/functions/v1/kyc',
      accessToken: () async => 'jwt',
      inner: MockClient((_) async {
        chamadas++;
        if (chamadas == 1) return http.Response(filaDe('c-1'), 200);
        return http.Response('{}', 500);
      }),
    );
    final controller = ConsoleController(api);

    await controller.load();
    await controller.load(silent: true);

    // A tela não fica em branco: ela mostra o que tinha e avisa que a
    // atualização falhou.
    expect(controller.queue.single.caseId, 'c-1');
    expect(controller.error, isNotNull);
  });
}
