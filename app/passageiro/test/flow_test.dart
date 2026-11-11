import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart' show LocationAccuracy;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:passageiro/main.dart';
import 'package:passageiro/src/api/client.dart';
import 'package:passageiro/src/api/radar_api.dart';
import 'package:passageiro/src/location/location_service.dart';
import 'package:passageiro/src/screens/screens.dart';
import 'package:passageiro/src/widgets/driver_radar.dart';
import 'package:passageiro/src/widgets/radar_hud.dart';
import 'package:passageiro/src/state/ride_controller.dart';
import 'package:passageiro/src/theme/theme.dart';
import 'package:ten_map/ten_map.dart';

/// Fluxo mínimo C1 → C2 (solicitar em ≤ 3 toques) contra o contrato:
/// a tela monta o POST /rides com o corpo esperado pelo servidor.
/// Sem plugin de localização no teste: responde na hora com falha explícita
/// (não deixa o timeout do plugin pendente no binding).
class _NoLocation extends LocationService {
  const _NoLocation();

  @override
  Future<LocationFix> current({
    Duration timeout = const Duration(seconds: 10),
    LocationAccuracy accuracy = LocationAccuracy.high,
  }) async =>
      throw const LocationException(LocationFailure.unavailable);

  @override
  Future<LocationFix?> tryCurrent({
    Duration timeout = const Duration(seconds: 8),
    LocationAccuracy accuracy = LocationAccuracy.high,
  }) async =>
      null;

  @override
  Future<void> openSettings() async {}
}

/// Sugestão de geocoding com número: o CTA "Chamar" só habilita com
/// endereço numerado (regra de produto: o parceiro precisa do número).
http.Response geocodeFound(String road, {String number = '100'}) =>
    http.Response(
      jsonEncode({
        'query': road,
        'results': [
          {
            'label': '$road, $number, Porto Velho, Rondônia, Brasil',
            'lat': -8.7647,
            'lon': -63.8969,
            'house_number': number,
            'road': road,
          }
        ],
      }),
      200,
      headers: const {'content-type': 'application/json; charset=utf-8'},
    );

/// Seleciona a primeira sugestão do autocomplete (debounce de 400 ms).
Future<void> pickFirstSuggestion(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 450));
  await tester.pumpAndSettle();
  await tester.tap(find.byType(ListTile).first);
  await tester.pump();
}

/// Monta o app com API mockada. [ride] deve ser dado `dispose` ao fim do
/// teste (encerra o poll periódico — o binding falha com timer pendente).
({Widget widget, RideController ride}) buildApp({
  MockClient? mock,
  Widget home = const HomeScreen(),
}) {
  final api = ApiClient(
    baseUrl: 'http://test.local/functions/v1/v1',
    accessToken: () => 'jwt-test',
    inner: mock ??
        MockClient((req) async {
          if (req.url.path.endsWith('/rides') && req.method == 'GET') {
            return http.Response('{"rides": []}', 200);
          }
          return http.Response('{}', 201);
        }),
  );
  final ride = RideController(api);
  return (
    widget: AppScope(
      ride: ride,
      api: api,
      child: MaterialApp(
        theme: buildAppTheme(),
        home: home,
        routes: {
          '/destino': (_) =>
              const DestinoScreen(location: _NoLocation()),
          // Radar de teste (sem rede): a fila aberta pela rota usa o mesmo
          // mock do resto da suíte.
          '/fila': (_) => FilaScreen(
                location: const _NoLocation(),
                radar: _radarDeTeste(drivers: 2),
              ),
          '/historico': (_) => const HistoricoScreen(),
          '/pagamento': (_) => const PagamentoScreen(),
          '/avaliar': (_) => const AvaliarScreen(),
          '/invite': (_) => const InviteScreen(),
        },
      ),
    ),
    ride: ride,
  );
}

/// Radar de teste: [drivers] motoristas reais (contador positivo) vindos do
/// backend. Serve à prova da varredura (C4b/C4c/C4d).
RadarApi _radarDeTeste({int drivers = 2}) {
  final lista = <Map<String, dynamic>>[
    for (var i = 0; i < drivers; i++)
      {
        'driver_id': 'p_$i',
        'lat': -8.761 - i * 0.003,
        'lon': -63.904 + i * 0.002,
        'distance_km': 0.4 + i * 0.8,
        'vehicle': 'Moto',
        'available': true,
      },
  ];
  return RadarApi(
    baseUrl: 'http://test.local/partners',
    token: '',
    client: MockClient((req) async => http.Response(
          jsonEncode({
            'drivers': lista,
            'eligible_count': drivers,
            'radius_km': 3,
            'generated_at': '2026-10-25T12:00:00Z',
          }),
          200,
          headers: const {'content-type': 'application/json; charset=utf-8'},
        )),
  );
}

