import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:parceiro/src/api/client.dart';
import 'package:parceiro/src/map/partner_map.dart';
import 'package:parceiro/src/widgets/heatmap_map.dart';
import 'package:ten_map/ten_map.dart';

HeatZone _zone({
  double lat = -8.76,
  double lon = -63.90,
  double weight = 0.5,
  String? label = 'Centro',
  int calls = 38,
}) =>
    HeatZone(
      lat: lat,
      lon: lon,
      weight: weight,
      label: label,
      callsLastHour: calls,
    );

MapHeatZone _mapZone({
  double lat = -8.76,
  double lon = -63.90,
  double weight = 0.5,
  String? label = 'Centro',
  int calls = 38,
}) =>
    MapHeatZone(
      lat: lat,
      lon: lon,
      weight: weight,
      label: label,
      callsLastHour: calls,
    );

Map<String, dynamic> _layerById(
  Map<String, dynamic> style,
  String id,
) {
  final layers = style['layers'] as List;
  return layers.firstWhere((l) => (l as Map)['id'] == id)
      as Map<String, dynamic>;
}

/// Regra do MapLibre: `["zoom"]` só é aceito como **entrada** de um
/// `interpolate`/`step` que seja a expressão do topo da propriedade.
///
/// Devolve `true` quando a expressão respeita a regra.
bool _zoomRuleOk(dynamic node, {required bool topLevel}) {
  if (node is! List || node.isEmpty) return true;
  final op = node.first;
  if (op == 'zoom') return false; // zoom fora do input de interpolate/step

  if (op == 'interpolate' || op == 'step') {
    // interpolate: [op, interpolation, input, out1, stop1, ...]
    // step:        [op, input, default, out1, stop1, ...]
    final input = node.length > 2 ? node[2] : null;
    final inputIsZoom =
        input is List && input.isNotEmpty && input.first == 'zoom';
    if (inputIsZoom && !topLevel) return false;
    if (!inputIsZoom && !_zoomRuleOk(input, topLevel: false)) return false;

    for (var i = inputIsZoom ? 3 : 2; i < node.length; i++) {
      if (!_zoomRuleOk(node[i], topLevel: false)) return false;
    }
    return true;
  }

  // Expressão composta: nenhum filho pode conter zoom.
  for (final child in node.skip(1)) {
    if (!_zoomRuleOk(child, topLevel: false)) return false;
  }
  return true;
}

