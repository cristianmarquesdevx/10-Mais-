import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
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

  group('MapViewport', () {
    const centro = LatLng(-8.7607, -63.9039);
    const area = Size(400, 800);

    test('o centro do mapa cai no meio da tela', () {
      const vp = MapViewport(center: centro, zoom: 13.4, size: area);
      final p = vp.project(centro);
      expect(p.dx, closeTo(area.width / 2, 0.001));
      expect(p.dy, closeTo(area.height / 2, 0.001));
    });

    test('1 km para o norte vale pixelsForKm(1) pixels', () {
      const vp = MapViewport(center: centro, zoom: 13.4, size: area);
      // 1 km de latitude ≈ 1/111,32 grau.
      final norte = LatLng(centro.latitude + 1 / 111.32, centro.longitude);
      final p = vp.project(norte);
      expect(vp.pixelsForKm(1), closeTo(area.height / 2 - p.dy, 1));
      expect(vp.pixelsForKm(1), greaterThan(50));
    });

    test('um zoom a mais dobra os pixels por quilômetro', () {
      const a = MapViewport(center: centro, zoom: 13.4, size: area);
      const b = MapViewport(center: centro, zoom: 14.4, size: area);
      expect(b.pixelsForKm(1), closeTo(a.pixelsForKm(1) * 2, 0.001));
    });

    testWidgets('a projeção bate com a do flutter_map (mesma convenção)',
        (tester) async {
      final controller = MapController();
      await tester.pumpWidget(MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 400,
            height: 600,
            child: FlutterMap(
              mapController: controller,
              options:
                  const MapOptions(initialCenter: centro, initialZoom: 13.4),
              children: const [],
            ),
          ),
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      final camera = controller.camera;
      final vp = MapViewport(
        center: camera.center,
        zoom: camera.zoom,
        size: camera.nonRotatedSize,
      );
      const point = LatLng(-8.755, -63.894);
      final esperado = camera.latLngToScreenOffset(point);
      final obtido = vp.project(point);
      expect(obtido.dx, closeTo(esperado.dx, 0.5));
      expect(obtido.dy, closeTo(esperado.dy, 0.5));
    });
  });

  group('BaseMapView', () {
    const centro = LatLng(-8.7607, -63.9039);

    testWidgets('emite o viewport e posiciona o marcador pela projeção',
        (tester) async {
      MapViewport? emitted;
      await tester.pumpWidget(MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 400,
            height: 600,
            child: BaseMapView(
              center: centro,
              zoom: 13.4,
              onViewport: (vp) => emitted = vp,
              markers: const [
                MapMarker(
                  point: centro,
                  width: 40,
                  height: 40,
                  child: SizedBox(key: Key('me')),
                ),
              ],
            ),
          ),
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(emitted, isNotNull);
      expect(emitted!.size, const Size(400, 600));
      expect(emitted!.zoom, closeTo(13.4, 0.01));

      final area = tester.getRect(find.byType(BaseMapView));
      final marcador = tester.getRect(find.byKey(const Key('me')));
      expect(marcador.center.dx, closeTo(area.center.dx, 1));
      expect(marcador.center.dy, closeTo(area.center.dy, 1));
    });

    testWidgets('um marcador fora da tela não é desenhado', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 400,
            height: 600,
            child: BaseMapView(
              center: centro,
              zoom: 13.4,
              markers: [
                MapMarker(
                  point: LatLng(-8.9, -63.9),
                  width: 40,
                  height: 40,
                  child: SizedBox(key: Key('longe')),
                ),
              ],
            ),
          ),
        ),
      ));
      await tester.pump();

      expect(find.byKey(const Key('longe')), findsNothing);
    });

    testWidgets('o crédito do OSM cita a fonte do backend em uso',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: SizedBox(
          width: 400,
          height: 600,
          child: BaseMapView(center: centro, zoom: 13.4),
        ),
      ));
      await tester.pump();

      // No host de teste o backend é o raster (tiles do OSM). O crédito não
      // pode prometer OpenFreeMap (a fonte do vetorial) aqui.
      final attribution = tester.widget<MapAttribution>(
        find.byType(MapAttribution),
      );
      expect(attribution.label, contains('OpenStreetMap'));
      expect(attribution.label, isNot(contains('OpenFreeMap')));
    });
  });
}
