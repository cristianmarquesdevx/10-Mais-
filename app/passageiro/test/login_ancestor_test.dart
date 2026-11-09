import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:passageiro/src/screens/screens.dart';

/// Regressão do erro "Looking up a deactivated widget's ancestor is unsafe".
///
/// A troca de layout do login (teclado abre/fecha) move o cartão com
/// `GlobalKey` e desativa o `TextField` focado por alguns instantes. O
/// carrossel do herói nasce exatamente nesse instante e lia o ancestral do
/// campo a partir do contexto desativado — o que estourava o assert do
/// Flutter. A correção lê o nó focado pelo `FocusScope` da tela.
void main() {
  testWidgets('troca de layout do teclado não estoura erro de ancestral',
      (tester) async {
    await tester.pumpWidget(MaterialApp(home: LoginScreen(onDone: () {})));

    final phone = find.byKey(const ValueKey('login-phone'));
    await tester.tap(phone);
    await tester.pump();

    // Teclado sobe: o herói (com o carrossel) sai de cena.
    tester.view.viewInsets = const FakeViewPadding(bottom: 320);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // Teclado desce: o herói volta e o cartão é reposicionado.
    tester.view.viewInsets = FakeViewPadding.zero;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(tester.takeException(), isNull);
  });

  testWidgets('troca de etapa (campo sai da árvore) não estoura',
      (tester) async {
    await tester.pumpWidget(MaterialApp(home: LoginScreen(onDone: () {})));

    await tester.enterText(
      find.byKey(const ValueKey('login-phone')),
      '69999999999',
    );
    await tester.tap(find.text('CONTINUAR'));
    await tester.pump();
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  testWidgets('após a troca de layout o carrossel segue pausado com o campo '
      'focado', (tester) async {
    final handle = tester.ensureSemantics();
    try {
      await tester.pumpWidget(MaterialApp(home: LoginScreen(onDone: () {})));

      await tester.tap(find.byKey(const ValueKey('login-phone')));
      await tester.pump();

      // Teclado sobe (herói sai) e desce (herói volta com o carrossel).
      tester.view.viewInsets = const FakeViewPadding(bottom: 320);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      tester.view.viewInsets = FakeViewPadding.zero;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // O campo continua focado: o autoplay do carrossel não pode rodar.
      await tester.pump(const Duration(seconds: 8));

      expect(
        find.bySemanticsLabel('Página 1 de 4'),
        findsOneWidget,
        reason: 'com o campo focado o autoplay não pode rodar',
      );
    } finally {
      handle.dispose();
    }
  });
}
