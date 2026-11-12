import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:console_operacao/src/api/console_api.dart';
import 'package:console_operacao/src/widgets/document_preview.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ten_design/ten_design.dart';

/// O documento VISTO: o preview baixa o objeto do bucket privado e mostra
/// a imagem — sem fingir que carregou quando não carregou.
void main() {
  /// Um PNG 1×1 DE VERDADE (em base64): o preview valida os bytes e o
  /// `Image.memory` precisa de um arquivo que o decodificador aceite — um
  /// JPEG de cabeçalhos falsos passaria pela validação e falharia na
  /// imagem (o teste viraria sobre o decodificador, não sobre a tela).
  final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
  );

  /// Dois PNGs 1×1 de cores DIFERENTES — para o teste distinguir DOIS
  /// documentos pelos BYTES que a tela está exibindo (com o mesmo PNG nos
  /// dois, o teste passaria mesmo sem recarregar: a imagem antiga ficaria
  /// na tela e o teste não veria a diferença).
  final vermelho = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC',
  );
  final azul = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNgYPgPAAEDAQAIicLsAAAAAElFTkSuQmCC',
  );

  ConsoleApi apiQueDevolve(Map<String, Uint8List> porPath) => ConsoleApi(
        baseUrl: 'http://host/functions/v1/kyc',
        accessToken: () async => 'jwt',
        inner: MockClient((req) async {
          // O objeto é pedido no bucket: `/storage/v1/object/kyc-docs/<path>`.
          for (final entrada in porPath.entries) {
            if (req.url.path.endsWith(entrada.key)) {
              return http.Response.bytes(entrada.value, 200);
            }
          }
          return http.Response('{}', 404);
        }),
      );

  Widget monta(Widget child) => MaterialApp(
        theme: buildLightTheme(),
        home: Scaffold(body: child),
      );

  /// Os bytes que a tela está EXIBINDO (o `Image.memory` que está no build).
  Uint8List? bytesNaTela(WidgetTester tester) {
    final image = tester.widget<Image>(find.byType(Image));
    final memory = image.image as MemoryImage;
    return memory.bytes;
  }

  testWidgets('o preview baixa o arquivo e mostra a imagem', (tester) async {
    final api = apiQueDevolve({'/a.png': png});

    await tester.pumpWidget(
      monta(DocumentPreview(api: api, path: 'a.png', label: 'CNH')),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('document-preview')), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    // A etiqueta diz que dá para ampliar.
    expect(find.text('Toque para ampliar'), findsOneWidget);
    // E o aviso de "não pôde abrir" NÃO aparece: o arquivo é uma imagem
    // de verdade e o aparelho decodificou.
    expect(find.text('Este arquivo não pôde ser aberto.'), findsNothing);
  });

  testWidgets('o servidor recusa: a tela mostra FALHA, não moldura vazia',
      (tester) async {
    final api = apiQueDevolve({});

    await tester.pumpWidget(
      monta(DocumentPreview(api: api, path: 'a.png', label: 'CNH')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Não foi possível carregar o documento.'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    expect(find.byKey(const ValueKey('document-retry')), findsOneWidget);
  });

  testWidgets('conteúdo que não é imagem também é FALHA', (tester) async {
    final api = apiQueDevolve({
      '/a.png': Uint8List.fromList([0x00, 0x01, 0x02, 0x03]),
    });

    await tester.pumpWidget(
      monta(DocumentPreview(api: api, path: 'a.png', label: 'CNH')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Não foi possível carregar o documento.'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('trocar o caminho recarrega (o preview não vira a foto antiga)',
      (tester) async {
    // Bytes DIFERENTES por path: com o mesmo PNG nos dois, o teste passaria
    // mesmo sem o `didUpdateWidget` (a imagem antiga continuaria na tela e
    // o `find.byType(Image)` acharia uma imagem) — o teste precisa poder
    // FALHAR.
    final api = apiQueDevolve({
      '/a.png': vermelho,
      '/b.png': azul,
    });

    await tester.pumpWidget(
      monta(DocumentPreview(api: api, path: 'a.png', label: 'CNH')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Toque para ampliar'), findsOneWidget);
    expect(bytesNaTela(tester), vermelho);

    // O mesmo widget, outro documento: o preview tem que buscar o NOVO
    // (sem `didUpdateWidget`, a tela mostraria a foto antiga com o rótulo
    // novo).
    await tester.pumpWidget(
      monta(DocumentPreview(api: api, path: 'b.png', label: 'CRLV')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Toque para ampliar'), findsOneWidget);
    expect(bytesNaTela(tester), azul,
        reason: 'o preview continuou com os bytes do documento anterior');
  });

  testWidgets('a resposta atrasada do caminho ANTIGO não vira a imagem',
      (tester) async {
    // O download do documento A é lento; a pessoa troca para o documento B
    // (que responde rápido). Quando A chega por último, ele NÃO pode
    // virar a imagem da tela — a tela está mostrando o B.
    final aLiberado = Completer<void>();
    final api = ConsoleApi(
      baseUrl: 'http://host/functions/v1/kyc',
      accessToken: () async => 'jwt',
      inner: MockClient((req) async {
        if (req.url.path.endsWith('/a.png')) {
          await aLiberado.future;
          return http.Response.bytes(vermelho, 200);
        }
        return http.Response.bytes(azul, 200);
      }),
    );

    await tester.pumpWidget(
      monta(DocumentPreview(api: api, path: 'a.png', label: 'CNH')),
    );
    await tester.pump(); // a requisição do A sai, mas não volta

    // A pessoa troca para o B.
    await tester.pumpWidget(
      monta(DocumentPreview(api: api, path: 'b.png', label: 'CRLV')),
    );
    await tester.pumpAndSettle();

    expect(bytesNaTela(tester), azul,
        reason: 'o documento B não foi o que ficou na tela');

    // A resposta atrasada do A chega agora.
    aLiberado.complete();
    await tester.pumpAndSettle();

    expect(bytesNaTela(tester), azul,
        reason: 'a resposta atrasada do documento anterior tomou a tela');
  });

  testWidgets('o botão de tentar de novo existe quando a imagem não decodifica',
      (tester) async {
    // Um arquivo que PASSA pela validação de "é imagem" (cabeçalho PNG),
    // mas que o decodificador não abre: o aviso aparece DENTRO da caixa
    // do preview — e precisa ter como recuperar.
    final api = apiQueDevolve({
      '/a.png': Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A]),
    });

    await tester.pumpWidget(
      monta(DocumentPreview(api: api, path: 'a.png', label: 'CNH')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Este arquivo não pôde ser aberto.'), findsOneWidget);
    expect(find.byKey(const ValueKey('document-retry-decode')), findsOneWidget);
  });

  testWidgets('o preview não quebra em 360x800 com a fonte em 2.0',
      (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = apiQueDevolve({'/a.png': png});

    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2.0)),
          child: child!,
        ),
        home: Scaffold(
          body: DocumentPreview(api: api, path: 'a.png', label: 'CNH'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets('o estado de FALHA não estoura em 360x800 com a fonte em 2.0',
      (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    // O servidor recusa: o aviso tem que caber (com a fonte grande, ele
    // não cabe em 200 px fixos — o preview precisa de altura variável).
    final api = apiQueDevolve({});

    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2.0)),
          child: child!,
        ),
        home: Scaffold(
          body: DocumentPreview(api: api, path: 'a.png', label: 'CNH'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('document-retry')), findsOneWidget);
  });
}
