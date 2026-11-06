import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:parceiro/main.dart';
import 'package:parceiro/src/api/client.dart';
import 'package:parceiro/src/screens/screens.dart';
import 'package:parceiro/src/screens/widgets/carousel_destaques.dart';
import 'package:parceiro/src/screens/widgets/raspadinha_onboarding.dart';
import 'package:parceiro/src/state/partner_controller.dart';
import 'package:parceiro/src/theme/theme.dart';

/// M5 — onboarding da raspadinha: reutiliza o carrossel com as artes da
/// raspadinha, "Pular"/"Começar" em #0F8279, abre uma única vez por versão
/// de conteúdo e "Como funciona" para rever. Não mexe em mecânica/prêmios.
void main() {
  ({ApiClient api, PartnerController partner}) buildApi() {
    final api = ApiClient(
      baseUrl: 'http://test.local/functions/v1/v1',
      accessToken: () => 'jwt-test',
      inner: MockClient((req) async => http.Response(
            '{"campaigns": []}',
            200,
            headers: const {'content-type': 'application/json; charset=utf-8'},
          )),
    );
    return (api: api, partner: PartnerController(api));
  }

  Widget campanhasTree(ApiClient api, PartnerController partner) => AppScope(
        partner: partner,
        api: api,
        child: MaterialApp(
          theme: buildAppTheme(),
          home: const ScratchCampaignsScreen(),
        ),
      );

  test('flag: abre uma vez por versão de conteúdo', () async {
    SharedPreferences.setMockInitialValues({});
    expect(await RaspadinhaOnboardingPrefs.precisaMostrar(), isTrue,
        reason: 'nunca visto: precisa abrir');

    await RaspadinhaOnboardingPrefs.marcarVisto();
    expect(await RaspadinhaOnboardingPrefs.precisaMostrar(), isFalse,
        reason: 'visto: não abre de novo');

    // Conteúdo novo (versão mudou): volta a exigir o onboarding.
    SharedPreferences.setMockInitialValues({
      RaspadinhaOnboardingPrefs.chave: RaspadinhaOnboardingPrefs.versaoAtual - 1,
    });
    expect(await RaspadinhaOnboardingPrefs.precisaMostrar(), isTrue);
  });

  testWidgets('tela usa o carrossel da raspadinha e botões em #0F8279',
      (tester) async {
    final handle = tester.ensureSemantics();
    try {
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(),
        home: const RaspadinhaOnboardingScreen(),
      ));
      await tester.pump();

      expect(find.text('Como funciona a raspadinha'), findsOneWidget);
      expect(find.byType(CarouselDestaques), findsOneWidget);
      expect(find.bySemanticsLabel('Raspe e ganhe'), findsOneWidget);

      expect(RaspadinhaOnboardingScreen.acao, const Color(0xFF0F8279));

      final pular = tester
          .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Pular'));
      expect(pular.style?.foregroundColor?.resolve(const {}),
          RaspadinhaOnboardingScreen.acao);
      expect(pular.style?.side?.resolve(const {})?.color,
          RaspadinhaOnboardingScreen.acao);

      final comecar = tester.widget<ElevatedButton>(
          find.widgetWithText(ElevatedButton, 'Começar'));
      expect(comecar.style?.backgroundColor?.resolve(const {}),
          RaspadinhaOnboardingScreen.acao);
    } finally {
      handle.dispose();
    }
  });

  testWidgets('"Pular" e "Começar" fecham a tela', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => RaspadinhaOnboardingScreen.abrir(context),
              child: const Text('abrir'),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(ElevatedButton, 'abrir'));
    await tester.pumpAndSettle();
    expect(find.byType(RaspadinhaOnboardingScreen), findsOneWidget);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Pular'));
    await tester.pumpAndSettle();
    expect(find.byType(RaspadinhaOnboardingScreen), findsNothing);

    await tester.tap(find.widgetWithText(ElevatedButton, 'abrir'));
    await tester.pumpAndSettle();
    expect(find.byType(RaspadinhaOnboardingScreen), findsOneWidget);

    await tester.tap(find.widgetWithText(ElevatedButton, 'Começar'));
    await tester.pumpAndSettle();
    expect(find.byType(RaspadinhaOnboardingScreen), findsNothing);
  });

  testWidgets('abre na primeira visita e não abre na segunda',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final (:api, :partner) = buildApi();
    addTearDown(partner.dispose);

    await tester.pumpWidget(campanhasTree(api, partner));
    await tester.pumpAndSettle();
    expect(find.byType(RaspadinhaOnboardingScreen), findsOneWidget,
        reason: 'primeira visita: onboarding automático');

    await tester.tap(find.widgetWithText(OutlinedButton, 'Pular'));
    await tester.pumpAndSettle();
    await tester.pump();
    expect(find.byType(RaspadinhaOnboardingScreen), findsNothing);
    expect(await RaspadinhaOnboardingPrefs.precisaMostrar(), isFalse,
        reason: 'fechar o onboarding grava a versão vista');

    // Segunda visita: a tela monta de novo e nada abre sozinho.
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await tester.pumpWidget(campanhasTree(api, partner));
    await tester.pumpAndSettle();
    expect(find.byType(RaspadinhaOnboardingScreen), findsNothing);
  });

  testWidgets('com a versão já vista não abre; "Como funciona" reabre',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      RaspadinhaOnboardingPrefs.chave:
          RaspadinhaOnboardingPrefs.versaoAtual,
    });
    final (:api, :partner) = buildApi();
    addTearDown(partner.dispose);

    await tester.pumpWidget(campanhasTree(api, partner));
    await tester.pumpAndSettle();
    expect(find.byType(RaspadinhaOnboardingScreen), findsNothing,
        reason: 'já visto: não abre sozinho');

    await tester.tap(find.text('Como funciona'));
    await tester.pumpAndSettle();
    expect(find.byType(RaspadinhaOnboardingScreen), findsOneWidget,
        reason: '"Como funciona" rever quando quiser');

    await tester.tap(find.widgetWithText(ElevatedButton, 'Começar'));
    await tester.pumpAndSettle();
    expect(find.byType(RaspadinhaOnboardingScreen), findsNothing);
  });
}
