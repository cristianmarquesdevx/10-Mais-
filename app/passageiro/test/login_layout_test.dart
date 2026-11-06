import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:passageiro/src/screens/screens.dart';
import 'package:passageiro/src/screens/widgets/carousel_destaques.dart';
import 'package:passageiro/src/theme/theme.dart';

/// M3 — o login precisa caber em 360dp, em tela grande e em tablet, com e
/// sem teclado, sem `RenderFlex overflow` e sem perder o cartão de entrada.
void main() {
  Future<void> pumpLogin(WidgetTester tester, Size size) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      theme: buildLightTheme(),
      home: LoginScreen(onDone: () {}),
    ));
    await tester.pump();
  }

  for (final size in const [
    Size(360, 640), // tela pequena
    Size(360, 800), // tela comum
    Size(800, 1200), // tablet
  ]) {
    testWidgets('login cabe em ${size.width.toInt()}x${size.height.toInt()}',
        (tester) async {
      await pumpLogin(tester, size);

      expect(tester.takeException(), isNull);
      expect(find.text('Entrar ou criar conta'), findsOneWidget);
      expect(find.byType(CarouselDestaques), findsOneWidget);
    });
  }

  testWidgets('rodapé do cartão fica visível e o cartão ancora no rodapé',
      (tester) async {
    await pumpLogin(tester, const Size(411, 914));

    final terms = find.text('Ao continuar você aceita os Termos de Uso.');
    expect(terms, findsOneWidget);
    expect(tester.getRect(terms).bottom, lessThanOrEqualTo(914),
        reason: 'o rodapé não pode ser cortado pela borda da tela');
    expect(tester.getTopLeft(find.text('Entrar ou criar conta')).dy,
        greaterThan(914 * 0.55),
        reason: 'o cartão deve ficar no rodapé, com o herói acima');
  });

  testWidgets('teclado aberto esconde o carrossel e mantém o cartão',
      (tester) async {
    await pumpLogin(tester, const Size(360, 640));
    expect(tester.takeException(), isNull, reason: 'antes do teclado');

    tester.view.viewInsets = const FakeViewPadding(bottom: 320);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(tester.takeException(), isNull);
    expect(find.byType(CarouselDestaques), findsNothing,
        reason: 'o carrossel deve sair de cena com o teclado aberto');
    expect(find.text('Entrar ou criar conta'), findsOneWidget);
  });

  testWidgets('com teclado o cartão ancora no rodapé, não no topo',
      (tester) async {
    await pumpLogin(tester, const Size(360, 800));

    tester.view.viewInsets = const FakeViewPadding(bottom: 320);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    const bodyHeight = 800 - 320;
    final titleTop =
        tester.getTopLeft(find.text('Entrar ou criar conta')).dy;
    expect(titleTop, greaterThan(bodyHeight * 0.25),
        reason: 'o cartão deve encostar no teclado, sem vazio no meio');
  });
}
