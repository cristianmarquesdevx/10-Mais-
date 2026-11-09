import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:passageiro/src/screens/widgets/carousel_destaques.dart';
import 'package:passageiro/src/theme/theme.dart';

/// M4 — carrossel reutilizável do login: autoplay de 4 s, loop, pausa com o
/// dedo na tela e com campo focado, `disableAnimations` e `Semantics`.
void main() {
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
    bool disableAnimations = false,
    bool withField = false,
  }) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildLightTheme(),
      home: Builder(builder: (context) {
        Widget child = const SizedBox(
          width: 400,
          height: 400,
          child: CarouselDestaques(),
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

  semanticsTest('avança sozinho a cada 4 s', (tester) async {
    await pumpCarousel(tester);
    expect(find.bySemanticsLabel('Página 1 de 4'), findsOneWidget);

    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(milliseconds: 350));

    expect(find.bySemanticsLabel('Página 2 de 4'), findsOneWidget);
  });

  semanticsTest('pausa enquanto há campo focado', (tester) async {
    await pumpCarousel(tester, withField: true);
    await tester.showKeyboard(find.byType(TextField));
    await tester.pump();

    await tester.pump(const Duration(seconds: 8));

    expect(
      find.bySemanticsLabel('Página 1 de 4'),
      findsOneWidget,
      reason: 'com o campo focado o autoplay não pode rodar',
    );
  });

  semanticsTest('pausa com o dedo na tela e retoma ao soltar', (tester) async {
    await pumpCarousel(tester);

    final gesture =
        await tester.startGesture(tester.getCenter(find.byType(PageView)));
    await tester.pump(const Duration(seconds: 6));
    expect(
      find.bySemanticsLabel('Página 1 de 4'),
      findsOneWidget,
      reason: 'com o dedo na tela o autoplay fica pausado',
    );

    await gesture.up();
    await tester.pump();

    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(milliseconds: 350));
    expect(
      find.bySemanticsLabel('Página 2 de 4'),
      findsOneWidget,
      reason: 'ao soltar o autoplay volta a rodar',
    );
  });

  semanticsTest('com disableAnimations continua automático (salto)', (tester) async {
    await pumpCarousel(tester, disableAnimations: true);

    await tester.pump(const Duration(seconds: 4));

    expect(find.bySemanticsLabel('Página 2 de 4'), findsOneWidget);
  });

  semanticsTest('no último aviso volta ao primeiro (loop)', (tester) async {
    await pumpCarousel(tester);

    for (var i = 0; i < 3; i++) {
      await tester.drag(find.byType(PageView), const Offset(-280, 0));
      await tester.pumpAndSettle();
    }
    expect(find.bySemanticsLabel('Página 4 de 4'), findsOneWidget);

    await tester.pump(const Duration(seconds: 4));
    await tester.pump();

    expect(find.bySemanticsLabel('Página 1 de 4'), findsOneWidget);
  });

  semanticsTest('expõe rótulos para o leitor de tela', (tester) async {
    await pumpCarousel(tester);

    expect(find.bySemanticsLabel('Destaques do 10 é Mais'), findsOneWidget);
    expect(find.bySemanticsLabel('Sua corrida em segundos'), findsOneWidget);
    expect(find.bySemanticsLabel('Página 1 de 4'), findsOneWidget);
  });
}
