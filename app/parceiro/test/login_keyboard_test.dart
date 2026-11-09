import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:parceiro/src/screens/screens.dart';

/// O teclado numérico do login não pode fechar sozinho quando o layout
/// muda para dar lugar ao cartão rolável.
void main() {
  testWidgets('teclado numérico continua aberto ao subir', (tester) async {
    await tester.pumpWidget(MaterialApp(home: LoginScreen(onDone: () {})));

    final phone = find.byType(TextField);
    await tester.tap(phone);
    await tester.pump();

    expect(tester.testTextInput.isVisible, isTrue,
        reason: 'a conexão do teclado deve estar aberta');

    tester.view.viewInsets = const FakeViewPadding(bottom: 320);
    addTearDown(tester.view.resetViewInsets);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(tester.testTextInput.isVisible, isTrue,
        reason: 'a conexão do teclado não pode cair na troca de layout');
  });
}
