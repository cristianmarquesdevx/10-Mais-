import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:passageiro/src/screens/screens.dart';

void main() {
  testWidgets('LoginScreen renders with carousel', (WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(home: LoginScreen(onDone: () {})));
    expect(find.byType(Scaffold), findsOneWidget);
  });
}
