import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parceiro/main.dart';
import 'package:parceiro/src/api/client.dart';
import 'package:parceiro/src/screens/historico_screen.dart';
import 'package:parceiro/src/screens/veiculos_screen.dart';
import 'package:parceiro/src/state/partner_controller.dart';
import 'package:parceiro/src/theme/theme.dart';
import 'package:parceiro/src/widgets/offer_loss_sheet.dart';

/// Os cards destes três widgets já usaram `AppColors.surface` fixo e ficavam
/// brancos no tema escuro. Aqui cada um é renderizado com o tema escuro real
/// e a superfície é conferida contra o token escuro — não contra o claro.

/// Monta o widget no tema escuro do app.
Widget darkApp(Widget home) => MaterialApp(
      theme: buildLightTheme(),
      darkTheme: buildDarkTheme(),
      themeMode: ThemeMode.dark,
      home: home,
    );

/// A cor que o design system entrega no escuro.
const _darkSurface = AppColorsDark.surface;
const _lightSurface = AppColors.surface;

Finder darkSurfaceMaterials() => find.byWidgetPredicate(
      (w) => w is Material && w.color == _darkSurface,
    );

Finder lightSurfaceMaterials() => find.byWidgetPredicate(
      (w) => w is Material && w.color == _lightSurface,
    );

Finder darkSurfaceBoxes() => find.byWidgetPredicate(
      (w) =>
          w is Container &&
          w.decoration is BoxDecoration &&
          (w.decoration! as BoxDecoration).color == _darkSurface,
    );

http.Response _json(Object body) => http.Response(
      jsonEncode(body),
      200,
      headers: const {'content-type': 'application/json; charset=utf-8'},
    );

void main() {
  testWidgets('veículos: cards usam a superfície escura', (tester) async {
    await tester.pumpWidget(darkApp(const VeiculosScreen()));

    expect(darkSurfaceMaterials(), findsNWidgets(2),
        reason: 'os dois cards da garagem devem usar AppColorsDark.surface');
    expect(lightSurfaceMaterials(), findsNothing,
        reason: 'nenhum card pode manter a superfície clara no escuro');
  });

  testWidgets('histórico: card da corrida usa a superfície escura',
      (tester) async {
    final api = ApiClient(
      baseUrl: 'http://test.local/functions/v1/v1',
      accessToken: () => 'jwt-test',
      inner: MockClient((req) async => _json({
            'rides': [
              {
                'ride_id': 'ride-1',
                'status': 'FINALIZADA',
                'fare_total': 18.5,
                'origin_address': 'Rua A, 10',
                'destination_address': 'Rua B, 20',
                'created_at': '2026-11-02T10:30:00Z',
                'partner': {'name': 'Parceiro Teste'},
              }
            ],
          })),
    );
    final partner = PartnerController(api);

    await tester.pumpWidget(
      AppScope(
        partner: partner,
        api: api,
        child: darkApp(const HistoricoScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Histórico de corridas'), findsOneWidget);
    // O horário é convertido para o fuso local da máquina de teste.
    expect(find.textContaining('Concluída · 02/11'), findsOneWidget);
    expect(darkSurfaceMaterials(), findsOneWidget,
        reason: 'o card da corrida deve usar AppColorsDark.surface');
    expect(lightSurfaceMaterials(), findsNothing);

    partner.dispose();
  });

  testWidgets('oferta perdida: sheet usa a superfície escura', (tester) async {
    final loss = OfferLoss(
      offerId: 'offer-1',
      rideId: 'ride-1',
      reason: 'DECLINED',
      lostAmount: 12.5,
      pickupDistanceKm: 1.2,
      tripDistanceKm: 6.4,
      pickupEtaMin: 4,
      tripDurationMin: 12,
      acceptanceRateBefore: 0.95,
      acceptanceRate: 0.92,
    );

    await tester.pumpWidget(darkApp(Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () => showOfferLossSheet(context, loss),
          child: const Text('abrir'),
        ),
      ),
    )));

    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();

    expect(find.text('Oferta recusada'), findsOneWidget);
    expect(darkSurfaceBoxes(), findsOneWidget,
        reason: 'o fundo do sheet deve usar AppColorsDark.surface');
  });
}
