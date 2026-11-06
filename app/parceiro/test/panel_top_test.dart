import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parceiro/main.dart';
import 'package:parceiro/src/api/client.dart';
import 'package:parceiro/src/screens/screens.dart';
import 'package:parceiro/src/state/partner_controller.dart';
import 'package:parceiro/src/theme/theme.dart';
import 'package:parceiro/src/widgets/heatmap_map.dart';
import 'package:parceiro/src/widgets/wallet_balance_card.dart';

/// Fase 1 — topo minimalista + saldo flutuante do motorista.
///
/// O que estes testes travam (para a Fase 2 não desfazer sem querer):
/// 1. o topo tem **só** menu + saldo (o chip de status, o chip de
///    passe/comissão e o botão "+ ✓" saíram);
/// 2. o saldo é do servidor, tem Semantics em reais e abre a Carteira;
/// 3. o "olho" oculta o valor (privacidade);
/// 4. a camada de demanda nunca mostra número sem marcar DEMO, e sem dado
///    real diz "sem dados de demanda".
http.Response resp(String body, int statusCode) => http.Response(
      body,
      statusCode,
      headers: const {'content-type': 'application/json; charset=utf-8'},
    );

const mePartner = '{"user_id":"u1","role":"PARTNER","partner":{'
    '"kyc_status":"APPROVED","monetization_mode":"PASSE_ATIVO",'
    '"pass_expires_at":"2099-01-01T12:00:00Z",'
    '"wallet_balance":134.5,"debt_cents":0}}';

/// Resposta de /heatmap com uma zona marcada como demonstração.
const heatDemo = '{"generated_at":"2026-11-06T12:00:00Z","demo":true,'
    '"source":"demo","zones":[{"lat":-8.7647,"lon":-63.9040,'
    '"weight":0.95,"label":"Centro","calls_last_hour":38}]}';

/// Resposta de /heatmap sem nenhuma zona (estado honesto).
const heatEmpty = '{"generated_at":"2026-11-06T12:00:00Z","demo":true,'
    '"source":"demo","zones":[]}';

({Widget widget, PartnerController partner}) buildApp({
  required MockClient mock,
  Widget home = const PainelScreen(onMenu: _noop),
}) {
  final api = ApiClient(
    baseUrl: 'http://test.local/functions/v1/v1',
    accessToken: () => 'jwt-test',
    inner: mock,
  );
  final partner = PartnerController(api);
  return (
    widget: AppScope(
      partner: partner,
      api: api,
      child: MaterialApp(
        theme: buildAppTheme(),
        home: home,
        routes: {
          '/carteira': (_) => const CarteiraScreen(),
          '/onboarding': (_) => const OnboardingScreen(),
        },
      ),
    ),
    partner: partner,
  );
}

