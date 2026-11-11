import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:passageiro/src/api/radar_api.dart';

/// O radar real (Edge Function `radar`, Postgres) exige o JWT do passageiro:
/// é o token que diz **quem** está perguntando. Sem ele a função recusa — e o
/// passageiro ficaria sem nenhum motorista no mapa.
///
/// Estes testes travam: o token da sessão vai no header, e sem token nenhum
/// o header não é inventado.
void main() {
  late List<http.Request> seen;

  http.Response answer(http.Request req) {
    seen.add(req);
    return http.Response(
      jsonEncode({
        'drivers': [
          {
            'driver_id': 'p_abcd1234',
            'lat': -8.761,
            'lon': -63.904,
            'distance_km': 0.8,
            'vehicle': 'Honda Biz 125',
          },
        ],
        'eligible_count': 1,
        'radius_km': 3.0,
        'generated_at': '2026-11-10T19:00:00Z',
      }),
      200,
    );
  }

  setUp(() => seen = []);

  test('o radar real leva o token da sessão (assíncrono)', () async {
    final radar = RadarApi(
      baseUrl: 'http://real.local/functions/v1/radar',
      tokenProvider: () async {
        await Future<void>.delayed(const Duration(milliseconds: 1));
        return 'jwt-da-sessao';
      },
      client: MockClient((req) async => answer(req)),
    );

    final snap = await radar.nearby(lat: -8.7607, lon: -63.9039);

    expect(snap.drivers, hasLength(1));
    expect(snap.drivers.single.distanceKm, 0.8);
    expect(seen.single.url.path, '/functions/v1/radar/nearby');
    expect(seen.single.headers['authorization'], 'Bearer jwt-da-sessao');
  });

  test('sem token nenhum o header não é inventado (modo demo)', () async {
    final radar = RadarApi(
      baseUrl: 'http://demo.local/partners',
      client: MockClient((req) async => answer(req)),
    );

    await radar.nearby(lat: -8.7607, lon: -63.9039);

    expect(seen.single.headers.containsKey('authorization'), isFalse);
    expect(seen.single.url.path, '/partners/nearby');
  });

  test('sem base configurada o radar não existe (a tela avisa)', () {
    final radar = RadarApi(baseUrl: '', client: MockClient((req) async => answer(req)));
    expect(radar.configured, isFalse);
  });

  test('a base que já traz /nearby não duplica o sufixo', () async {
    final radar = RadarApi(
      baseUrl: 'http://real.local/functions/v1/radar/nearby',
      token: 'jwt',
      client: MockClient((req) async => answer(req)),
    );

    await radar.nearby(lat: -8.7607, lon: -63.9039);

    expect(seen.single.url.path, '/functions/v1/radar/nearby');
  });
}
