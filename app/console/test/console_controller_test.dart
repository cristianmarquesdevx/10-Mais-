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

  test('a leitura que DEU CERTO não é descartada se a mais nova falhou',
      () async {
    // A leitura NOVA falha (o servidor caiu), mas a VELHA deu certo. A
    // fila antiga é o ÚLTIMO retrato verdadeiro que temos: descartar
    // seria trocar uma informação boa por uma tela vazia com erro.
    final primeiraLiberada = Completer<void>();
    var chamadas = 0;
    final api = ConsoleApi(
      baseUrl: 'http://host/functions/v1/kyc',
      accessToken: () async => 'jwt',
      inner: MockClient((_) async {
        chamadas++;
        if (chamadas == 1) {
          await primeiraLiberada.future;
          return http.Response(filaDe('c-BOM'), 200);
        }
        throw Exception('o servidor caiu');
      }),
    );
    final controller = ConsoleController(api);

    final lenta = controller.load();
    final rapida = controller.load();
    await rapida;

    // A nova falhou: a tela mostra o erro.
    expect(controller.error, 'offline');

    // Agora a velha responde com sucesso.
    primeiraLiberada.complete();
    await lenta;

    // A fila tem o último retrato verdadeiro — E o erro continua visível
    // (a fila na tela pode estar velha: a pessoa precisa saber).
    expect(controller.queue.single.caseId, 'c-BOM');
    expect(controller.error, 'offline');
  });

  test('o spinner NUNCA fica preso (nem com uma leitura pendurada)',
      () async {
    // A leitura mais recente fica pendurada (o servidor não responde) e a
    // antiga responde. O `loading` tem que desligar: senão a tela fica
    // presa em "carregando" para sempre. Quem garante isso é o PRAZO da
    // API (`requestTimeout`): a leitura pendurada vira erro `offline`.
    final primeiraLiberada = Completer<void>();
    var chamadas = 0;
    final api = ConsoleApi(
      baseUrl: 'http://host/functions/v1/kyc',
      accessToken: () async => 'jwt',
      requestTimeout: const Duration(milliseconds: 50),
      inner: MockClient((_) async {
        chamadas++;
        if (chamadas == 1) {
          await primeiraLiberada.future;
          return http.Response(filaDe('c-1'), 200);
        }
        await Completer<void>().future; // pendurada: só o prazo a salva
        return http.Response(filaDe('c-2'), 200);
      }),
    );
    final controller = ConsoleController(api);

    final lenta = controller.load();
    final rapida = controller.load();

    // A antiga responde (ela NÃO é o dono do spinner — a nova é).
    primeiraLiberada.complete();
    await lenta;

    // A nova segue pendurada: só o PRAZO da API a resolve.
    await Future<void>.delayed(const Duration(milliseconds: 120));

    // A pendurada já bateu o prazo: a tela avisou e o spinner desligou.
    expect(controller.error, 'offline');
    expect(controller.loading, isFalse);
    // E a fila conserva o ÚLTIMO retrato verdadeiro (a leitura antiga).
    expect(controller.queue.single.caseId, 'c-1');
    await rapida;
  });

  test('a leitura antiga NÃO desliga o spinner da nova (sem piscar)',
      () async {
    // Duas leituras iniciadas pela pessoa: a antiga responde primeiro,
    // a nova ainda está em curso. A antiga não pode apagar o "carregando"
    // da nova — senão a tela pisca e mente ("já carregou" enquanto o
    // servidor ainda não respondeu).
    final segundaLiberada = Completer<void>();
    var chamadas = 0;
    final api = ConsoleApi(
      baseUrl: 'http://host/functions/v1/kyc',
      accessToken: () async => 'jwt',
      requestTimeout: const Duration(milliseconds: 500),
      inner: MockClient((_) async {
        chamadas++;
        if (chamadas == 1) return http.Response(filaDe('c-VELHO'), 200);
        await segundaLiberada.future;
        return http.Response(filaDe('c-NOVO'), 200);
      }),
    );
    final controller = ConsoleController(api);

    final antiga = controller.load();
    final nova = controller.load();
    await antiga;

    // A antiga acabou, a nova não: o spinner continua.
    expect(controller.loading, isTrue);

    segundaLiberada.complete();
    await nova;

    // Agora a nova acabou: o spinner desliga.
    expect(controller.loading, isFalse);
    expect(controller.queue.single.caseId, 'c-NOVO');
  });

  test('a leitura que deu certo limpa o erro anterior', () async {
    var chamadas = 0;
    final api = ConsoleApi(
      baseUrl: 'http://host/functions/v1/kyc',
      accessToken: () async => 'jwt',
      inner: MockClient((_) async {
        chamadas++;
        if (chamadas == 1) return http.Response('{}', 500);
        return http.Response(filaDe('c-1'), 200);
      }),
    );
    final controller = ConsoleController(api);

    await controller.load();
    expect(controller.error, isNotNull);

    await controller.load();
    expect(controller.error, isNull);
    expect(controller.queue.single.caseId, 'c-1');
  });

  test('sem resposta do servidor, a leitura vira erro (não trava)',
      () async {
    // O prazo do cliente HTTP: uma leitura pendurada não pode deixar a
    // tela presa no spinner.
    final api = ConsoleApi(
      baseUrl: 'http://host/functions/v1/kyc',
      accessToken: () async => 'jwt',
      requestTimeout: const Duration(milliseconds: 50),
      inner: MockClient((_) async {
        await Completer<void>().future;
        return http.Response(filaDe('c-1'), 200);
      }),
    );
    final controller = ConsoleController(api);

    await controller.load();

    expect(controller.error, 'offline');
    expect(controller.loading, isFalse);
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
