import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:passageiro/src/api/route_service.dart';
import 'package:passageiro/src/map/route_map_view.dart';

/// Decodificação da polyline (padrão OSRM/Google, precisão 5) e
/// comportamento do serviço: rota real quando o servidor responde, traçado
/// aproximado quando não responde, e cache por par de coordenadas.
void main() {
  group('decodePolyline', () {
    test('decodifica o exemplo canônico do Google', () {
      final pts = decodePolyline('_p~iF~ps|U_ulLnnqC_mqNvxq`@');
      expect(pts, hasLength(3));
      expect(pts[0].latitude, closeTo(38.5, 1e-6));
      expect(pts[0].longitude, closeTo(-120.2, 1e-6));
      expect(pts[1].latitude, closeTo(40.7, 1e-6));
      expect(pts[1].longitude, closeTo(-120.95, 1e-6));
      expect(pts[2].latitude, closeTo(43.252, 1e-6));
      expect(pts[2].longitude, closeTo(-126.453, 1e-6));
    });

    test('string vazia devolve lista vazia', () {
      expect(decodePolyline(''), isEmpty);
    });
  });

  group('RouteService', () {
    const from = LatLng(-8.7607, -63.9039);
    const to = LatLng(-8.7647, -63.8969);

    test('usa o traçado e os números do OSRM', () async {
      var calls = 0;
      final client = MockClient((req) async {
        calls++;
        expect(req.url.host, 'router.project-osrm.org');
        expect(req.url.path, contains('/route/v1/driving/'));
        return http.Response(
          '{"code":"Ok","routes":[{"distance":1234.5,"duration":321.0,'
          '"geometry":"_p~iF~ps|U_ulLnnqC_mqNvxq`@"}]}',
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final svc = RouteService(client: client);
      final r = await svc.route(from, to);
      expect(r.approx, isFalse);
      expect(r.points, hasLength(3));
      expect(r.distanceMeters, closeTo(1234.5, 0.01));
      expect(r.durationSeconds, closeTo(321.0, 0.01));
      expect(r.minutes, 6);
      expect(r.label, '1,2 km · 6 min');

      // Mesma origem/destino: cache evita nova chamada de rede.
      final again = await svc.route(from, to);
      expect(identical(again, r), isTrue);
      expect(calls, 1);
    });

    test('cai no traçado aproximado quando o OSRM falha', () async {
      final svc = RouteService(
        client: MockClient((_) async => http.Response('boom', 503)),
      );
      final r = await svc.route(from, to);
      expect(r.approx, isTrue);
      expect(r.points, hasLength(2));
      expect(r.distanceMeters, greaterThan(0));
      expect(r.durationSeconds, greaterThan(0));
    });

    test('rota sem geometria também cai no aproximado', () async {
      final svc = RouteService(
        client: MockClient((_) async => http.Response('{"routes":[]}', 200)),
      );
      final r = await svc.route(from, to);
      expect(r.approx, isTrue);
    });
  });

  group('cameraFor', () {
    test('enquadra a rota no mapa sem abrir no mundo', () {
      const pts = [LatLng(-8.7607, -63.9039), LatLng(-8.70984, -63.90097)];
      final cam = cameraFor(pts, const Size(380, 220));
      expect(cam.zoom, inInclusiveRange(11.0, 16.5));
      expect(cam.center.latitude, closeTo(-8.73527, 1e-4));
      expect(cam.center.longitude, closeTo(-63.90243, 1e-4));
    });

    test('rota maior usa zoom menor e pontos iguais batem no teto', () {
      final curta = cameraFor(
          const [LatLng(-8.7607, -63.9039), LatLng(-8.70984, -63.90097)],
          const Size(380, 220));
      final longa = cameraFor(
          const [LatLng(-8.7607, -63.9039), LatLng(-9.9, -64.9)],
          const Size(380, 220));
      expect(longa.zoom, lessThan(curta.zoom));
      final igual = cameraFor(
          const [LatLng(-8.7607, -63.9039), LatLng(-8.7607, -63.9039)],
          const Size(380, 220));
      expect(igual.zoom, 16.5);
    });
  });

  test('straightMeters mede a distância em linha reta', () {
    final m = straightMeters(
      const LatLng(-8.7607, -63.9039),
      const LatLng(-8.7647, -63.8969),
    );
    expect(m, greaterThan(400));
    expect(m, lessThan(1200));
  });
}
