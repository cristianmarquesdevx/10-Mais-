import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:passageiro/src/map/map_layers.dart';
import 'package:passageiro/src/map/map_styles.dart';

void main() {
  group('Mapa do passageiro', () {
    test('usa a mesma base Console Noturno do motorista', () {
      final style = MapStyles.consoleNoturnoStyle(dark: true);

      expect(style['version'], 8);
      expect(style['sources'], contains('openmaptiles'));
      expect(style['glyphs'], MapStyles.glyphsUrl);

      final ids = (style['layers'] as List)
          .map((layer) => (layer as Map)['id'])
          .toSet();
      expect(
          ids,
          containsAll(<String>[
            'background',
            'water',
            'road-casing',
            'road-label',
            'place-label',
            'route-casing',
            'route-line',
            'route-marker-ring',
            'route-marker-core',
          ]));
    });

    test('a rota fica acima das vias e abaixo dos rótulos', () {
      final ids = (MapStyles.consoleNoturnoStyle(dark: true)['layers'] as List)
          .map((layer) => (layer as Map)['id'] as String)
          .toList();

      expect(ids.indexOf('route-line'), greaterThan(ids.indexOf('road-trunk')));
      expect(ids.indexOf('route-line'), lessThan(ids.indexOf('road-label')));
    });

    test('a fonte da rota começa vazia e é geojson', () {
      final sources = MapStyles.consoleNoturnoStyle(dark: true)['sources']
          as Map;
      final route = sources['route'] as Map;

      expect(route['type'], 'geojson');
      final data = route['data'] as Map;
      expect(data['type'], 'FeatureCollection');
      expect(data['features'], isEmpty);
    });

    test('não tem camada de calor de chamadas nem marcador Radar', () {
      final style = MapStyles.consoleNoturnoStyle(dark: true);

      final ids = (style['layers'] as List)
          .map((layer) => (layer as Map)['id'])
          .toSet();

      // Calor de chamadas é informação exclusiva do app do motorista.
      expect(ids.any((id) => '$id'.startsWith('demand')), isFalse);
      expect(ids.any((id) => '$id'.startsWith('driver')), isFalse);

      final sources = style['sources'] as Map;
      expect(sources.containsKey('demand'), isFalse);
      expect(sources.containsKey('driver'), isFalse);
    });

    test('o tema claro troca a paleta sem perder a base', () {
      final dark = MapStyles.consoleNoturnoStyle(dark: true);
      final light = MapStyles.consoleNoturnoStyle(dark: false);

      final darkBackground = (dark['layers'] as List)
          .cast<Map>()
          .firstWhere((layer) => layer['id'] == 'background');
      final lightBackground = (light['layers'] as List)
          .cast<Map>()
          .firstWhere((layer) => layer['id'] == 'background');

      expect(
        darkBackground['paint']['background-color'],
        isNot(lightBackground['paint']['background-color']),
      );
    });
  });

  group('GeoJSON da rota (passageiro)', () {
    test('o traçado vira LineString em [lon, lat]', () {
      final gj = MapLayers.routeGeoJson(
        points: const [
          LatLng(-8.7607, -63.9039),
          LatLng(-8.7647, -63.8969),
        ],
      );

      final features = gj['features'] as List;
      expect(features, hasLength(1));

      final geometry = (features.first as Map)['geometry'] as Map;
      expect(geometry['type'], 'LineString');
      final coords = geometry['coordinates'] as List;
      expect(coords.first, [-63.9039, -8.7607]);
      expect(coords.last, [-63.8969, -8.7647]);
    });

    test('origem, destino e motorista viram pontos com o seu kind', () {
      final gj = MapLayers.routeGeoJson(
        points: const [
          LatLng(-8.7607, -63.9039),
          LatLng(-8.7647, -63.8969),
        ],
        origin: const LatLng(-8.7607, -63.9039),
        destination: const LatLng(-8.7647, -63.8969),
        driver: const LatLng(-8.7610, -63.9040),
      );

      final kinds = (gj['features'] as List)
          .map((f) => ((f as Map)['properties'] as Map)['kind'])
          .toList();
      expect(kinds, containsAll(['route', 'origin', 'destination', 'driver']));
    });

    test('sem traçado e sem pontos → coleção vazia', () {
      expect((MapLayers.routeGeoJson(points: const [])['features'] as List),
          isEmpty);
    });
  });
}
