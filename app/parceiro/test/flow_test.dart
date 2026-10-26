import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart' show LocationAccuracy;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parceiro/main.dart';
import 'package:parceiro/src/api/client.dart';
import 'package:parceiro/src/location/location_service.dart';
import 'package:parceiro/src/screens/navegacao_screen.dart';
import 'package:parceiro/src/screens/screens.dart';
import 'package:parceiro/src/state/partner_controller.dart';
import 'package:parceiro/src/theme/theme.dart';

/// Fluxos do parceiro contra o contrato: painel → online → oferta →
/// aceitar → em corrida → finalizar; gate KYC (F9); carteira.
/// Monta o app com API mockada. [partner] deve receber `dispose` ao fim do
/// teste (encerra o poll periódico — o binding falha com timer pendente).
///
/// [resp] mocka o servidor com charset UTF-8 (JSON é UTF-8 por padrão —
/// RFC 8259; o pacote http codifica latin1 quando o header omite charset).
http.Response resp(String body, int statusCode) => http.Response(
      body,
      statusCode,
      headers: const {'content-type': 'application/json; charset=utf-8'},
    );

/// Posição do Centro de Porto Velho nos testes: o plugin real não existe no
/// runner, mas o fluxo que depende de GPS precisa de uma leitura válida.
class _FixedLocation extends LocationService {
  const _FixedLocation();

  static LocationFix get _fix => LocationFix(
        lat: -8.7607,
        lon: -63.9039,
        accuracyM: 5,
        at: DateTime.now(),
      );

  @override
  Future<LocationFix> current({
    Duration timeout = const Duration(seconds: 10),
    LocationAccuracy accuracy = LocationAccuracy.high,
  }) async =>
      _fix;

  @override
  Future<LocationFix?> tryCurrent({
    Duration timeout = const Duration(seconds: 8),
    LocationAccuracy accuracy = LocationAccuracy.high,
  }) async =>
      _fix;

  @override
  Future<void> openSettings() async {}
}
({Widget widget, PartnerController partner}) buildApp({
  MockClient? mock,
  Widget home = const PainelScreen(),
}) {
  final api = ApiClient(
    baseUrl: 'http://test.local/functions/v1/v1',
    accessToken: () => 'jwt-test',
    inner: mock ?? MockClient((req) async => defaultResp(req)),
  );
  final partner = PartnerController(api, location: const _FixedLocation());
  return (
    widget: AppScope(
      partner: partner,
      api: api,
      child: MaterialApp(
        theme: buildAppTheme(),
        home: home,
        routes: {
          '/onboarding': (_) => const OnboardingScreen(),
          '/oferta': (_) => const OfertaScreen(),
          '/em-corrida': (_) => const EmCorridaScreen(),
          '/passe': (_) => const PasseScreen(),
          '/carteira': (_) => const CarteiraScreen(),
          '/configurar-solicitacoes': (_) =>
              const ConfigurarSolicitacoesScreen(),
          '/status-solicitacao': (_) => const StatusSolicitacaoScreen(),
        },
      ),
    ),
    partner: partner,
  );
}

/// Mock padrão: lista vazia onde o contrato exige array (o client é estrito).
http.Response defaultResp(http.Request req) =>
    req.url.path.endsWith('/offers/mine')
        ? resp('{"offers": []}', 200)
        : resp('{}', 200);

