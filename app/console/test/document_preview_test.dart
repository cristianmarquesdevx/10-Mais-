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
      monta(DocumentPreview(api: api, path: 'a.jpg', label: 'CNH')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Não foi possível carregar o documento.'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    expect(find.byKey(const ValueKey('document-retry')), findsOneWidget);
  });

  testWidgets('conteúdo que não é imagem também é FALHA', (tester) async {
    final api = apiQueDevolve({
      '/a.jpg': Uint8List.fromList([0x00, 0x01, 0x02, 0x03]),
    });

    await tester.pumpWidget(
      monta(DocumentPreview(api: api, path: 'a.jpg', label: 'CNH')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Não foi possível carregar o documento.'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('trocar o caminho recarrega (o preview não vira a foto antiga)',
      (tester) async {
    final api = apiQueDevolve({
      '/a.png': png,
      '/b.png': png,
    });

    await tester.pumpWidget(
      monta(DocumentPreview(api: api, path: 'a.png', label: 'CNH')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Toque para ampliar'), findsOneWidget);

    // O mesmo widget, outro documento: o preview tem que buscar o NOVO
    // (sem `didUpdateWidget`, a tela mostraria a foto antiga com o rótulo
    // novo).
    await tester.pumpWidget(
      monta(DocumentPreview(api: api, path: 'b.png', label: 'CRLV')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Toque para ampliar'), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
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
