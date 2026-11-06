import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:parceiro/src/assets/app_assets.dart';
import 'package:parceiro/src/screens/widgets/carousel_destaques.dart';
import 'package:parceiro/src/theme/theme.dart';

/// M4 — carrossel reutilizável do login: autoplay de 4 s, loop, pausa com o
/// dedo na tela e com campo focado, `disableAnimations` e `Semantics`.
///
/// Por padrão o parceiro mostra um único pôster (ganhos do motorista); os
/// casos de autoplay/loop usam os cinco pôsteres via `items`.
void main() {
  final multiItems = AppAssets.carrosselLoginTodos
      .map((imagem) => <String, dynamic>{'imagem': imagem})
      .toList(growable: false);

  /// O `SemanticsHandle` precisa ser liberado dentro do corpo do teste: a
  /// verificação do `flutter_test` roda antes dos `addTearDown`.
  void semanticsTest(
    String description,
    Future<void> Function(WidgetTester tester) body,
  ) {
    testWidgets(description, (tester) async {
      final handle = tester.ensureSemantics();
      try {
        await body(tester);
      } finally {
        handle.dispose();
      }
    });
  }

  Future<void> pumpCarousel(
    WidgetTester tester, {
    List<Map<String, dynamic>> items = const [],
    bool disableAnimations = false,
    bool withField = false,
  }) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildLightTheme(),
      home: Builder(builder: (context) {
        Widget child = SizedBox(
          width: 400,
          height: 400,
          child: CarouselDestaques(items: items),
        );
        if (withField) {
          child = Column(
            children: [
              child,
              const TextField(),
            ],
          );
        }
        if (disableAnimations) {
          child = MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child,
          );
        }
        return Scaffold(body: child);
      }),
    ));
    await tester.pump();
  }

  semanticsTest('por padrão mostra só o pôster do motorista', (tester) async {
    await pumpCarousel(tester);

    expect(find.bySemanticsLabel('Destaques do 10 é Mais'), findsOneWidget);
    expect(
      find.bySemanticsLabel('Mais ganhos para o motorista'),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel('Página 1 de 1'), findsOneWidget);

    // Um único item: não há para onde avançar.
    await tester.pump(const Duration(seconds: 8));
    expect(find.bySemanticsLabel('Página 1 de 1'), findsOneWidget);
  });

  semanticsTest('avança sozinho a cada 4 s', (tester) async {
    await pumpCarousel(tester, items: multiItems);
    expect(find.bySemanticsLabel('Página 1 de 5'), findsOneWidget);

    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(milliseconds: 350));

    expect(find.bySemanticsLabel('Página 2 de 5'), findsOneWidget);
  });

  semanticsTest('pausa enquanto há campo focado', (tester) async {
    await pumpCarousel(tester, items: multiItems, withField: true);
    await tester.showKeyboard(find.byType(TextField));
    await tester.pump();

    await tester.pump(const Duration(seconds: 8));

    expect(
      find.bySemanticsLabel('Página 1 de 5'),
      findsOneWidget,
      reason: 'com o campo focado o autoplay não pode rodar',
    );
  });

  semanticsTest('pausa com o dedo na tela e retoma ao soltar', (tester) async {
    await pumpCarousel(tester, items: multiItems);

    final gesture =
        await tester.startGesture(tester.getCenter(find.byType(PageView)));
    await tester.pump(const Duration(seconds: 6));
    expect(
      find.bySemanticsLabel('Página 1 de 5'),
      findsOneWidget,
      reason: 'com o dedo na tela o autoplay fica pausado',
    );

    await gesture.up();
    await tester.pump();

    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(milliseconds: 350));
    expect(
      find.bySemanticsLabel('Página 2 de 5'),
      findsOneWidget,
      reason: 'ao soltar o autoplay volta a rodar',
    );
  });

  semanticsTest('não faz autoplay com disableAnimations', (tester) async {
    await pumpCarousel(tester, items: multiItems, disableAnimations: true);

    await tester.pump(const Duration(seconds: 10));

    expect(find.bySemanticsLabel('Página 1 de 5'), findsOneWidget);
  });

  semanticsTest('no último aviso volta ao primeiro (loop)', (tester) async {
    await pumpCarousel(tester, items: multiItems);

    for (var i = 0; i < 4; i++) {
      await tester.drag(find.byType(PageView), const Offset(-280, 0));
      await tester.pumpAndSettle();
    }
    expect(find.bySemanticsLabel('Página 5 de 5'), findsOneWidget);

    await tester.pump(const Duration(seconds: 4));
    await tester.pump();

    expect(find.bySemanticsLabel('Página 1 de 5'), findsOneWidget);
  });

  semanticsTest('expõe rótulos para o leitor de tela', (tester) async {
    await pumpCarousel(tester);

    expect(find.bySemanticsLabel('Destaques do 10 é Mais'), findsOneWidget);
    expect(
      find.bySemanticsLabel('Mais ganhos para o motorista'),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel('Página 1 de 1'), findsOneWidget);
  });
}