/// Corrida em BUSCANDO (a fase em que o radar aparece).
Ride _corridaBuscando() => Ride(
      rideId: 'r1',
      status: RideStatus.buscando,
      fareTotal: 12.5,
      distanceKm: 1.2,
      origin: const GeoPoint(-8.7607, -63.9039),
      destination: const GeoPoint(-8.7647, -63.8969),
      originAddress: 'Centro, 100',
      destinationAddress: 'Aeroporto, 248',
      paymentStatus: 'NOT_DUE',
      createdAt: DateTime.utc(2026, 10, 25),
    );

void main() {
  testWidgets('C1 → C2 → chamar monta POST /rides válido', (tester) async {
    http.Request? sent;
    final (widget: app, ride: ride) = buildApp(
      mock: MockClient((req) async {
        if (req.url.path.endsWith('/geocode')) {
          return geocodeFound('Rua Bandeirantes', number: '1200');
        }
        if (req.url.path.endsWith('/geocode')) {
          return geocodeFound('Avenida Amazonas', number: '248');
        }
        if (req.method == 'POST' && req.url.path.endsWith('/rides')) {
          sent = req;
        }
        if (req.method == 'GET') return http.Response('{"rides": []}', 200);
        return http.Response('{}', 201);
      }),
    );

    await tester.pumpWidget(app);
    expect(find.text('Para onde?'), findsOneWidget);

    await tester.tap(find.text('Para onde?'));
    await tester.pumpAndSettle();

    // C2: digita destino, escolhe a sugestão COM número e chama.
    await tester.enterText(find.byType(TextField), 'Rua Bandeirantes');
    await pickFirstSuggestion(tester);
    await tester.tap(find.text('Chamar'));
    await tester.pumpAndSettle();

    expect(sent, isNotNull, reason: 'POST /rides deve disparar');
    final body = sent!.body;
    expect(body, contains('"pricing_mode":"TARIFF"'));
    expect(sent!.headers['Idempotency-Key'], isNotNull);
    // Sucesso navega para a fila (C4)
    expect(find.text('Busca ativa'), findsOneWidget);
    ride.dispose(); // para o poll antes da checagem de invariantes
  });

  testWidgets('C2 endereço sem número pede o número e envia no pedido',
      (tester) async {
    http.Request? sent;
    final (widget: app, ride: ride) = buildApp(
      mock: MockClient((req) async {
        if (req.url.path.endsWith('/geocode')) {
          // Rótulo SEM house_number: praça/bairro. O app tem de pedir o número
          // e garantir que ele viaje no destination_address.
          return http.Response(
            jsonEncode({
              'query': 'Centro',
              'results': [
                {
                  'label': 'Centro, Porto Velho, Rondônia, Brasil',
                  'lat': -8.7647,
                  'lon': -63.8969,
                  'house_number': null,
                  'road': '',
                },
              ],
            }),
            200,
            headers: const {
              'content-type': 'application/json; charset=utf-8'
            },
          );
        }
        if (req.method == 'POST' && req.url.path.endsWith('/rides')) {
          sent = req;
        }
        if (req.method == 'GET') return http.Response('{"rides": []}', 200);
        return http.Response('{}', 201);
      }),
    );

    await tester.pumpWidget(app);
    await tester.tap(find.text('Para onde?'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'Centro');
    await pickFirstSuggestion(tester);
    await tester.pumpAndSettle();

    // O diálogo do número é obrigatório: sem número ele não fecha.
    expect(find.text('Número do endereço'), findsOneWidget);
    await tester.tap(find.text('Confirmar'));
    await tester.pump();
    expect(find.text('Número do endereço'), findsOneWidget);

    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      '1234',
    );
    await tester.tap(find.text('Confirmar'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Chamar'));
    await tester.pumpAndSettle();

    expect(sent, isNotNull);
    expect(sent!.body, contains('"destination_address":"Centro, 1234'));
    ride.dispose();
  });

  testWidgets('409 active_ride_exists mostra mensagem por code, sem navegar',
      (tester) async {
    final (widget: app, ride: ride) = buildApp(
      mock: MockClient((req) async {
        if (req.url.path.endsWith('/geocode')) {
          return geocodeFound('Rua Sete de Setembro', number: '89');
        }
        if (req.method == 'GET') return http.Response('{"rides": []}', 200);
        return http.Response(
            '{"title":"Conflict","status":409,"code":"active_ride_exists"}',
            409);
      }),
    );

    await tester.pumpWidget(app);
    await tester.tap(find.text('Para onde?'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Rua Sete de Setembro');
    await pickFirstSuggestion(tester);
    await tester.tap(find.text('Chamar'));
    await tester.pumpAndSettle();

    expect(find.text('Você já tem uma corrida em andamento.'), findsOneWidget);
    expect(find.text('Procurando parceiro'), findsNothing);
    ride.dispose();
  });

  testWidgets('C2 preço do momento: valor na tela e quoted_fare no POST /rides',
      (tester) async {
    http.Request? sent;
    final (widget: app, ride: ride) = buildApp(
      mock: MockClient((req) async {
        if (req.url.path.endsWith('/quote')) {
          return http.Response(
              '{"fare_total":19.90,"expires_in":90,"currency":"BRL",'
              '"breakdown":{"distance_km":1.5,"base":8.3,'
              '"demand_multiplier":1.33,"rush_multiplier":1.18}}',
              200);
        }
        if (req.url.path.endsWith('/geocode')) {
          return geocodeFound('Avenida Amazonas', number: '248');
        }
        if (req.method == 'POST' && req.url.path.endsWith('/rides')) {
          sent = req;
        }
        if (req.method == 'GET') return http.Response('{"rides": []}', 200);
        return http.Response('{}', 201);
      }),
    );

    await tester.pumpWidget(app);
    await tester.tap(find.text('Para onde?'));
    await tester.pumpAndSettle();    await tester.enterText(find.byType(TextField), 'Avenida Amazonas');
    await pickFirstSuggestion(tester);

    // debounce de 500 ms → GET /quote (preço do momento)
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();

    expect(find.text('Valor no momento'), findsOneWidget);
    expect(find.textContaining('19,90'), findsOneWidget,
        reason: 'o valor do momento deve aparecer antes de chamar');
    expect(find.textContaining('vale por'), findsOneWidget,
        reason: 'validade da cotação visível');
    expect(find.textContaining('demanda ×1,33'), findsOneWidget,
        reason: 'o card explica de onde vem o valor (base · km · demanda · hora)');

    await tester.tap(find.text('Chamar'));
    await tester.pumpAndSettle();

    expect(sent, isNotNull, reason: 'POST /rides deve disparar');
    expect(sent!.body, contains('"quoted_fare":19.9'),
        reason: 'o valor mostrado vai congelado como fare_total');
    expect(find.text('Busca ativa'), findsOneWidget);
    ride.dispose();
  });

  testWidgets('C2 cotação vencida: re-cota antes de chamar', (tester) async {
    http.Request? sent;
    var quotes = 0;
    final (widget: app, ride: ride) = buildApp(
      mock: MockClient((req) async {
        if (req.url.path.endsWith('/quote')) {
          quotes++;
          // 1ª cotação já vence no ato; a 2ª (no Chamar) vem com outro valor.
          final fare = quotes == 1 ? 10.0 : 12.5;
          final ttl = quotes == 1 ? 0 : 90;
          return http.Response(
              '{"fare_total":$fare,"expires_in":$ttl,"currency":"BRL"}', 200);
        }
        if (req.url.path.endsWith('/geocode')) {
          return geocodeFound('Avenida Amazonas', number: '248');
        }
        if (req.method == 'POST' && req.url.path.endsWith('/rides')) {
          sent = req;
        }
        if (req.method == 'GET') return http.Response('{"rides": []}', 200);
        return http.Response('{}', 201);
      }),
    );

    await tester.pumpWidget(app);
    await tester.tap(find.text('Para onde?'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Avenida Amazonas');
    await pickFirstSuggestion(tester);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(); // resolve o GET /quote sem deixar o ticker de 1 s rodar

    // A cotação de 10,00 vence no ato: o card se re-cota sozinho e o valor
    // congelado nunca é o expirado.
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(quotes, greaterThanOrEqualTo(2),
        reason: 'cotação vencida dispara nova consulta');
    expect(find.textContaining('12,50'), findsOneWidget);

    await tester.tap(find.text('Chamar'));
    await tester.pumpAndSettle();

    expect(sent, isNotNull, reason: 'POST /rides deve disparar');
    expect(sent!.body, contains('"quoted_fare":12.5'),
        reason: 'cotação vencida não pode virar o preço congelado no pedido');
    ride.dispose();
  });

  testWidgets('histórico: estado vazio renderiza mensagem', (tester) async {
    final (widget: app, ride: ride) = buildApp(
      mock: MockClient((req) async => http.Response('{"rides": []}', 200)),
    );
    await tester.pumpWidget(app);
    final nav = Navigator.of(tester.element(find.byType(HomeScreen)));
    nav.pushNamed('/historico');
    await tester.pumpAndSettle();
    expect(find.text('Nenhuma corrida ainda'), findsOneWidget);
    ride.dispose();
  });

  testWidgets('histórico: cada corrida mostra a distância congelada',
      (tester) async {
    final (widget: app, ride: ride) = buildApp(
      mock: MockClient((req) async => http.Response(
          '{"rides": ['
          '{"ride_id":"r1","status":"FINALIZADA","fare_total":10.16,'
          '"distance_km":1.2,"destination_address":"Aeroporto",'
          '"origin":{"lat":-8.7607,"lon":-63.9039},'
          '"destination":{"lat":-8.7647,"lon":-63.8969},'
          '"origin_address":"Centro",'
          '"partner":{"name":"Raimundo","rating":4.9,'
          '"vehicle":"Biz 125"},'
          '"payment_status":"CONFIRMED","created_at":"2026-10-23T13:00:00Z"},'
          '{"ride_id":"r2","status":"CANCELADA_CLIENTE","fare_total":null,'
          '"destination_address":"Centro",'
          '"payment_status":"NOT_DUE","created_at":"2026-10-22T13:00:00Z"}'
          ']}',
          200)),
    );
    await tester.pumpWidget(app);
    final nav = Navigator.of(tester.element(find.byType(HomeScreen)));
    nav.pushNamed('/historico');
    await tester.pumpAndSettle();

    expect(find.textContaining('1,2 km'), findsOneWidget,
        reason: 'cada corrida com distância mostra o km no histórico');
    expect(find.textContaining('Cancelada por você'), findsOneWidget,
        reason: 'corrida sem distância continua listada, só sem o km');
    expect(
        find.textContaining(RegExp(r'\d{2}/\d{2}/\d{4} às \d{2}:\d{2}$')),
        findsNWidgets(2),
        reason: 'data curta nas duas linhas: o toString() cru vazava '
            'microssegundos');
    ride.dispose();
  });

  testWidgets('histórico: tocar numa linha abre os detalhes da corrida',
      (tester) async {
    final (widget: app, ride: ride) = buildApp(
      mock: MockClient((req) async => http.Response(
          '{"rides": ['
          '{"ride_id":"r1","status":"FINALIZADA","fare_total":10.16,'
          '"distance_km":1.2,"destination_address":"Aeroporto",'
          '"origin":{"lat":-8.7607,"lon":-63.9039},'
          '"destination":{"lat":-8.7647,"lon":-63.8969},'
          '"origin_address":"Centro",'
          '"partner":{"name":"Raimundo","rating":4.9,'
          '"vehicle":"Biz 125"},'
          '"payment_status":"CONFIRMED","created_at":"2026-10-23T13:00:00Z"}'
          ']}',
          200)),
    );
    await tester.pumpWidget(app);
    final nav = Navigator.of(tester.element(find.byType(HomeScreen)));
    nav.pushNamed('/historico');
    await tester.pumpAndSettle();

    await tester.tap(find.text('Aeroporto'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Detalhes da corrida'), findsOneWidget);
    expect(find.text('Finalizada'), findsOneWidget);
    expect(find.text('1,2 km'), findsOneWidget);
    expect(find.text('Confirmado'), findsOneWidget);
    expect(find.textContaining('10,16'), findsOneWidget);
    expect(find.textContaining('Raimundo'), findsOneWidget);
    expect(
        find.textContaining(RegExp(r'\d{2}/\d{2}/\d{4} às \d{2}:\d{2}$')),
        findsOneWidget);
    ride.dispose();
  });

  testWidgets('detalhe: repetir viagem abre o destino já preenchido',
      (tester) async {
    http.Request? repetida;
    final (widget: app, ride: ride) = buildApp(
      mock: MockClient((req) async {
        // A corrida nova é cotada de novo: repetir não herda o preço do recibo.
        if (req.url.path.endsWith('/quote')) {
          return http.Response(
              '{"fare_total":12.5,"expires_in":90,"currency":"BRL"}', 200);
        }
        // Repetir um destino antigo sem número pede o número antes de chamar.
        if (req.url.path.endsWith('/geocode')) {
          return geocodeFound('Aeroporto', number: '100');
        }
        if (req.method == 'POST') {
          repetida = req;
          return http.Response('{"ride_id":"r2","status":"CRIADA"}', 201);
        }
        // A corrida nova ainda não existe para o GET /rides?active=1.
        if (req.url.queryParameters['active'] == '1') {
          return http.Response('{"rides": []}', 200);
        }
        return http.Response(
            '{"rides": ['
            '{"ride_id":"r1","status":"FINALIZADA","fare_total":10.16,'
            '"distance_km":1.2,"destination_address":"Aeroporto",'
            '"origin":{"lat":-8.7607,"lon":-63.9039},'
            '"destination":{"lat":-8.7647,"lon":-63.8969},'
            '"origin_address":"Centro",'
            '"partner":{"name":"Raimundo","rating":4.9,'
            '"vehicle":"Biz 125"},'
            '"payment_status":"CONFIRMED","created_at":"2026-10-23T13:00:00Z"}'
            ']}',
            200);
      }),
    );
    await tester.pumpWidget(app);
    final nav = Navigator.of(tester.element(find.byType(HomeScreen)));
    nav.pushNamed('/historico');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Aeroporto'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tap(find.text('Repetir viagem'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('Confirmar destino'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Aeroporto'), findsOneWidget,
        reason: 'o destino da corrida antiga entra escolhido no campo');
    expect(find.textContaining('R\$ 12,50'), findsOneWidget,
        reason: 'a cotação é do momento, não a do recibo antigo');

    // O destino antigo veio sem número: o app pede o número antes de chamar.
    await tester.tap(find.text('Incluir número'));
    // pumpAndSettle não converge com o cursor do TextField piscando.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(
        find.descendant(
            of: find.byType(AlertDialog), matching: find.byType(TextField)),
        '100');
    await tester.tap(find.text('Confirmar'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.widgetWithText(TextField, 'Aeroporto, 100'), findsOneWidget);

    // A corrida nova vai para o mesmo ponto do mapa, com o endereço do recibo
    // antigo (agora numerado) — e com o preço que o passageiro está vendo.
    await tester.tap(find.text('Chamar'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(repetida, isNotNull, reason: 'repetir deve chamar de novo');
    expect(repetida!.body, contains('"destination":{"lat":-8.7647'));
    expect(repetida!.body, contains('"destination_address":"Aeroporto, 100'));
    expect(repetida!.body, contains('"quoted_fare":12.5'));

    // Descarta a tela: o contador da cotação é um Timer.periodic.
    await tester.pumpWidget(const SizedBox());
    ride.dispose();
  });

  testWidgets('P1 apresentação → OTP → home', (tester) async {
    final (widget: app, ride: ride) = buildApp();
    // Apresentação fica antes da home: monta o gate como o main real.
    await tester.pumpWidget(_LoginGate(inner: app));
    // O login abre com a logo da marca + carrossel de campanha.
    expect(find.byType(Image), findsWidgets);
    expect(find.text('Entrar ou criar conta'), findsOneWidget);
    expect(find.text('Para onde?'), findsNothing);

    await tester.enterText(find.byType(TextField).first, '69999999999');
    await tester.tap(find.text('CONTINUAR'));
    await tester.pump();
    // Login em duas etapas: celular → email → código.
    expect(find.text('E-mail'), findsWidgets);
    await tester.enterText(find.byType(TextField), 'teste@dezemais.app');
    await tester.tap(find.text('CONTINUAR'));
    await tester.pump();
    expect(find.text('Código de verificação'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '1234');
    await tester.tap(find.text('ENTRAR'));
    await tester.pump(const Duration(milliseconds: 700)); // OTP fake delay
    // CityMap tem ticker infinito (repeat) — pumpAndSettle não converge;
    // o pós-frame do gate sai no pump seguinte.
    await tester.pump();
    expect(find.text('Para onde?'), findsOneWidget);
    ride.dispose();
  });

  testWidgets('C7: dinheiro já confirmado pelo parceiro não pede pagamento',
      (tester) async {
    final (widget: app, ride: controller) =
        buildApp(home: const PagamentoScreen());
    controller.ride = Ride(
      rideId: 'r1',
      status: RideStatus.finalizada,
      fareTotal: 11.04,
      distanceKm: 1.2,
      paymentStatus: 'CONFIRMED',
      createdAt: DateTime.utc(2026, 10, 22),
    );

    await tester.pumpWidget(app);
    await tester.pump();

    expect(find.text('Pagamento confirmado'), findsOneWidget);
    expect(find.text('Avaliar corrida'), findsOneWidget);
    expect(find.text('1,2 km'), findsOneWidget,
        reason: 'recibo repete o km congelado no pedido');
    expect(find.text('Pagar com PIX'), findsNothing);
    controller.dispose();
  });

  testWidgets('convites: carrega lista e gera novo código', (tester) async {
    final (widget: app, ride: controller) = buildApp(
      home: const InviteScreen(),
      mock: MockClient((req) async {
        if (req.method == 'GET' && req.url.path.endsWith('/invites/mine')) {
          return http.Response(
              '{"invites":[{"invite_id":"i1","invite_code":"10MAIS-ABC123",'
              '"status":"PENDING","reward_hours":12}]}',
              200,
              headers: const {
                'content-type': 'application/json; charset=utf-8'
              });
        }
        if (req.method == 'POST' && req.url.path.endsWith('/invites')) {
          return http.Response(
              '{"invite_id":"i2","invite_code":"10MAIS-NEW999",'
              '"status":"PENDING","reward_hours":12}',
              201,
              headers: const {
                'content-type': 'application/json; charset=utf-8'
              });
        }
        return http.Response('{}', 200);
      }),
    );

    await tester.pumpWidget(app);
    await tester.pumpAndSettle();
    expect(find.text('10MAIS-ABC123'), findsWidgets);

    await tester.tap(find.text('GERAR NOVO CÓDIGO'));
    await tester.pumpAndSettle();
    expect(find.text('10MAIS-NEW999'), findsWidgets);
    controller.dispose();
  });

  testWidgets('C4 radar: motoristas reais DENTRO do mapa, com contador',
      (tester) async {
    final radar = RadarApi(
      baseUrl: 'http://test.local/partners',
      token: '',
      client: MockClient((req) async => http.Response(
            jsonEncode({
              'drivers': [
                {
                  'driver_id': 'p_1',
                  'lat': -8.761,
                  'lon': -63.904,
                  'distance_km': 0.4,
                  'vehicle': 'Moto',
                  'available': true,
                },
                {
                  'driver_id': 'p_2',
                  'lat': -8.764,
                  'lon': -63.9,
                  'distance_km': 1.2,
                  'vehicle': 'Moto',
                  'available': true,
                },
              ],
              'eligible_count': 2,
              'radius_km': 3,
              'generated_at': '2026-10-25T12:00:00Z',
            }),
            200,
            headers: const {'content-type': 'application/json; charset=utf-8'},
          )),
    );
    final (widget: app, ride: controller) = buildApp(
      home: FilaScreen(location: const _NoLocation(), radar: radar),
    );
    controller.ride = Ride(
      rideId: 'r1',
      status: RideStatus.buscando,
      fareTotal: 12.5,
      distanceKm: 1.2,
      origin: const GeoPoint(-8.7607, -63.9039),
      destination: const GeoPoint(-8.7647, -63.8969),
      originAddress: 'Centro, 100',
      destinationAddress: 'Aeroporto, 248',
      paymentStatus: 'NOT_DUE',
      createdAt: DateTime.utc(2026, 10, 25),
    );

    await tester.pumpWidget(app);
    // Localização falha de propósito → fallback para o embarque do pedido;
    // depois o radar consulta o backend e a câmera do mapa monta.
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }

    expect(find.text('2 motoristas na região'), findsOneWidget);
    expect(find.text('Radar indisponível'), findsNothing);
    // Os pinos do radar são desenhados em Flutter por cima do mapa
    // compartilhado (o mesmo desenho no vetorial e no raster).
    expect(find.byType(DriverRadarPin), findsNWidgets(2));
    expect(find.byType(UserRadarDot), findsOneWidget);
    expect(find.byType(RadarHud), findsOneWidget);

    // "Dentro do mapa": a varredura e os pinos ficam na MESMA área do mapa,
    // não num card fora dele.
    final map = tester.getRect(find.byType(BaseMapView));
    final hud = tester.getRect(find.byType(RadarHud));
    expect(map.width, greaterThan(700),
        reason: 'o mapa ocupa a largura toda (radar não vive fora dele)');
    expect(map.contains(hud.center), isTrue,
        reason: 'o centro do radar está sobre o mapa');

    // Descarta a tela: encerra timers/ticker do radar.
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets(
      'C4b radar: a varredura PARA quando o aparelho pede "sem animação"',
      (tester) async {
    // Por que este teste existe: a varredura do radar repinta a tela 15× por
    // segundo. Quem liga "remover animações" nas configurações de
    // acessibilidade não pode receber isso — e, no teste de ponta a ponta,
    // uma tela que nunca fica parada faz o `uiautomator` esperar o tempo de
    // idle do sistema (≈9 s por leitura), comendo a janela de 15 s da
    // oferta do parceiro.
    //
    // O radar de teste vem VAZIO de propósito: sem motorista na região a
    // varredura é a única coisa se movendo na tela.
    final (widget: app, ride: controller) = buildApp(
      home: FilaScreen(
        location: const _NoLocation(),
        radar: _radarDeTeste(drivers: 0),
      ),
    );
    controller.ride = _corridaBuscando();

    // O `MediaQuery` que a app real recebe da preferência de acessibilidade
    // do sistema (aqui, injetado no mesmo ponto da árvore).
    await tester.pumpWidget(Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: true),
        child: app,
      ),
    ));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
    expect(find.text('Nenhum motorista na região'), findsOneWidget);

    // Um segundo de tela: o feixe do radar não pode ter andado.
    await tester.pump(const Duration(seconds: 1));
    final hud = tester.widget<RadarHud>(find.byType(RadarHud));
    expect(hud.progress, 0.0,
        reason: 'com "remover animações" a varredura não pode repintar a tela');

    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('C4c radar: com animação, a varredura anda (prova do C4b)',
      (tester) async {
    final (widget: app, ride: controller) = buildApp(
      home: FilaScreen(
        location: const _NoLocation(),
        radar: _radarDeTeste(drivers: 0),
      ),
    );
    controller.ride = _corridaBuscando();

    await tester.pumpWidget(app);
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
    expect(find.text('Nenhum motorista na região'), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
    final hud = tester.widget<RadarHud>(find.byType(RadarHud));
    expect(hud.progress, greaterThan(0.0),
        reason: 'sem "remover animações" o feixe do radar gira');

    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('C4d radar: com motorista na região, a tela fica calma',
      (tester) async {
    // O feixe varrendo a área não informa nada quando já há motorista na
    // região (o pino e o contador dizem) — só gasta bateria repintando a
    // tela 15× por segundo. A varredura para nesse caso.
    final (widget: app, ride: controller) = buildApp(
      home: FilaScreen(
        location: const _NoLocation(),
        radar: _radarDeTeste(drivers: 2),
      ),
    );
    controller.ride = _corridaBuscando();

    await tester.pumpWidget(app);
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
    expect(find.text('2 motoristas na região'), findsOneWidget);

    // A varredura CONGELA (o feixe fica onde estava): um segundo de tela
    // não pode mover o radar.
    final antes = tester.widget<RadarHud>(find.byType(RadarHud)).progress;
    await tester.pump(const Duration(seconds: 1));
    final depois = tester.widget<RadarHud>(find.byType(RadarHud)).progress;
    expect(depois, antes,
        reason: 'com motorista na região o feixe não precisa varrer');

    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets(
      'C8 destino: o passageiro vê quantos parceiros REAIS estão perto',
      (tester) async {
    // O radar é lido ANTES do pedido: o passageiro decide com o número na
    // tela ("há motorista por perto?"), e o dado viaja com o pedido para a
    // tela de busca. Sem backend, a tela diz "radar indisponível" — nunca
    // motorista inventado.
    final (widget: app, ride: controller) = buildApp(
      home: DestinoScreen(
        location: const _NoLocation(),
        radar: _radarDeTeste(drivers: 2),
      ),
    );

    await tester.pumpWidget(app);
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
    expect(find.text('2 motoristas na região'), findsOneWidget);
    expect(find.text('Radar indisponível nesta versão'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets(
      'C8b destino: sem radar configurado, a tela avisa (nada de motorista '
      'inventado)', (tester) async {
    final (widget: app, ride: controller) = buildApp(
      home: DestinoScreen(
        location: const _NoLocation(),
        radar: RadarApi(baseUrl: ''),
      ),
    );

    await tester.pumpWidget(app);
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
    expect(find.text('Radar indisponível nesta versão'), findsOneWidget);
    expect(find.textContaining('motorista na região'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('C9 fila: abre com o contador que o destino já leu',
      (tester) async {
    // O snapshot viaja nos argumentos da rota '/fila': a tela de busca mostra
    // o número desde o primeiro quadro (sem "consultando…" e sem piscar).
    final snapshot = RadarSnapshot(
      drivers: const [],
      eligibleCount: 2,
      radiusKm: 3,
      generatedAt: DateTime.utc(2026, 10, 25),
    );
    final (widget: app, ride: controller) = buildApp();
    controller.ride = _corridaBuscando();

    await tester.pumpWidget(app);
    tester
        .state<NavigatorState>(find.byType(Navigator))
        .pushNamed('/fila', arguments: snapshot);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('2 motoristas na região'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('C10 destino: endereço completo fecha o teclado (o preço '
      'fica visível)', (tester) async {
    // Com o teclado aberto, a tela perde ~40% da altura e o card de cotação
    // sai da área visível: o passageiro acabaria chamando SEM ver o preço
    // (foi o que travou o E2E). Endereço escolhido = teclado fechado.
    final (widget: app, ride: controller) = buildApp(
      home: const DestinoScreen(location: _NoLocation()),
      mock: MockClient((req) async {
        if (req.url.path.endsWith('/geocode')) {
          return geocodeFound('Avenida Amazonas', number: '248');
        }
        if (req.url.path.endsWith('/quote')) {
          return http.Response(
              '{"fare_total":12.5,"expires_in":90,"currency":"BRL"}', 200);
        }
        return http.Response('{}', 200);
      }),
    );

    await tester.pumpWidget(app);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byType(TextField).first);
    await tester.pump();
    await tester.enterText(find.byType(TextField).first, 'Avenida Amazonas');
    await tester.pump(const Duration(milliseconds: 450));
    await tester.pumpAndSettle();

    // A sugestão aparece e o usuário escolhe.
    expect(find.byType(ListTile), findsWidgets);
    await tester.tap(find.byType(ListTile).first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // Endereço completo: o campo perdeu o foco (o teclado fecha).
    final editable = tester.widget<EditableText>(find.byType(EditableText).first);
    expect(editable.focusNode.hasFocus, isFalse,
        reason: 'endereço escolhido → o teclado fecha (o preço fica visível)');
    expect(tester.testTextInput.isVisible, isFalse);

    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('C7 PIX: só avança quando o backend confirma o pagamento',
      (tester) async {
    var confirms = 0;
    final (widget: app, ride: controller) = buildApp(
      home: const PagamentoScreen(),
      mock: MockClient((req) async {
        if (req.method == 'POST' && req.url.path.endsWith('/payments/ride')) {
          return http.Response(
            jsonEncode({
              'payment_id': 'pay_1',
              'pix': {
                'qr': 'data:image/png;base64,demo',
                'copia_cola': '00020126pixdemo',
                'expires_at': '2026-10-22T00:15:00Z',
              },
            }),
            201,
            headers: const {
              'content-type': 'application/json; charset=utf-8'
            },
          );
        }
        if (req.method == 'POST' &&
            req.url.path.endsWith('/rides/r1/payment/confirm')) {
          confirms++;
          // O PSP ainda não liquidou: o servidor responde PENDING e a tela
          // tem de ficar no pagamento (nada de sucesso inventado).
          final status = confirms == 1 ? 'PENDING' : 'CONFIRMED';
          return http.Response(
            jsonEncode({
              'ride_id': 'r1',
              'status': 'FINALIZADA',
              'fare_total': 11.04,
              'distance_km': 1.2,
              'payment_status': status,
              'created_at': '2026-10-22T00:00:00Z',
            }),
            200,
            headers: const {
              'content-type': 'application/json; charset=utf-8'
            },
          );
        }
        return http.Response('{}', 200);
      }),
    );
    controller.ride = Ride(
      rideId: 'r1',
      status: RideStatus.finalizada,
      fareTotal: 11.04,
      distanceKm: 1.2,
      paymentStatus: 'PENDING',
      createdAt: DateTime.utc(2026, 10, 22),
    );

    await tester.pumpWidget(app);
    await tester.tap(find.text('Pagar com PIX'));
    await tester.pump();
    expect(find.text('Já paguei'), findsOneWidget);

    // 1ª confirmação: servidor ainda em PENDING → continua no pagamento.
    await tester.tap(find.text('Já paguei'));
    await tester.pump();
    await tester.pump();
    expect(confirms, 1);
    expect(find.text('Pagar com PIX'), findsNothing);
    expect(find.textContaining('ainda não confirmou'), findsOneWidget);
    expect(find.text('Avaliar corrida'), findsNothing);
    expect(controller.ride!.paymentStatus, 'PENDING');

    // 2ª confirmação: o backend responde CONFIRMED → segue para a avaliação.
    await tester.tap(find.text('Já paguei'));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400)); // transição de rota
    expect(controller.ride!.paymentStatus, 'CONFIRMED');
    expect(find.text('Como foi a viagem?'), findsOneWidget,
        reason: 'só chega na avaliação depois do CONFIRMED');
    controller.dispose();
  });
}

/// Gate de sessão como o main real: login (OTP) → home.
class _LoginGate extends StatefulWidget {
  const _LoginGate({required this.inner});

  /// Árvore já montada do app (AppScope + MaterialApp + HomeScreen).
  final Widget inner;

  @override
  State<_LoginGate> createState() => _LoginGateState();
}

class _LoginGateState extends State<_LoginGate> {
  bool _signedIn = false;

  @override
  Widget build(BuildContext context) => _signedIn
      ? widget.inner
      : MaterialApp(
          theme: buildAppTheme(),
          home: LoginScreen(onDone: () => setState(() => _signedIn = true)),
        );
}
