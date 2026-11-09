import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:ten_map/ten_map.dart';

/// Prova que o pacote compartilhado se sustenta sozinho: base + rota para os
/// dois apps e as camadas Radar apenas quando o app pede (`radar: true`).
void main() {
  List<String> layerIds(Map<String, dynamic> style) => (style['layers'] as List)
      .map((layer) => (layer as Map)['id'] as String)
      .toList();

  group('MapStyles', () {
    test('a base e a rota existem sem o Radar', () {
      final style = MapStyles.consoleNoturnoStyle(dark: true);
      final ids = layerIds(style);
      final sources = style['sources'] as Map;

      expect(ids, containsAll(['background', 'road-label', 'route-line']));
      expect(sources.containsKey('openmaptiles'), isTrue);
      expect(sources.containsKey('route'), isTrue);

      // O calor é informação exclusiva do app do motorista.
      expect(sources.containsKey('demand'), isFalse);
      expect(sources.containsKey('driver'), isFalse);
      expect(ids.any((id) => id.startsWith('demand')), isFalse);
      expect(ids.any((id) => id.startsWith('driver')), isFalse);
    });

    test('radar: true acrescenta demanda e marcador sem perder a rota', () {
      final style = MapStyles.consoleNoturnoStyle(dark: true, radar: true);
      final ids = layerIds(style);
      final sources = style['sources'] as Map;

      expect(sources.keys, containsAll(['demand', 'driver', 'route']));
      expect(
        ids,
        containsAll([
          'demand-heat',
          'demand-outline',
          'demand-label',
          'driver-halo',
          'driver-dot',
          'driver-arrow',
          'route-line',
        ]),
      );

      // Calor abaixo dos rótulos; marcador do motorista por cima de tudo.
      expect(ids.indexOf('demand-heat'), lessThan(ids.indexOf('road-label')));
      expect(ids.indexOf('driver-arrow'),
          greaterThan(ids.indexOf('demand-label')));
    });

    test('claro e escuro geram JSON válido com paletas diferentes', () {
      final dark = MapStyles.consoleNoturnoStyle(dark: true, radar: true);
      final light = MapStyles.consoleNoturnoStyle(dark: false, radar: true);

      String bg(Map<String, dynamic> style) => ((style['layers'] as List)
              .cast<Map>()
              .firstWhere((l) => l['id'] == 'background'))['paint']
          ['background-color'] as String;

      expect(bg(dark), isNot(bg(light)));
      expect(MapStyles.consoleNoturnoStyleJson(dark: true, radar: true),
          contains('"version":8'));
    });
  });

  group('MapLayers', () {
    test('MapHeatZone vira feature [lon, lat] e satura o peso', () {
      final gj = MapLayers.demandGeoJson(const [
        MapHeatZone(
          lat: -8.76,
          lon: -63.90,
          weight: 3.2,
          callsLastHour: 38,
          label: 'Centro',
        ),
      ]);

      final f = (gj['features'] as List).first as Map<String, dynamic>;
      final coords = (f['geometry'] as Map)['coordinates'] as List;
      expect(coords[0], -63.90);
      expect(coords[1], -8.76);

      final props = f['properties'] as Map;
      expect(props['weight'], 1.0);
      expect(props['calls'], 38);
      expect(props['label'], 'Centro');
    });

    test('rota vira LineString e pontos com kind', () {
      final gj = MapLayers.routeGeoJson(
        points: const [
          LatLng(-8.7607, -63.9039),
          LatLng(-8.7647, -63.8969),
        ],
        origin: const LatLng(-8.7607, -63.9039),
        destination: const LatLng(-8.7647, -63.8969),
      );

      final kinds = (gj['features'] as List)
          .map((f) => ((f as Map)['properties'] as Map)['kind'])
          .toList();
      expect(kinds, containsAll(['route', 'origin', 'destination']));
    });

    test('a rampa de calor é a da marca', () {
      expect(MapLayers.heatColorHex(0), '#5CCFC3');
      expect(MapLayers.heatColorHex(1), '#FF6B5A');
    });
  });

  group('cameraFor', () {
    test('enquadra o traçado e nunca abre no mundo inteiro', () {
      final cam = cameraFor(
        const [
          LatLng(-8.7607, -63.9039),
          LatLng(-8.7647, -63.8969),
        ],
        const Size(380, 220),
      );
      expect(cam.zoom, inInclusiveRange(8.0, 16.5));
    });
  });
}