/// Oferta com timeout relativo ao relógio real — o cronômetro de P3 conta a
/// partir de `timeout_at` do servidor (15 s de PRM), não de um instante fixo.
String offerJsonNow() {
  final timeout =
      DateTime.now().toUtc().add(const Duration(seconds: 15)).toIso8601String();
  return '{"offers":[{'
      '"offer_id":"11111111-2222-3333-4444-555555555555",'
      '"ride_id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",'
      '"amount":18.5,"pickup_distance_km":1.2,"trip_distance_km":4.8,'
      '"destination_area":"B. São Pedro",'
      '"service":"MOTO","pickup_eta_min":2,"trip_duration_min":10,'
      '"price_multiplier":1.33,'
      '"origin":{"lat":-8.7607,"lon":-63.9039},'
      '"destination":{"lat":-8.7647,"lon":-63.8969},'
      '"passenger_name":"Passageira demo","passenger_rating":4.9,'
      '"dispatch":{"rank":1,"pool":3,"score":0.81,'
      '"components":{"eta":0.93,"rating":0.93},'
      '"online_seconds":742,"rating":4.9,"rating_count":128,'
      '"acceptance_rate":0.97,"vehicle":"Moto"},'
      '"timeout_at":"$timeout"}]}';
}

const mePartnerApproved = '{"user_id":"u1","role":"PARTNER","partner":{'
    '"kyc_status":"APPROVED","monetization_mode":"PASSE_ATIVO",'
    '"pass_expires_at":"2099-01-01T12:00:00Z",'
    '"wallet_balance":134.5,"debt_cents":0}}';

/// Fechamento da oferta: o servidor é quem diz o que foi perdido e como o
/// aceite ficou depois (95% → 92% pela penalização suave de 3%).
String lossJson(String reason) => '{"loss":{'
    '"offer_id":"11111111-2222-3333-4444-555555555555",'
    '"ride_id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",'
    '"reason":"$reason","lost_amount":18.5,'
    '"pickup_distance_km":1.2,"pickup_eta_min":2,'
    '"trip_distance_km":4.8,"trip_duration_min":10,'
    '"acceptance_rate_before":0.95,"acceptance_rate":0.9215,'
    '"timeout_s":15}}';

const rideAceita = '{"ride_id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",'
    '"status":"ACEITA","pricing_mode":"PASSE",'
    '"origin_address":"Centro","destination_address":"B. São Pedro",'
    '"created_at":"2026-10-10T12:00:00Z"}';