void main() {
  group('Style JSON (Console Noturno)', () {
    test('tem versão 8, glifos e as três fontes', () {
      final style = MapStyles.consoleNoturnoStyle(dark: true, radar: true);

      expect(style['version'], 8);
      // Sem `glyphs` os rótulos (symbol layers) não aparecem.
      expect(style['glyphs'], isNotNull);
      expect(style['glyphs'], contains('{fontstack}'));

      final sources = style['sources'] as Map;
      expect(sources.keys, containsAll(['openmaptiles', 'demand', 'driver']));
      // A rota das telas de oferta/navegação usa a **mesma** base: fonte
      // própria, alimentada em runtime.
      expect(sources.keys, contains('route'));

      final base = sources['openmaptiles'] as Map;
      expect(base['type'], 'vector');
      expect(base['url'], MapStyles.tilesUrl);

      // As fontes Radar começam vazias: o dado entra em runtime.
      for (final id in ['demand', 'driver', 'route']) {
        final src = sources[id] as Map;
        expect(src['type'], 'geojson');
        final data = src['data'] as Map;
        expect(data['type'], 'FeatureCollection');
        expect(data['features'], isEmpty);
      }
    });

    test('serializa em JSON válido (o MapLibre não aceita JSON inválido)', () {
      for (final dark in [true, false]) {
        final json = MapStyles.consoleNoturnoStyleJson(dark: dark);
        final decoded = jsonDecode(json);
        expect(decoded['version'], 8);
      }
    });

    test('tem as camadas base e as camadas Radar, na ordem certa', () {
      final style = MapStyles.consoleNoturnoStyle(dark: true, radar: true);
      final ids = (style['layers'] as List)
          .map((l) => (l as Map)['id'] as String)
          .toList();

      expect(
        ids,
        containsAll([
          'background',
          'water',
          'building',
          'road-casing',
          'road-minor',
          'road-major',
          'road-trunk',
          'road-label',
          'place-label',
          'demand-heat',
          'demand-outline',
          'demand-label',
          'driver-halo',
          'driver-dot',
          'driver-arrow',
          'route-casing',
          'route-line',
          'route-marker-ring',
          'route-marker-core',
        ]),
      );

      // O calor fica **abaixo** dos rótulos do mapa (senão o texto some) e
      // o marcador fica **por cima** de tudo.
      expect(ids.indexOf('demand-heat'), lessThan(ids.indexOf('road-label')));
      expect(
          ids.indexOf('demand-label'), greaterThan(ids.indexOf('place-label')));
      expect(
        ids.indexOf('driver-arrow'),
        greaterThan(ids.indexOf('demand-label')),
      );

      // A rota é o que o parceiro segue: acima do calor e abaixo dos rótulos
      // da rua (o nome da rua não pode ficar escondido pelo traçado).
      expect(ids.indexOf('route-line'), greaterThan(ids.indexOf('demand-heat')));
      expect(ids.indexOf('route-line'), lessThan(ids.indexOf('road-label')));
      expect(
        ids.indexOf('route-marker-core'),
        greaterThan(ids.indexOf('route-line')),
      );
    });

    test('a paleta do calor é a da marca (teal → âmbar → coral)', () {
      final style = MapStyles.consoleNoturnoStyle(dark: true, radar: true);
      final heat = _layerById(style, 'demand-heat');
      final color = heat['paint']['circle-color'] as List;

      // A rampa é um interpolate sobre o peso, com as três cores da marca
      // nas paradas: ["interpolate", ["linear"], ["get","weight"], 0, cor, ...]
      expect(color.first, 'interpolate');
      final cores = color.whereType<String>().toList();

      expect(cores, contains(MapLayers.heatColorHex(0)));
      expect(cores, contains(MapLayers.heatColorHex(0.5)));
      expect(cores, contains(MapLayers.heatColorHex(1)));

      expect(MapLayers.heatColorHex(0), '#5CCFC3');
      expect(MapLayers.heatColorHex(1), '#FF6B5A');
    });

    test('claro e escuro usam paletas diferentes', () {
      final dark = MapStyles.consoleNoturnoStyle(dark: true);
      final light = MapStyles.consoleNoturnoStyle(dark: false);

      final bgDark =
          _layerById(dark, 'background')['paint']['background-color'];
      final bgLight =
          _layerById(light, 'background')['paint']['background-color'];
      expect(bgDark, isNot(bgLight));
    });

    test('o rótulo da zona mostra o nome e as chamadas', () {
      final style = MapStyles.consoleNoturnoStyle(dark: true, radar: true);
      final label = _layerById(style, 'demand-label');
      final field = jsonEncode(label['layout']['text-field']);

      expect(field, contains('label'));
      expect(field, contains('calls'));
    });

    test('nenhuma expressão de zoom está aninhada (MapLibre recusa)', () {
      // O MapLibre só aceita `["zoom"]` como entrada de um interpolate/step
      // que seja a expressão **do topo** da propriedade. Se aninhar
      // (`["*", ["interpolate", ...["zoom"]...], ...]`) ele **descarta a
      // camada inteira** — e isso só apareceu no device, com o aviso
      // "zoom expression may only be used as input to a top-level step or
      // interpolate expression" no logcat.
      for (final dark in [true, false]) {
        for (final radar in [true, false]) {
          final style =
              MapStyles.consoleNoturnoStyle(dark: dark, radar: radar);
          for (final layer in style['layers'] as List) {
            final l = layer as Map;
            final id = l['id'];
            for (final bloco in ['paint', 'layout']) {
              final props = l[bloco];
              if (props is! Map) continue;
              for (final entry in props.entries) {
                expect(
                  _zoomRuleOk(entry.value, topLevel: true),
                  isTrue,
                  reason: 'expressão inválida em "$id.$bloco.${entry.key}"',
                );
              }
            }
          }
        }
      }
    });
  });

  group('GeoJSON da demanda', () {
    test('mapeia zona → feature com peso, rótulo e chamadas', () {
      final gj = MapLayers.demandGeoJson([
        _mapZone(lat: -8.76, lon: -63.90, weight: 0.8, calls: 38),
      ]);

      expect(gj['type'], 'FeatureCollection');
      final features = gj['features'] as List;
      expect(features, hasLength(1));

      final f = features.first as Map<String, dynamic>;
      // GeoJSON é [lon, lat] — inverter é o bug clássico.
      final coords = (f['geometry'] as Map)['coordinates'] as List;
      expect(coords[0], -63.90);
      expect(coords[1], -8.76);

      final props = f['properties'] as Map;
      expect(props['weight'], 0.8);
      expect(props['label'], 'Centro');
      expect(props['calls'], 38);
    });

    test('peso fora de 0..1 é limitado e rótulo nulo vira string vazia', () {
      final gj = MapLayers.demandGeoJson([
        _mapZone(weight: 3.2, label: null),
      ]);
      final props =
          ((gj['features'] as List).first as Map)['properties'] as Map;
      expect(props['weight'], 1.0);
      expect(props['label'], '');
    });

    test('sem zonas → coleção vazia', () {
      final gj = MapLayers.demandGeoJson([]);
      expect((gj['features'] as List), isEmpty);
    });
  });

  group('GeoJSON do marcador', () {
    test('tem seta, halo e ponto', () {
      final gj = MapLayers.driverGeoJson(lat: -8.76, lon: -63.90, online: true);
      final features = gj['features'] as List;
      expect(features, hasLength(3));

      final kinds = features
          .map((f) => ((f as Map)['properties'] as Map)['kind'])
          .toList();
      expect(kinds, containsAll(['arrow', 'halo', 'dot']));
    });

    test('heading 0 aponta para o norte e 90 para o leste', () {
      // Geometria da seta: Polygon -> [anel] -> [tip, left, right, tip].
      List<double> tipDe(Map<String, dynamic> gj) {
        final geometry =
            ((gj['features'] as List).first as Map)['geometry'] as Map;
        final ring = (geometry['coordinates'] as List).first as List;
        return (ring.first as List).cast<double>();
      }

      final norte = MapLayers.driverGeoJson(
          lat: -8.76, lon: -63.90, headingDeg: 0, online: true);
      final tipNorte = tipDe(norte);
      expect(tipNorte[1], greaterThan(-8.76)); // latitude sobe (norte)
      expect(tipNorte[0], closeTo(-63.90, 0.0001));

      final leste = MapLayers.driverGeoJson(
          lat: -8.76, lon: -63.90, headingDeg: 90, online: true);
      final tipLeste = tipDe(leste);
      expect(tipLeste[0], greaterThan(-63.90)); // longitude aumenta (leste)
      expect(tipLeste[1], closeTo(-8.76, 0.0001));
    });

    test('a cor segue o status (online teal, offline cinza)', () {
      final on = MapLayers.driverGeoJson(lat: -8.76, lon: -63.90, online: true);
      final off =
          MapLayers.driverGeoJson(lat: -8.76, lon: -63.90, online: false);

      String cor(Map<String, dynamic> gj) =>
          ((gj['features'] as List).first as Map)['properties']['color']
              as String;

      expect(cor(on), MapLayers.driverColorHex(true));
      expect(cor(off), MapLayers.driverColorHex(false));
      expect(cor(on), isNot(cor(off)));
    });
  });

  group('GeoJSON da rota', () {
    test('o traçado vira LineString em [lon, lat]', () {
      final gj = MapLayers.routeGeoJson(
        points: const [
          LatLng(-8.7607, -63.9039),
          LatLng(-8.7647, -63.8969),
        ],
      );

      expect(gj['type'], 'FeatureCollection');
      final features = gj['features'] as List;
      expect(features, hasLength(1));

      final f = features.first as Map<String, dynamic>;
      final geometry = f['geometry'] as Map;
      expect(geometry['type'], 'LineString');
      // GeoJSON é [lon, lat] — inverter é o bug clássico.
      final coords = geometry['coordinates'] as List;
      expect(coords.first, [-63.9039, -8.7607]);
      expect(coords.last, [-63.8969, -8.7647]);
      expect((f['properties'] as Map)['kind'], 'route');
    });

    test('origem, destino e parceiro viram pontos com o seu kind', () {
      final gj = MapLayers.routeGeoJson(
        points: const [
          LatLng(-8.7607, -63.9039),
          LatLng(-8.7647, -63.8969),
        ],
        origin: const LatLng(-8.7607, -63.9039),
        destination: const LatLng(-8.7647, -63.8969),
        driver: const LatLng(-8.7610, -63.9040),
      );

      final features = gj['features'] as List;
      final kinds = features
          .map((f) => ((f as Map)['properties'] as Map)['kind'])
          .toList();
      expect(kinds, containsAll(['route', 'origin', 'destination', 'driver']));

      final ponto = features
          .where((f) => ((f as Map)['properties'] as Map)['kind'] == 'driver')
          .cast<Map<String, dynamic>>()
          .first;
      final geometry = ponto['geometry'] as Map;
      expect(geometry['type'], 'Point');
      expect((geometry['coordinates'] as List), [-63.9040, -8.7610]);
    });

    test('sem traçado e sem pontos → coleção vazia', () {
      final gj = MapLayers.routeGeoJson(points: const []);
      expect((gj['features'] as List), isEmpty);
    });
  });

  group('RouteMapView (widget)', () {
    testWidgets('no host de teste usa o fallback raster', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: RouteMapView(
            points: [LatLng(-8.7607, -63.9039), LatLng(-8.7647, -63.8969)],
            origin: LatLng(-8.7607, -63.9039),
            destination: LatLng(-8.7647, -63.8969),
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 50));

      // O host de teste não tem o plugin nativo: o mapa cai no raster.
      expect(find.byType(FlutterMap), findsOneWidget);
    });
  });

  group('Rampa de calor', () {
    test('heatColorHex e heatColor dizem a mesma coisa', () {
      for (final w in [0.0, 0.25, 0.5, 0.75, 1.0]) {
        final c = MapLayers.heatColor(w);
        final hex =
            '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}'
                .toUpperCase();
        expect(MapLayers.heatColorHex(w), hex);
      }
    });

    test('a rampa vai de teal a coral e satura fora de 0..1', () {
      expect(MapLayers.heatColorHex(0), '#5CCFC3');
      expect(MapLayers.heatColorHex(1), '#FF6B5A');
      expect(MapLayers.heatColorHex(-5), '#5CCFC3');
      expect(MapLayers.heatColorHex(9), '#FF6B5A');
    });

    test('o fallback raster usa exatamente a mesma rampa', () {
      // O vetorial e o raster têm que mostrar a mesma informação.
      expect(heatColor(0.7), MapLayers.heatColor(0.7));
    });
  });

  group('MapProvider', () {
    test('o provedor do piloto é vetorial e o de reserva é raster', () {
      expect(MapProviders.openFreeMap.isVector, isTrue);
      expect(MapProviders.openFreeMap.backend, MapBackend.vector);
      expect(MapProviders.osmRaster.isVector, isFalse);
      expect(MapProviders.osmRaster.backend, MapBackend.raster);
    });

    test('todo provedor tem atribuição (política do OSM)', () {
      for (final p in [MapProviders.openFreeMap, MapProviders.osmRaster]) {
        expect(p.attribution, isNotEmpty);
        expect(p.attribution, contains('OpenStreetMap'));
      }
    });

    test('iguais se comparam iguais e o hashCode bate', () {
      const a = MapProvider(
        id: 'x',
        label: 'X',
        backend: MapBackend.vector,
        attribution: '© OSM',
        styleUrl: 'https://exemplo/style.json',
      );
      const b = MapProvider(
        id: 'x',
        label: 'Outro nome',
        backend: MapBackend.vector,
        attribution: '© OSM',
        styleUrl: 'https://exemplo/style.json',
      );
      const c = MapProvider(
        id: 'x',
        label: 'X',
        backend: MapBackend.raster,
        attribution: '© OSM',
      );

      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
    });

    test('o provedor público não permite cache offline', () {
      // A política de tiles do OSMF proíbe prefetch no servidor público.
      expect(MapProviders.openFreeMap.offlineCapable, isFalse);
      expect(MapProviders.osmRaster.offlineCapable, isFalse);
    });
  });

  group('Capacidade de plataforma', () {
    test('o host de teste não tem backend vetorial (usa o fallback raster)',
        () {
      // O `flutter test` roda no Windows: `dart:io` diz isWindows, então o
      // app cai no raster — o teste não fala com o plugin nativo.
      expect(supportsVectorMap, isFalse);
    });
  });

  group('PartnerMap (widget)', () {
    testWidgets('no host de teste usa o fallback raster sem marca DEMO',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: PartnerMap(
          zones: [_zone()],
          showAttribution: false,
        ),
      ));
      await tester.pump(const Duration(milliseconds: 50));

      // Backend raster (o vetorial exigiria o plugin nativo).
      expect(find.byType(HeatmapMap), findsOneWidget);
      // O mapa do motorista não exibe texto DEMO.
      expect(find.text('DEMO'), findsNothing);
      expect(find.textContaining('DEMO'), findsNothing);
    });

    testWidgets('sem dado real o mapa continua limpo', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: PartnerMap(
          zones: [],
          showAttribution: false,
        ),
      ));
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('DEMO'), findsNothing);
    });
  });
}
