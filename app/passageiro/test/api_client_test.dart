import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:passageiro/src/api/client.dart';

/// Contrato client ↔ openapi.yaml: Idempotency-Key em toda mutação,
/// problem+json → ApiProblem(code), formatos de corpo conforme spec.
void main() {
  late List<http.Request> seen;
  int idemCalls = 0;

  ApiClient clientWith(MockClient handler) {
    seen = [];
    idemCalls = 0;
    return ApiClient(
      baseUrl: 'http://test.local/functions/v1/v1',
      accessToken: () => 'jwt-test',
      inner: handler,
      newIdemKey: () => 'idem-${++idemCalls}',
    );
  }

  test('POST /rides envia corpo do contrato + Idempotency-Key + JWT', () async {
    final api = clientWith(MockClient((req) async {
      seen.add(req);
      return http.Response('{}', 201);
    }));

    await api.createRide(
      origin: const GeoPoint(-8.7607, -63.9039),
      destination: const GeoPoint(-8.7647, -63.8969),
      mode: PricingMode.negotiated,
      proposedAmount: 15.5,
      originAddress: 'Centro',
      destinationAddress: 'B. São Pedro',
    );

    expect(seen.single.method, 'POST');
    expect(seen.single.url.path, '/functions/v1/v1/rides');
    expect(seen.single.headers['Idempotency-Key'], 'idem-1');
    expect(seen.single.headers['authorization'], 'Bearer jwt-test');
    final body = jsonDecode(seen.single.body) as Map<String, dynamic>;
    expect(body['pricing_mode'], 'NEGOTIATED');
    expect(body['proposed_amount'], 15.5);
    expect(body['origin'], {'lat': -8.7607, 'lon': -63.9039});
    expect(body.keys.toSet(), {
      'origin', 'destination', 'pricing_mode', 'proposed_amount',
      'origin_address', 'destination_address',
    });
  });

  test('TARIFF não carrega proposed_amount', () async {
    final api = clientWith(MockClient((req) async {
      seen.add(req);
      return http.Response('{}', 201);
    }));
    await api.createRide(
      origin: const GeoPoint(0, 0),
      destination: const GeoPoint(1, 1),
      mode: PricingMode.tariff,
    );
    final body = jsonDecode(seen.single.body) as Map<String, dynamic>;
    expect(body['pricing_mode'], 'TARIFF');
    expect(body.containsKey('proposed_amount'), isFalse);
  });

  test('problem+json 409 vira ApiProblem com code estável', () async {
    final api = clientWith(MockClient((req) async => http.Response(
          jsonEncode({
            'type': 'https://api.dezemais.app/errors/active-ride-exists',
            'title': 'Conflict',
            'status': 409,
            'code': 'active_ride_exists',
          }),
          409,
          headers: {'content-type': 'application/problem+json'},
        )));

    await expectLater(
      api.createRide(
        origin: const GeoPoint(0, 0),
        destination: const GeoPoint(1, 1),
        mode: PricingMode.tariff,
      ),
      throwsA(isA<ApiProblem>()
          .having((p) => p.code, 'code', 'active_ride_exists')
          .having((p) => p.status, 'status', 409)),
    );
  });

  test('corpo não-JSON 500 vira ApiProblem unknown (nunca crasha a tela)', () async {
    final api = clientWith(
        MockClient((req) async => http.Response('Internal Server Error', 500)));
    await expectLater(
      api.me(),
      throwsA(isA<ApiProblem>().having((p) => p.code, 'code', 'unknown')),
    );
  });

  test('GET /rides devolve lista tipada com status do enum', () async {
    final api = clientWith(MockClient((req) async {
      seen.add(req);
      return http.Response(
        jsonEncode({
          'rides': [
            {
              'ride_id': '11111111-1111-4111-8111-111111111111',
              'status': 'EM_VIAGEM',
              'payment_status': 'NOT_DUE',
              'created_at': '2026-10-10T12:00:00Z',
              'fare_total': 18.9,
              'eta_seconds': 540,
              'distance_km': 1.2,
            },
            {
              'ride_id': '22222222-2222-4222-8222-222222222222',
              'status': 'CANCELADA_CLIENTE',
              'payment_status': 'NOT_DUE',
              'created_at': '2026-10-09T12:00:00Z',
            },
          ],
        }),
        200,
      );
    }));

    final rides = await api.rideHistory(limit: 20);
    expect(rides, hasLength(2));
    expect(rides[0].status, RideStatus.emViagem);
    expect(rides[0].fareTotal, 18.9);
    expect(rides[0].etaSeconds, 540);
    expect(rides[0].distanceKm, 1.2,
        reason: 'km congelado no pedido vem no Ride (mesmo da oferta/recibo)');
    expect(rides[1].status, RideStatus.canceladaCliente);
    expect(seen.single.url.queryParameters['limit'], '20');
  });

  test('RideStatus.fromWire cobre os estados Cancelada_* do 0001', () {
    for (final s in [
      'CRIADA', 'BUSCANDO', 'OFERTADA', 'ACEITA', 'A_CAMINHO', 'CHEGOU',
      'EM_VIAGEM', 'FINALIZADA', 'FALHA_PAGAMENTO', 'EXPIRADA',
      'CANCELADA_CLIENTE', 'CANCELADA_PARCEIRO', 'CANCELADA_SISTEMA',
      'CANCELADA_SUPORTE',
    ]) {
      expect(() => RideStatus.fromWire(s), returnsNormally, reason: s);
    }
    expect(RideStatus.fromWire('CANCELADA_SUPORTE'), RideStatus.canceladaSuporte);
    expect(RideStatus.emViagem.isOpen, isTrue);
    expect(RideStatus.finalizada.isOpen, isFalse);
    expect(RideStatus.canceladaCliente.isCancelled, isTrue);
  });

  test('rating: 201 ok e 409 already_rated propagam code', () async {
    var ok = clientWith(MockClient((req) async {
      seen.add(req);
      return http.Response('{}', 201);
    }));
    await ok.rateRide('33333333-3333-4333-8333-333333333333', stars: 5);
    expect(seen.single.headers['Idempotency-Key'], 'idem-1');
    expect(jsonDecode(seen.single.body), {'stars': 5});

    var conflict = clientWith(MockClient((req) async => http.Response(
        jsonEncode({'title': 'Conflict', 'status': 409, 'code': 'already_rated'}),
        409)));
    await expectLater(
      conflict.rateRide('33333333-3333-4333-8333-333333333333', stars: 4),
      throwsA(isA<ApiProblem>().having((p) => p.code, 'code', 'already_rated')),
    );
  });
}