void main() {
  testWidgets('Apresentação: arte de abertura e toque segue para o login',
      (tester) async {
    var done = false;
    await tester.pumpWidget(MaterialApp(
      home: ApresentacaoScreen(onDone: () => done = true),
    ));
    await tester.pump();

    expect(find.byType(ApresentacaoScreen), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);

    // O toque pula a espera e cancela o timer de auto-avanço.
    await tester.tap(find.byType(ApresentacaoScreen));
    await tester.pump();
    expect(done, isTrue);
  });

  testWidgets('P2 painel: chip PASSE + PassCard + carteira para parceiro aprovado',
      (tester) async {
    final (widget: app, partner: p) = buildApp(
      mock: MockClient((req) async {
        if (req.url.path.endsWith('/me')) return resp(mePartnerApproved, 200);
        return resp('{}', 200);
      }),
    );

    await tester.pumpWidget(app);
    await tester.pumpAndSettle();

    expect(find.text('PASSE · 100% seu'), findsOneWidget);
    expect(find.textContaining('Passe ativo'), findsOneWidget);
    expect(find.textContaining('Carteira: R\$ 134,50'), findsOneWidget);
    expect(find.text('FICAR ONLINE'), findsOneWidget);
    p.dispose();
  });

  testWidgets('P2 → P3 → aceitar envia POST accept com Idempotency-Key e '
      'entra em EM_CORRIDA', (tester) async {
    http.Request? accepted;
    final (widget: app, partner: p) = buildApp(
      mock: MockClient((req) async {
        if (req.url.path.endsWith('/me')) return resp(mePartnerApproved, 200);
        if (req.method == 'POST' && req.url.path.endsWith('/partner/online')) {
          return resp('{"mode":"PASSE_ATIVO"}', 200);
        }
        if (req.url.path.endsWith('/offers/mine')) return resp(offerJsonNow(), 200);
        if (req.method == 'POST' && req.url.path.endsWith('/accept')) {
          accepted = req;
          return resp('{}', 200);
        }
        if (req.url.path.endsWith('/rides/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee')) {
          return resp(rideAceita, 200);
        }
        return resp('{}', 200);
      }),
    );

    await tester.pumpWidget(app);
    await tester.pumpAndSettle();

    await tester.tap(find.text('FICAR ONLINE'));
    await tester.pumpAndSettle();

    // Oferta chegou → P3 abre sobre o painel (auto-navegação)
    expect(find.textContaining('18,50'), findsOneWidget);
    expect(find.text('ACEITAR'), findsOneWidget);
    // Hierarquia OfferCard: bruto > coleta > total > destino > cronômetro
    expect(find.textContaining('Coleta a 1,2 km'), findsOneWidget);
    expect(find.textContaining('Corrida de 4,8 km'), findsOneWidget);
    expect(find.textContaining('B. São Pedro'), findsOneWidget);
    // O que é a oferta e por que o preço está acima da base (multiplicador).
    expect(find.text('Moto'), findsOneWidget);
    expect(find.textContaining('Preço ×1,33'), findsOneWidget);
    // Tempo de cada perna: o parceiro decide olhando minutos, não só km.
    expect(find.textContaining('≈ 2 min até o embarque'), findsOneWidget);
    expect(find.textContaining('≈ 10 min até o destino'), findsOneWidget);
    expect(find.text('4,9'), findsOneWidget,
        reason: 'nota do passageiro no padrão pt-BR');
    // Despacho: o parceiro precisa ver POR QUE esta oferta veio para ele.
    // Fica no fim da lista (preço e coleta vêm antes), então rola até lá.
    // O arrasto sai do topo da lista: em cima do mapa o gesto é do mapa.
    final list = find.byType(ListView).first;
    for (var i = 0;
        i < 6 && find.text('Por que esta oferta é sua').evaluate().isEmpty;
        i++) {
      await tester.dragFrom(
          tester.getTopLeft(list) + const Offset(24, 12),
          const Offset(0, -240));
      await tester.pumpAndSettle();
    }
    expect(find.text('Por que esta oferta é sua'), findsOneWidget);
    expect(find.text('1º de 3 na fila'), findsOneWidget);
    expect(find.text('1,2 km · 2 min'), findsOneWidget);
    expect(find.text('12 min'), findsOneWidget, reason: 'tempo online');
    expect(find.text('4,9 · 128 aval.'), findsOneWidget);
    expect(find.text('aceite 97%'), findsOneWidget);
    // Cronômetro vem do timeout_at do servidor (15 s de PRM), não de fixed.
    expect(find.textContaining(RegExp(r'^\d+ s$')), findsOneWidget);

    await tester.tap(find.text('ACEITAR'));
    await tester.pumpAndSettle();

    expect(accepted, isNotNull, reason: 'POST /offers/{id}/accept deve disparar');
    expect(accepted!.headers['Idempotency-Key'], isNotNull);
    expect(find.text('Em corrida'), findsOneWidget);
    expect(find.text('A CAMINHO'), findsOneWidget);
    expect(find.textContaining('PASSE · 100% seu'), findsOneWidget);
    p.dispose();
  });

  testWidgets('P3 recusa: explica o que o parceiro perdeu e o efeito no aceite',
      (tester) async {
    var served = 0;
    http.Request? declined;
    final (widget: app, partner: p) = buildApp(
      mock: MockClient((req) async {
        if (req.url.path.endsWith('/me')) return resp(mePartnerApproved, 200);
        if (req.method == 'POST' && req.url.path.endsWith('/partner/online')) {
          return resp('{"mode":"PASSE_ATIVO"}', 200);
        }
        if (req.url.path.endsWith('/offers/mine')) {
          served++;
          return resp(served == 1 ? offerJsonNow() : '{"offers": []}', 200);
        }
        if (req.method == 'POST' && req.url.path.endsWith('/decline')) {
          declined = req;
          return resp(lossJson('DECLINED'), 200);
        }
        return resp('{}', 200);
      }),
    );

    await tester.pumpWidget(app);
    await tester.pumpAndSettle();
    await tester.tap(find.text('FICAR ONLINE'));
    await tester.pumpAndSettle();
    expect(find.text('ACEITAR'), findsOneWidget);

    await tester.tap(find.text('Recusar'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500)); // sheet entra

    expect(declined, isNotNull, reason: 'POST /offers/{id}/decline');
    // A consequência não é mensagem genérica: valor congelado, corrida e o
    // aceite antes/depois vêm da resposta do servidor.
    expect(find.text('Oferta recusada'), findsOneWidget);
    expect(find.text('Você deixou de ganhar'), findsOneWidget);
    expect(find.textContaining('18,50'), findsWidgets);
    expect(find.textContaining('1,2 km · 2 min'), findsOneWidget);
    expect(find.textContaining('4,8 km · 10 min'), findsOneWidget);
    expect(find.text('Sua prioridade nas próximas chamadas'), findsOneWidget);
    expect(find.text('Aceite 95%'), findsOneWidget);
    expect(find.text('92%'), findsOneWidget);

    await tester.tap(find.text('ENTENDI'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500)); // sai + volta
    expect(find.text('Oferta recusada'), findsNothing);
    expect(find.text('ACEITAR'), findsNothing); // voltou ao painel
    p.dispose();
  });

  testWidgets('P3 timeout: a oferta vencida explica a perda em vez de sumir',
      (tester) async {
    var served = 0;
    String? askedOutcome;
    final (widget: app, partner: p) = buildApp(
      mock: MockClient((req) async {
        if (req.url.path.endsWith('/me')) return resp(mePartnerApproved, 200);
        if (req.method == 'POST' && req.url.path.endsWith('/partner/online')) {
          return resp('{"mode":"PASSE_ATIVO"}', 200);
        }
        if (req.url.path.endsWith('/offers/mine')) {
          served++;
          return resp(served == 1 ? offerJsonNow() : '{"offers": []}', 200);
        }
        if (req.method == 'GET' && req.url.path.contains('/offers/')) {
          askedOutcome = req.url.path;
          return resp(lossJson('EXPIRED'), 200);
        }
        return resp('{}', 200);
      }),
    );

    await tester.pumpWidget(app);
    await tester.pumpAndSettle();
    await tester.tap(find.text('FICAR ONLINE'));
    await tester.pumpAndSettle();
    expect(find.text('ACEITAR'), findsOneWidget);

    // O servidor para de ofertar (os 15 s venceram) e o app pergunta o motivo.
    await tester.pump(const Duration(seconds: 6));
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 500)); // sheet entra

    expect(askedOutcome, contains('11111111-2222-3333-4444-555555555555'));
    expect(find.text('Oferta perdida por tempo'), findsOneWidget);
    expect(find.textContaining('15 s'), findsOneWidget);
    expect(find.text('Aceite 95%'), findsOneWidget);

    await tester.tap(find.text('ENTENDI'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Oferta perdida por tempo'), findsNothing);
    expect(find.text('ACEITAR'), findsNothing);
    p.dispose();
  });

  testWidgets('P4: aceita → a caminho → chegou → iniciar → finalizar dinheiro '
      'envia cash_declared + fare_total', (tester) async {
    final transitions = <Map<String, dynamic>>[];
    var rideStatus = 'ACEITA';
    final (widget: app, partner: p) = buildApp(
      mock: MockClient((req) async {
        if (req.url.path.endsWith('/me')) return resp(mePartnerApproved, 200);
        if (req.method == 'POST' && req.url.path.endsWith('/partner/transitions')) {
          final body = jsonDecode(req.body) as Map<String, dynamic>;
          transitions.add(body);
          rideStatus = body['to'] as String;
          return resp('{}', 200);
        }
        if (req.url.path.endsWith('/rides/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee')) {
          return resp(
              rideAceita.replaceFirst('ACEITA', rideStatus), 200);
        }
        return resp('{}', 200);
      }),
    );

    // Entra direto em EM_CORRIDA com corrida aceita (estado vindo do aceite).
    p.status = PartnerStatus.emCorrida;
    p.ride = Ride.fromJson(jsonDecode(rideAceita) as Map<String, dynamic>);

    await tester.pumpWidget(app);
    await tester.pumpAndSettle();

    await tester.tap(find.text('A CAMINHO'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('CHEGUEI (raio 50 m)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('INICIAR CORRIDA'));
    await tester.pumpAndSettle();

    expect(transitions.map((t) => t['to']).toList(),
        ['A_CAMINHO', 'CHEGOU', 'EM_VIAGEM']);
    for (final t in transitions) {
      expect(t.containsKey('fare_total'), isFalse,
          reason: 'fare_total só em FINALIZADA');
    }

    // P5: finalizar com dinheiro
    await tester.tap(find.text('FINALIZAR'));
    await tester.pumpAndSettle();
    expect(find.text('Confirmação de dinheiro'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '22.50');
    await tester.tap(find.text('CONFIRMEI O DINHEIRO'));
    await tester.pumpAndSettle();

    final last = transitions.last;
    expect(last['to'], 'FINALIZADA');
    expect(last['fare_total'], 22.5);
    expect(last['cash_declared'], isTrue);
    p.dispose();
  });

  testWidgets('F9 gate: 403 kyc_not_approved leva ao onboarding (em análise ≠ online)',
      (tester) async {
    final (widget: app, partner: p) = buildApp(
      mock: MockClient((req) async {
        if (req.url.path.endsWith('/me')) {
          return resp(
              '{"user_id":"u1","role":"PARTNER","partner":{'
              '"kyc_status":"IN_REVIEW","monetization_mode":"COMISSAO",'
              '"wallet_balance":0,"debt_cents":0}}',
              200);
        }
        if (req.url.path.endsWith('/partner/online')) {
          return resp(
              '{"title":"Forbidden","status":403,"code":"kyc_not_approved"}',
              403);
        }
        return resp('{}', 200);
      }),
    );

    await tester.pumpWidget(app);
    await tester.pumpAndSettle();

    // Em análise: painel mostra o gate e o servidor manda no clique.
    expect(find.text('Cadastro em análise'), findsOneWidget);
    await tester.tap(find.text('FICAR ONLINE'));
    await tester.pumpAndSettle();

    expect(find.text('Cadastro de parceiro'), findsOneWidget);
    expect(find.text('Enviar documentação'), findsOneWidget);
    expect(p.status, PartnerStatus.offline);
    p.dispose();
  });

  testWidgets('P7 carteira: saldo, dívida e extrato itemizado por direção',
      (tester) async {
    final (widget: app, partner: p) = buildApp(
      mock: MockClient((req) async {
        if (req.url.path.endsWith('/me')) return resp(mePartnerApproved, 200);
        if (req.url.path.endsWith('/partner/wallet')) {
          return resp('{"balance":40.0,"debt_cents":350,"statement":[{'
              '"entry_group_id":"g1","description":"Corrida PASSE (bruto)",'
              '"direction":"C","amount":18.5,'
              '"created_at":"2026-10-10T12:00:00Z"},{'
              '"entry_group_id":"g2","description":"Taxa de saque",'
              '"direction":"D","amount":1.5,'
              '"created_at":"2026-10-10T13:00:00Z"}]}', 200);
        }
        return resp('{}', 200);
      }),
    );

    await tester.pumpWidget(app);
    await tester.pumpAndSettle();

    final nav = Navigator.of(tester.element(find.byType(PainelScreen)));
    nav.pushNamed('/carteira');
    await tester.pumpAndSettle();

    expect(find.text('R\$ 40,00'), findsOneWidget);
    expect(find.textContaining('Dívida: R\$ 3,50'), findsOneWidget);
    expect(find.textContaining('bloqueadas'), findsOneWidget);
    expect(find.text('Corrida PASSE (bruto)'), findsOneWidget);
    expect(find.text('+ R\$ 18,50'), findsOneWidget);
    expect(find.text('Taxa de saque'), findsOneWidget);
    expect(find.text('− R\$ 1,50'), findsOneWidget);
    expect(find.textContaining('Sacar via PIX'), findsOneWidget);
    p.dispose();
  });

  testWidgets('Configurar solicitações: desligar um tipo grava PUT com o resto',
      (tester) async {
    http.Request? put;
    final (widget: app, partner: p) = buildApp(
      home: const ConfigurarSolicitacoesScreen(),
      mock: MockClient((req) async {
        if (req.url.path.endsWith('/partner/preferences')) {
          if (req.method == 'PUT') {
            put = req;
            return resp(req.body, 200);
          }
          return resp('{"services":["MOTO","MOTO_NEGOCIA"]}', 200);
        }
        return resp('{}', 200);
      }),
    );

    await tester.pumpWidget(app);
    await tester.pumpAndSettle();

    expect(find.text('Moto'), findsOneWidget);
    expect(find.text('Moto Negocia'), findsOneWidget);
    // Ambos ligados no servidor → ambos ligados na tela.
    expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile).at(1)).value,
        isTrue);

    await tester.tap(find.text('Moto Negocia'));
    await tester.pumpAndSettle();

    expect(put, isNotNull, reason: 'o switch precisa gravar no servidor');
    expect(put!.body, '{"services":["MOTO"]}');
    expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile).at(1)).value,
        isFalse);
    p.dispose();
  });

  testWidgets('Configurar solicitações: valor mínimo vem do servidor e grava',
      (tester) async {
    http.Request? put;
    final (widget: app, partner: p) = buildApp(
      home: const ConfigurarSolicitacoesScreen(),
      mock: MockClient((req) async {
        if (req.url.path.endsWith('/partner/preferences')) {
          if (req.method == 'PUT') {
            put = req;
            return resp(req.body, 200);
          }
          return resp('{"services":["MOTO","MOTO_NEGOCIA"],'
              '"min_fare":7.5}', 200);
        }
        return resp('{}', 200);
      }),
    );

    await tester.pumpWidget(app);
    await tester.pumpAndSettle();

    // O piso carregado do servidor aparece no campo (não é 0 local).
    expect(find.text('7,50'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '9,90');
    await tester.pump();
    await tester.tap(find.text('SALVAR'));
    await tester.pumpAndSettle();

    expect(put, isNotNull, reason: 'SALVAR precisa gravar no servidor');
    expect(put!.body, contains('"min_fare":9.9'));
    expect(put!.body, contains('"services":["MOTO","MOTO_NEGOCIA"]'));
    expect(p.minFare, 9.9);
    p.dispose();
  });

  testWidgets('Teste de status: mostra conexão, modo e tipos ligados',
      (tester) async {
    final (widget: app, partner: p) = buildApp(
      home: const StatusSolicitacaoScreen(),
      mock: MockClient((req) async {
        if (req.url.path.endsWith('/me')) return resp(mePartnerApproved, 200);
        if (req.url.path.endsWith('/partner/preferences')) {
          return resp('{"services":["MOTO"]}', 200);
        }
        return resp('{}', 200);
      }),
    );

    await tester.pumpWidget(app);
    await tester.pumpAndSettle();

    expect(find.textContaining('Respondeu em'), findsOneWidget);
    expect(find.text('OFFLINE — fique online no painel para receber'),
        findsOneWidget);
    expect(find.text('Moto'), findsOneWidget); // tipos ligados no servidor
    expect(find.text('Aprovado'), findsOneWidget);

    await tester.tap(find.text('TESTAR AGORA'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Última verificação'), findsOneWidget);
    p.dispose();
  });

  testWidgets('P4 Navegar abre o mapa com as instruções (não é só um aviso)',
      (tester) async {
    const rideGeo = '{"ride_id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",'
        '"status":"ACEITA","pricing_mode":"PASSE",'
        '"origin_address":"Centro, 100","destination_address":"Aeroporto, 248",'
        '"origin":{"lat":-8.7607,"lon":-63.9039},'
        '"destination":{"lat":-8.7647,"lon":-63.8969},'
        '"created_at":"2026-10-10T12:00:00Z"}';
    final (widget: app, partner: p) = buildApp(
      home: const EmCorridaScreen(),
      mock: MockClient((req) async {
        if (req.url.path.endsWith('/me')) return resp(mePartnerApproved, 200);
        return resp('{}', 200);
      }),
    );
    p.status = PartnerStatus.emCorrida;
    p.ride = Ride.fromJson(jsonDecode(rideGeo) as Map<String, dynamic>);

    await tester.pumpWidget(app);
    await tester.pump();
    await tester.ensureVisible(find.text('Navegar'));
    await tester.tap(find.text('Navegar'));
    await tester.pump();
    // Rota OSRM não responde no runner; o que importa aqui é que o botão
    // abre o MAPA de navegação (tela cheia), não um aviso ou link externo.
    await tester.pump(const Duration(seconds: 1));

    expect(find.byType(NavegacaoScreen), findsOneWidget);
    expect(find.text('Navegação'), findsOneWidget);
    p.dispose();
  });

  testWidgets('Desempenho: mostra taxa de aceite, tempo online, nota e '
      'posição média da semana (números do servidor)', (tester) async {
    // Tela de celular real (360×720 dp): é onde os quatro cartões e a série
    // da semana precisam caber sem overflow.
    tester.view.physicalSize = const Size(1080, 2160);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final (widget: app, partner: p) = buildApp(
      home: const DesempenhoScreen(),
      mock: MockClient((req) async {
        if (req.url.path.endsWith('/me')) return resp(mePartnerApproved, 200);
        if (req.url.path.endsWith('/partner/performance')) {
          return resp('{"date":"2026-10-25","week_start":"2026-10-19",'
              '"timezone":"America/Porto_Velho","days":[{'
              '"date":"2026-10-19","weekday":"seg","offers":4,'
              '"accepted":3,"declined":1,"expired":0,'
              '"acceptance_rate":0.75,"online_seconds":7200,'
              '"avg_rank":2.0,"rank_samples":4,"pool":3.0,'
              '"ratings":1,"rating_avg":5.0}],'
              '"acceptance":{"current":0.9123,"week":0.75,"offers":4,'
              '"accepted":3,"declined":1,"expired":0},'
              '"online":{"week_seconds":7200,"today_seconds":3600,'
              '"session_seconds":600},'
              '"rating":{"value":4.87,"count":305,"week_count":1,'
              '"week_avg":5.0},'
              '"rank":{"avg":2.0,"best":1,"worst":3,"pool":3.0,'
              '"samples":4}}', 200);
        }
        return resp('{}', 200);
      }),
    );

    await tester.pumpWidget(app);
    await tester.pumpAndSettle();

    expect(find.text('Meu desempenho'), findsOneWidget);
    expect(find.text('Últimos 7 dias'), findsOneWidget);
    expect(find.text('19 a 25 de out · fuso de Porto Velho'), findsOneWidget);

    // Os quatro indicadores pedidos, cada um com o número do servidor.
    expect(find.text('Taxa de aceite'), findsOneWidget);
    expect(find.text('75%'), findsOneWidget, reason: '3 aceitas de 4 chamadas');
    expect(find.text('3 de 4 chamadas'), findsOneWidget);
    expect(find.text('Tempo online'), findsOneWidget);
    expect(find.text('2h'), findsOneWidget);
    expect(find.text('hoje 1h'), findsOneWidget);
    expect(find.text('Avaliação'), findsOneWidget);
    expect(find.text('4,9'), findsOneWidget);
    expect(find.text('305 avaliações · 1 nesta semana'), findsOneWidget);
    expect(find.text('Posição no ranking'), findsOneWidget);
    expect(find.text('2,0º'), findsOneWidget);
    expect(find.text('de 3,0 na fila · 4 chamadas'), findsOneWidget);

    // Série da semana: aceitas/total do dia e o tempo conectado.
    expect(find.text('seg'), findsOneWidget);
    expect(find.text('3/4'), findsOneWidget);
    expect(find.text('2h00'), findsOneWidget);

    // A consequência de recusar aparece escrita, não só como número.
    expect(
        find.textContaining(
            'Nesta semana você perdeu 1 chamada: 1 recusada.'),
        findsOneWidget);
    p.dispose();
  });

  testWidgets('Desempenho sem eventos: diz "sem dados" em vez de 0%',
      (tester) async {
    final (widget: app, partner: p) = buildApp(
      home: const DesempenhoScreen(),
      mock: MockClient((req) async {
        if (req.url.path.endsWith('/me')) return resp(mePartnerApproved, 200);
        if (req.url.path.endsWith('/partner/performance')) {
          return resp('{"date":"2026-10-25","week_start":"2026-10-19",'
              '"timezone":"America/Porto_Velho","days":[{'
              '"date":"2026-10-25","weekday":"dom","offers":0,'
              '"accepted":0,"declined":0,"expired":0,'
              '"acceptance_rate":null,"online_seconds":0,'
              '"avg_rank":null,"rank_samples":0,"pool":null,'
              '"ratings":0,"rating_avg":null}],'
              '"acceptance":{"current":0.95,"week":null,"offers":0,'
              '"accepted":0,"declined":0,"expired":0},'
              '"online":{"week_seconds":0,"today_seconds":0,'
              '"session_seconds":0},'
              '"rating":{"value":4.9,"count":301,"week_count":0,'
              '"week_avg":null},'
              '"rank":{"avg":null,"best":null,"worst":null,"pool":null,'
              '"samples":0}}', 200);
        }
        return resp('{}', 200);
      }),
    );

    await tester.pumpWidget(app);
    await tester.pumpAndSettle();

    expect(find.textContaining('Nenhuma chamada nesta semana'), findsOneWidget);
    // Taxa de aceite: semana sem chamada é traço, nunca 0%.
    expect(find.text('—'), findsWidgets);
    expect(find.text('sem chamadas · agora 95%'), findsOneWidget);
    expect(find.text('sem chamadas para ranquear'), findsOneWidget);
    expect(find.text('75%'), findsNothing);
    p.dispose();
  });

  testWidgets('Heartbeat de 30 s mantém a presença fresca (sem ele o parceiro '
      'sai do radar e nunca recebe oferta)', (tester) async {
    final pulses = <Map<String, dynamic>>[];
    final (widget: app, partner: p) = buildApp(
      mock: MockClient((req) async {
        if (req.url.path.endsWith('/me')) return resp(mePartnerApproved, 200);
        if (req.method == 'POST' && req.url.path.endsWith('/partner/online')) {
          return resp('{"mode":"PASSE_ATIVO"}', 200);
        }
        if (req.method == 'POST' &&
            req.url.path.endsWith('/partner/heartbeat')) {
          pulses.add(jsonDecode(req.body) as Map<String, dynamic>);
          return resp('{}', 200);
        }
        return defaultResp(req);
      }),
    );

    await tester.pumpWidget(app);
    await tester.pumpAndSettle();
    await tester.tap(find.text('FICAR ONLINE'));
    await tester.pumpAndSettle();
    expect(pulses, isEmpty, reason: 'o ONLINE já publicou a posição');

    // 30 s depois o parceiro precisa dizer que continua vivo: o despacho só
    // considera quem sinalizou nos últimos 90 s.
    await tester.pump(const Duration(seconds: 31));
    await tester.pumpAndSettle();
    expect(pulses, hasLength(1));
    final points = pulses.single['points'] as List;
    final point = points.single as Map<String, dynamic>;
    expect(point['lat'], -8.7607);
    expect(point['lon'], -63.9039);
    p.dispose();
  });
}
