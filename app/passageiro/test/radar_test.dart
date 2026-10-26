import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:passageiro/src/api/radar_api.dart';

void main() {
  test('nearby lê o contrato real (posição aproximada + contador)', () async {
    late http.Request seen;
    final api = RadarApi(
      baseUrl: 'http://test.local/radar',
      token: 'jwt-dev',
      client: MockClient((req) async {
        seen = req;
        return http.Response(
          jsonEncode({
            'drivers': [
              {
                'driver_id': 'p_abc123',
                'lat': -8.761,
                'lon': -63.904,
                'distance_km': 0.4,
                'vehicle': 'Biz 125',
                'available': true,
              },
              {
                'driver_id': 'p_def456',
                'lat': -8.764,
                'lon': -63.9,
                'distance_km': 1.2,
                'vehicle': null,
                'available': true,
              },
              // Linha sem coordenada não pode derrubar a tela inteira.
              {'driver_id': 'p_sem_pos', 'available': true},
            ],
            'eligible_count': 2,
            'radius_km': 3,
            'generated_at': '2026-10-24T23:00:00Z',
          }),
          200,
          headers: const {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );

    final snap = await api.nearby(lat: -8.7607, lon: -63.9039, radiusKm: 3);

    expect(seen.headers['authorization'], 'Bearer jwt-dev');
    expect(seen.url.path, '/radar/nearby');
    expect(seen.url.queryParameters['radius_km'], '3.0');
    expect(snap.eligibleCount, 2);
    expect(snap.radiusKm, 3);
    expect(snap.drivers.length, 2);
    expect(snap.drivers.first.driverId, 'p_abc123');
    expect(snap.drivers.first.distanceKm, 0.4);
  });

  test('sem backend configurado o radar é indisponível (não inventa dado)',
      () async {
    // O token é opcional (o backend do app já autentica a sessão); o que
    // desabilita o radar é não ter para onde consultar.
    final api = RadarApi(baseUrl: '', token: '');
    expect(api.configured, isFalse);
    await expectLater(
      api.nearby(lat: -8.76, lon: -63.90),
      throwsA(
          isA<RadarProblem>().having((p) => p.code, 'code', 'radar_unconfigured')),
    );
  });

  test('sem token ele consulta o backend do app sem header de auth', () async {
    late http.Request seen;
    final api = RadarApi(
      baseUrl: 'http://test.local/partners/nearby',
      token: '',
      client: MockClient((req) async {
        seen = req;
        return http.Response(
          '{"drivers":[],"eligible_count":0,"radius_km":3,"generated_at":null}',
          200,
          headers: const {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    expect(api.configured, isTrue);
    final snap = await api.nearby(lat: -8.76, lon: -63.90);
    expect(seen.headers.containsKey('authorization'), isFalse);
    // Base já apontando para o endpoint completo não vira
    // `/partners/nearby/nearby` (o 404 que anunciava radar indisponível).
    expect(seen.url.path, '/partners/nearby');
    expect(snap.eligibleCount, 0);
  });

  test('erro do servidor vira code de negócio', () async {
    final api = RadarApi(
      baseUrl: 'http://test.local/radar',
      token: 'jwt-dev',
      client: MockClient((_) async => http.Response(
            '{"title":"Posição inválida","status":422,"code":"invalid_position"}',
            422,
          )),
    );
    await expectLater(
      api.nearby(lat: 999, lon: 0),
      throwsA(isA<RadarProblem>()
          .having((p) => p.code, 'code', 'invalid_position')
          .having((p) => p.status, 'status', 422)),
    );
  });
}
