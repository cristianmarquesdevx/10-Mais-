import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:passageiro/src/screens/screens.dart';

/// M6 — o campo de e-mail precisa ser um campo NOVO, com teclado de letras.
///
/// O bug original: os dois passos ocupavam o mesmo slot da árvore, o
/// `TextField` era reaproveitado e a conexão do teclado numérico continuava
/// viva. Aqui garantimos a estrutura que impede a regressão.
void main() {
  Future<void> goToEmail(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(home: LoginScreen(onDone: () {})));
    await tester.enterText(
      find.byKey(const ValueKey('login-phone')),
      '69999999999',
    );
    await tester.tap(find.text('CONTINUAR'));
    await tester.pump(); // troca de etapa
    await tester.pump(); // foco pedido no post-frame
  }

  testWidgets('e-mail tem identidade própria e teclado de letras', (tester) async {
    await goToEmail(tester);

    final field = tester.widget<TextField>(
      find.byKey(const ValueKey('login-email')),
    );

    expect(field.keyboardType, TextInputType.emailAddress);
    expect(field.textInputAction, TextInputAction.done);
    expect(field.autocorrect, isFalse);
    expect(field.enableSuggestions, isFalse);
    expect(field.autofillHints, contains(AutofillHints.email));
    expect(field.inputFormatters, isNull,
        reason: 'e-mail não pode herdar máscara numérica do celular');
    expect(field.focusNode?.hasFocus, isTrue,
        reason: 'o foco deve migrar para o e-mail sem toque manual');
  });

  testWidgets('e-mail inválido mostra erro em português e não avança',
      (tester) async {
    await goToEmail(tester);

    await tester.enterText(
      find.byKey(const ValueKey('login-email')),
      'sem-arroba',
    );
    await tester.tap(find.text('CONTINUAR'));
    await tester.pump();

    expect(find.textContaining('e-mail válido'), findsOneWidget);
    expect(find.text('Código de verificação'), findsNothing);
  });

  testWidgets('e-mail válido avança e leva o foco para o código', (tester) async {
    await goToEmail(tester);

    await tester.enterText(
      find.byKey(const ValueKey('login-email')),
      'teste@dezemais.app',
    );
    await tester.tap(find.text('CONTINUAR'));
    await tester.pump();
    await tester.pump();

    final otp = tester.widget<TextField>(
      find.byKey(const ValueKey('login-otp')),
    );
    expect(otp.keyboardType, TextInputType.number);
    expect(otp.focusNode?.hasFocus, isTrue);
  });
}