/// Pump de alguns quadros: o mapa tem animação repetida (pulso/calor) e o
/// shimmer do saldo é um ticker infinito — `pumpAndSettle` neveria.
Future<void> pumpFrames(WidgetTester tester, {int frames = 6}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

void _noop() {}

void main() {
  testWidgets('Topo minimalista: só menu + saldo (sem OFFLINE, sem chip de '
      'passe/comissão, sem "+ ✓")', (tester) async {
    final (widget: app, partner: p) = buildApp(
      mock: MockClient((req) async {
        if (req.url.path.endsWith('/me')) return resp(mePartner, 200);
        if (req.url.path.endsWith('/partner/wallet')) {
          return resp('{"balance":134.5,"debt_cents":0,"statement":[]}', 200);
        }
        if (req.url.path.endsWith('/heatmap')) return resp(heatEmpty, 200);
        return resp('{}', 200);
      }),
    );

    await tester.pumpWidget(app);
    await pumpFrames(tester);

    // O saldo flutuante existe e é o único elemento à direita do topo.
    expect(find.byType(WalletBalanceCard), findsOneWidget);
    expect(find.byIcon(Icons.menu_rounded), findsOneWidget);

    // Chips que foram do topo para o painel inferior / para a cor do
    // marcador não podem reaparecer no topo.
    expect(find.text('OFFLINE'), findsNothing);
    expect(find.text('ONLINE'), findsNothing);
    expect(find.text('PASSE · 100% seu'), findsNothing);
    expect(find.text('COMISSÃO 12%'), findsNothing);

    // O "+ ✓" era decorativo: some com o topo, junto com a marca.
    expect(find.byIcon(Icons.add), findsNothing);

    p.dispose();
  });

  testWidgets('Saldo: valor do servidor em reais, com Semantics e números '
      'tabulares', (tester) async {
    final (widget: app, partner: p) = buildApp(
      mock: MockClient((req) async {
        if (req.url.path.endsWith('/me')) return resp(mePartner, 200);
        if (req.url.path.endsWith('/partner/wallet')) {
          return resp('{"balance":1234.56,"debt_cents":0,"statement":[]}', 200);
        }
        if (req.url.path.endsWith('/heatmap')) return resp(heatEmpty, 200);
        return resp('{}', 200);
      }),
    );

    await tester.pumpWidget(app);
    await pumpFrames(tester);

    // Milhar com ponto, decimal com vírgula — padrão pt-BR.
    expect(find.text('R\$ 1.234,56'), findsOneWidget);

    // Leitor de tela: "Saldo da carteira: X reais".
    expect(
      find.bySemanticsLabel('Saldo da carteira: 1234,56 reais'),
      findsOneWidget,
    );

    p.dispose();
  });

  testWidgets('Saldo: o "olho" oculta o valor (privacidade na rua)',
      (tester) async {
    final (widget: app, partner: p) = buildApp(
      mock: MockClient((req) async {
        if (req.url.path.endsWith('/me')) return resp(mePartner, 200);
        if (req.url.path.endsWith('/partner/wallet')) {
          return resp('{"balance":1234.56,"debt_cents":0,"statement":[]}', 200);
        }
        if (req.url.path.endsWith('/heatmap')) return resp(heatEmpty, 200);
        return resp('{}', 200);
      }),
    );

    await tester.pumpWidget(app);
    await pumpFrames(tester);

    expect(find.text('R\$ 1.234,56'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Ocultar saldo'));
    await pumpFrames(tester, frames: 3);

    expect(find.text('R\$ 1.234,56'), findsNothing);
    expect(find.text('••••'), findsOneWidget);
    expect(
      find.bySemanticsLabel('Saldo da carteira: oculto'),
      findsOneWidget,
    );

    // E volta a mostrar quando pedido.
    await tester.tap(find.bySemanticsLabel('Mostrar saldo'));
    await pumpFrames(tester, frames: 3);
    expect(find.text('R\$ 1.234,56'), findsOneWidget);

    p.dispose();
  });

  testWidgets('Saldo: tocar abre a Carteira', (tester) async {
    final (widget: app, partner: p) = buildApp(
      mock: MockClient((req) async {
        if (req.url.path.endsWith('/me')) return resp(mePartner, 200);
        if (req.url.path.endsWith('/partner/wallet')) {
          return resp('{"balance":134.5,"debt_cents":0,"statement":[]}', 200);
        }
        if (req.url.path.endsWith('/heatmap')) return resp(heatEmpty, 200);
        return resp('{}', 200);
      }),
    );

    await tester.pumpWidget(app);
    await pumpFrames(tester);

    await tester.tap(find.byType(WalletBalanceCard));
    await pumpFrames(tester);

    expect(find.byType(CarteiraScreen), findsOneWidget);

    p.dispose();
  });

  testWidgets('Demanda: dado de demonstração vem marcado como DEMO',
      (tester) async {
    final (widget: app, partner: p) = buildApp(
      mock: MockClient((req) async {
        if (req.url.path.endsWith('/me')) return resp(mePartner, 200);
        if (req.url.path.endsWith('/partner/wallet')) {
          return resp('{"balance":134.5,"debt_cents":0,"statement":[]}', 200);
        }
        if (req.url.path.endsWith('/heatmap')) return resp(heatDemo, 200);
        return resp('{}', 200);
      }),
    );

    await tester.pumpWidget(app);
    await pumpFrames(tester);

    // Marca d'água no mapa.
    expect(find.text('DEMO · dados simulados'), findsOneWidget);
    // E o rótulo da camada diz que é simulado.
    expect(find.text('DEMO · 1 zonas (simulado)'), findsOneWidget);
    // Nunca aparece como se fosse real.
    expect(find.text('1 zonas quentes'), findsNothing);

    p.dispose();
  });

  testWidgets('Demanda: sem dado real o app diz que não tem dado',
      (tester) async {
    final (widget: app, partner: p) = buildApp(
      mock: MockClient((req) async {
        if (req.url.path.endsWith('/me')) return resp(mePartner, 200);
        if (req.url.path.endsWith('/partner/wallet')) {
          return resp('{"balance":134.5,"debt_cents":0,"statement":[]}', 200);
        }
        if (req.url.path.endsWith('/heatmap')) return resp(heatEmpty, 200);
        return resp('{}', 200);
      }),
    );

    await tester.pumpWidget(app);
    await pumpFrames(tester);

    expect(find.text('Sem dados de demanda agora'), findsOneWidget);
    expect(find.textContaining('zonas quentes'), findsNothing);
    expect(find.text('DEMO · dados simulados'), findsNothing);

    p.dispose();
  });

  testWidgets('Marcador: teal online e cinza offline (status no mapa)',
      (tester) async {
    Future<void> pumpMarker({required bool online}) async {
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(),
        home: HeatmapMap(
          zones: const [],
          online: online,
          showAttribution: false,
        ),
      ));
      await tester.pump(const Duration(milliseconds: 50));
    }

    await pumpMarker(online: true);
    expect(
      find.bySemanticsLabel('Sua posição: motorista online'),
      findsOneWidget,
    );

    await pumpMarker(online: false);
    expect(
      find.bySemanticsLabel('Sua posição: motorista offline'),
      findsOneWidget,
    );
  });
}
