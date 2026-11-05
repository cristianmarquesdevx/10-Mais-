import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:passageiro/src/api/client.dart';
import 'package:passageiro/src/screens/detalhe_corrida_screen.dart';
import 'package:passageiro/src/theme/theme.dart';

/// A barra "Repetir viagem" do detalhe já usou `AppColors.surface` fixo e
/// ficava branca no tema escuro. Aqui a tela é renderizada com o tema escuro
/// real e a superfície é conferida contra o token escuro.

Widget darkApp(Widget home) => MaterialApp(
      theme: buildLightTheme(),
      darkTheme: buildDarkTheme(),
      themeMode: ThemeMode.dark,
      home: home,
    );

const _darkSurface = AppColorsDark.surface;
const _lightSurface = AppColors.surface;

Finder darkSurfaceBoxes() => find.byWidgetPredicate(
      (w) =>
          w is Container &&
          w.decoration is BoxDecoration &&
          (w.decoration! as BoxDecoration).color == _darkSurface,
    );

Finder lightSurfaceBoxes() => find.byWidgetPredicate(
      (w) =>
          w is Container &&
          w.decoration is BoxDecoration &&
          (w.decoration! as BoxDecoration).color == _lightSurface,
    );

void main() {
  testWidgets('detalhe da corrida: barra inferior usa a superfície escura',
      (tester) async {
    final ride = Ride(
      rideId: 'ride-1',
      status: RideStatus.finalizada,
      pricingMode: 'COMISSAO',
      fareTotal: 18.5,
      distanceKm: 4.2,
      origin: const GeoPoint(-8.7607, -63.9039),
      destination: const GeoPoint(-8.7700, -63.8900),
      originAddress: 'Rua A, 10',
      destinationAddress: 'Rua B, 20',
      paymentStatus: 'CONFIRMED',
      createdAt: DateTime(2026, 11, 2, 10, 30),
    );

    await tester.pumpWidget(darkApp(DetalheCorridaScreen(ride: ride)));
    // O mapa traça a rota em background; a barra inferior já existe no
    // primeiro frame. Dois pumps bastam e não dependem da rede.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Repetir viagem'), findsOneWidget);
    expect(darkSurfaceBoxes(), findsOneWidget,
        reason: 'a barra inferior deve usar AppColorsDark.surface');
    expect(lightSurfaceBoxes(), findsNothing,
        reason: 'nenhum Container pode manter a superfície clara no escuro');
  });
}
