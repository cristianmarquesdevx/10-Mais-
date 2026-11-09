import 'dart:convert';

import 'package:flutter/material.dart';

import 'map_layers.dart';

/// Estilo vetorial do mapa — direção visual "Console Noturno".
///
/// Esta é a base compartilhada pela marca: o app do motorista acrescenta as
/// camadas Radar (demanda); o do passageiro usa o mesmo estilo **sem** calor.
///
/// O estilo é **gerado em Dart**, não um arquivo de asset, por três motivos:
/// 1. o mesmo código serve o tema claro e o escuro (uma paleta, dois
///    conjuntos de cores) — o mapa acompanha o app;
/// 2. dá para testar (a suíte verifica cores, camadas e fontes);
/// 3. a base do mapa fica no próprio estilo; o app do motorista acrescenta
///    as camadas Radar em cima desta mesma paleta.
///
/// Fontes (OpenMapTiles via OpenFreeMap):
/// - tiles: `https://tiles.openfreemap.org/planet` (TileJSON, maxzoom 14);
/// - glifos: `https://tiles.openfreemap.org/fonts/{fontstack}/{range}.pbf`
///   (necessário para os `symbol` layers — sem ele os rótulos não aparecem).
abstract final class MapStyles {
  /// TileJSON da fonte vetorial.
  static const tilesUrl = 'https://tiles.openfreemap.org/planet';

  /// Servidor de glifos (textos).
  static const glyphsUrl =
      'https://tiles.openfreemap.org/fonts/{fontstack}/{range}.pbf';

  /// Pilha de fontes usada nos rótulos.
  static const fontStack = 'Noto Sans Regular';

  /// Zoom inicial da câmera (Porto Velho).
  static const initialZoom = 13.4;

  /// Paleta do Console Noturno (tema escuro) e sua contraparte clara.
  static const _dark = _MapPalette(
    background: Color(0xFF0B1214),
    water: Color(0xFF10262B),
    waterLine: Color(0xFF17333A),
    landcover: Color(0xFF12211E),
    landuse: Color(0xFF142621),
    building: Color(0xFF131C1F),
    buildingOutline: Color(0xFF1C292D),
    roadCasing: Color(0xFF080D0F),
    roadMinor: Color(0xFF1B262A),
    roadMajor: Color(0xFF2C3E43),
    roadTrunk: Color(0xFF3C5A5C),
    roadLabel: Color(0xFF6E8A88),
    label: Color(0xFF8FA9A6),
    labelHalo: Color(0xFF0B1214),
    heatLabel: Color(0xFFEAF4F2),
    heatLabelHalo: Color(0xFF0B1214),
    driverRing: Color(0xFFFFFFFF),
    routeCasing: Color(0xFF0B1214),
    routeLine: Color(0xFF05998C),
  );

  static const _light = _MapPalette(
    background: Color(0xFFEDF3F2),
    water: Color(0xFFCBDFE4),
    waterLine: Color(0xFFA9CBD3),
    landcover: Color(0xFFE2ECE4),
    landuse: Color(0xFFDDE9E0),
    building: Color(0xFFE1E9E7),
    buildingOutline: Color(0xFFCFDCD9),
    roadCasing: Color(0xFFC4D3D0),
    roadMinor: Color(0xFFFFFFFF),
    roadMajor: Color(0xFFDCE6E4),
    roadTrunk: Color(0xFFBFD4D1),
    roadLabel: Color(0xFF6C817E),
    label: Color(0xFF3C5150),
    labelHalo: Color(0xFFFFFFFF),
    heatLabel: Color(0xFF12211F),
    heatLabelHalo: Color(0xFFFFFFFF),
    driverRing: Color(0xFFFFFFFF),
    routeCasing: Color(0xFFBFD4D1),
    // Teal da marca escurecido: no mapa claro o #05998C não tem contraste
    // suficiente para uma linha de 6 px.
    routeLine: Color(0xFF03786E),
  );

  /// Style JSON (dark = true) pronto para o MapLibre.
  static String consoleNoturnoStyleJson({required bool dark}) =>
      jsonEncode(consoleNoturnoStyle(dark: dark));

  /// Style JSON do Console Noturno como mapa — a forma testável.
  static Map<String, dynamic> consoleNoturnoStyle({required bool dark}) {
    final p = dark ? _dark : _light;
    return {
      'version': 8,
      'name': dark ? 'Console Noturno' : 'Console Noturno (claro)',
      'glyphs': glyphsUrl,
      'sources': {
        'openmaptiles': {
          'type': 'vector',
          'url': tilesUrl,
        },
        // Fonte da rota: o traçado e os pontos entram em runtime.
        MapLayers.routeSourceId: {
          'type': 'geojson',
          'data': MapLayers.emptyGeoJson(),
        },
      },
      'layers': [
        // --- base ---
        _background(p),
        _landcover(p),
        _landuse(p),
        _water(p),
        _waterway(p),
        _building(p),
        // --- vias (hierarquia de "central de operações") ---
        _roadCasing(p),
        _roadMinor(p),
        _roadMajor(p),
        _roadTrunk(p),
        // --- rota: traçado + pontos (acima das vias, abaixo dos rótulos) ---
        _routeCasing(p),
        _routeLine(p),
        _routeMarkerRing(p),
        _routeMarkerCore(p),
        // --- rótulos do mapa ---
        _roadLabels(p),
        _waterLabels(p),
        _placeLabels(p),
      ],
    };
  }

  // -------------------------------------------------------------------------
  // Base
  // -------------------------------------------------------------------------

  static Map<String, dynamic> _background(_MapPalette p) => {
        'id': 'background',
        'type': 'background',
        'paint': {'background-color': _hex(p.background)},
      };

  static Map<String, dynamic> _landcover(_MapPalette p) => {
        'id': 'landcover',
        'type': 'fill',
        'source': 'openmaptiles',
        'source-layer': 'landcover',
        'filter': [
          'match',
          ['get', 'class'],
          ['wood', 'grass', 'farmland', 'park'],
          true,
          false,
        ],
        'paint': {
          'fill-color': _hex(p.landcover),
          'fill-opacity': 0.7,
        },
      };

  static Map<String, dynamic> _landuse(_MapPalette p) => {
        'id': 'landuse',
        'type': 'fill',
        'source': 'openmaptiles',
        'source-layer': 'landuse',
        'filter': [
          '==',
          ['get', 'class'],
          'residential'
        ],
        'paint': {
          'fill-color': _hex(p.landuse),
          'fill-opacity': 0.35,
        },
      };

  static Map<String, dynamic> _water(_MapPalette p) => {
        'id': 'water',
        'type': 'fill',
        'source': 'openmaptiles',
        'source-layer': 'water',
        'filter': [
          'all',
          [
            'match',
            ['geometry-type'],
            ['MultiPolygon', 'Polygon'],
            true,
            false,
          ],
          [
            '!=',
            ['get', 'brunnel'],
            'tunnel'
          ],
        ],
        'paint': {
          'fill-antialias': false,
          'fill-color': _hex(p.water),
        },
      };

  static Map<String, dynamic> _waterway(_MapPalette p) => {
        'id': 'waterway',
        'type': 'line',
        'source': 'openmaptiles',
        'source-layer': 'waterway',
        'filter': [
          'match',
          ['geometry-type'],
          ['LineString', 'MultiLineString'],
          true,
          false,
        ],
        'paint': {
          'line-color': _hex(p.waterLine),
          'line-width': [
            'interpolate',
            ['exponential', 1.5],
            ['zoom'],
            10,
            0.6,
            18,
            6,
          ],
        },
      };

  static Map<String, dynamic> _building(_MapPalette p) => {
        'id': 'building',
        'type': 'fill',
        'source': 'openmaptiles',
        'source-layer': 'building',
        'minzoom': 13,
        'filter': [
          'match',
          ['geometry-type'],
          ['MultiPolygon', 'Polygon'],
          true,
          false,
        ],
        'paint': {
          'fill-color': _hex(p.building),
          'fill-outline-color': _hex(p.buildingOutline),
        },
      };

  // -------------------------------------------------------------------------
  // Vias
  // -------------------------------------------------------------------------

  static Map<String, dynamic> _roadCasing(_MapPalette p) => {
        'id': 'road-casing',
        'type': 'line',
        'source': 'openmaptiles',
        'source-layer': 'transportation',
        'filter': _roadClassFilter(
          ['motorway', 'trunk', 'primary', 'secondary'],
        ),
        'layout': {
          'line-cap': 'round',
          'line-join': 'round',
        },
        'paint': {
          'line-color': _hex(p.roadCasing),
          'line-width': [
            'interpolate',
            ['exponential', 1.4],
            ['zoom'],
            8,
            1.2,
            14,
            4,
            18,
            16,
          ],
        },
      };

  static Map<String, dynamic> _roadMinor(_MapPalette p) => {
        'id': 'road-minor',
        'type': 'line',
        'source': 'openmaptiles',
        'source-layer': 'transportation',
        'filter': _roadClassFilter(
          ['minor', 'service', 'track', 'path', 'raceway'],
        ),
        'layout': {
          'line-cap': 'round',
          'line-join': 'round',
        },
        'paint': {
          'line-color': _hex(p.roadMinor),
          'line-opacity': 0.85,
          'line-width': [
            'interpolate',
            ['exponential', 1.5],
            ['zoom'],
            12,
            0.4,
            18,
            8,
          ],
        },
      };

  static Map<String, dynamic> _roadMajor(_MapPalette p) => {
        'id': 'road-major',
        'type': 'line',
        'source': 'openmaptiles',
        'source-layer': 'transportation',
        'filter': _roadClassFilter(['primary', 'secondary']),
        'layout': {
          'line-cap': 'round',
          'line-join': 'round',
        },
        'paint': {
          'line-color': _hex(p.roadMajor),
          'line-width': [
            'interpolate',
            ['exponential', 1.4],
            ['zoom'],
            8,
            0.8,
            14,
            3,
            18,
            13,
          ],
        },
      };

  static Map<String, dynamic> _roadTrunk(_MapPalette p) => {
        'id': 'road-trunk',
        'type': 'line',
        'source': 'openmaptiles',
        'source-layer': 'transportation',
        'filter': _roadClassFilter(['motorway', 'trunk']),
        'layout': {
          'line-cap': 'round',
          'line-join': 'round',
        },
        'paint': {
          'line-color': _hex(p.roadTrunk),
          'line-width': [
            'interpolate',
            ['exponential', 1.4],
            ['zoom'],
            6,
            0.8,
            14,
            3.4,
            18,
            14,
          ],
        },
      };

  // -------------------------------------------------------------------------
  // Rótulos do mapa
  // -------------------------------------------------------------------------

  static Map<String, dynamic> _roadLabels(_MapPalette p) => {
        'id': 'road-label',
        'type': 'symbol',
        'source': 'openmaptiles',
        'source-layer': 'transportation_name',
        'minzoom': 12,
        'layout': {
          'symbol-placement': 'line',
          'symbol-spacing': 350,
          'text-field': _nameExpression(),
          'text-font': [fontStack],
          'text-size': 10,
          'text-max-angle': 30,
          'text-rotation-alignment': 'map',
          'text-pitch-alignment': 'viewport',
        },
        'paint': {
          'text-color': _hex(p.roadLabel),
          'text-halo-color': _hex(p.labelHalo),
          'text-halo-width': 1.2,
          'text-halo-blur': 0.2,
        },
      };

  static Map<String, dynamic> _waterLabels(_MapPalette p) => {
        'id': 'water-label',
        'type': 'symbol',
        'source': 'openmaptiles',
        'source-layer': 'water_name',
        'layout': {
          'symbol-placement': 'line',
          'text-field': _nameExpression(),
          'text-font': [fontStack],
          'text-size': 11,
          'text-rotation-alignment': 'map',
          'text-pitch-alignment': 'viewport',
        },
        'paint': {
          'text-color': _hex(p.roadLabel),
          'text-halo-color': _hex(p.labelHalo),
          'text-halo-width': 1.2,
        },
      };

  static Map<String, dynamic> _placeLabels(_MapPalette p) => {
        'id': 'place-label',
        'type': 'symbol',
        'source': 'openmaptiles',
        'source-layer': 'place',
        'filter': [
          'match',
          ['get', 'class'],
          [
            'city',
            'town',
            'suburb',
            'neighbourhood',
            'village',
            'hamlet',
            'isolated_dwelling',
          ],
          true,
          false,
        ],
        'layout': {
          'text-field': _nameExpression(),
          'text-font': [fontStack],
          'text-size': [
            'interpolate',
            ['linear'],
            ['zoom'],
            10,
            10,
            15,
            13,
          ],
          'text-transform': 'uppercase',
          'text-letter-spacing': 0.04,
          'text-allow-overlap': false,
        },
        'paint': {
          'text-color': _hex(p.label),
          'text-halo-color': _hex(p.labelHalo),
          'text-halo-width': 1.4,
          'text-halo-blur': 0.3,
        },
      };

  // -------------------------------------------------------------------------
  // Rota (traçado + origem/destino/motorista)
  // -------------------------------------------------------------------------

  /// Contorno do traçado: linha escura e grossa sob a linha da marca, para
  /// o traçado não sumir em cima de uma rua clara.
  static Map<String, dynamic> _routeCasing(_MapPalette p) => {
        'id': 'route-casing',
        'type': 'line',
        'source': MapLayers.routeSourceId,
        'filter': ['==', ['get', 'kind'], 'route'],
        'layout': {
          'line-cap': 'round',
          'line-join': 'round',
        },
        'paint': {
          'line-color': _hex(p.routeCasing),
          'line-width': 10,
          'line-opacity': 0.9,
        },
      };

  /// A linha da rota: teal da marca.
  static Map<String, dynamic> _routeLine(_MapPalette p) => {
        'id': 'route-line',
        'type': 'line',
        'source': MapLayers.routeSourceId,
        'filter': ['==', ['get', 'kind'], 'route'],
        'layout': {
          'line-cap': 'round',
          'line-join': 'round',
        },
        'paint': {
          'line-color': _hex(p.routeLine),
          'line-width': 6,
        },
      };

  /// Anel dos pontos (origem/destino/motorista).
  static Map<String, dynamic> _routeMarkerRing(_MapPalette p) => {
        'id': 'route-marker-ring',
        'type': 'circle',
        'source': MapLayers.routeSourceId,
        'filter': ['!=', ['get', 'kind'], 'route'],
        'paint': {
          'circle-radius': [
            'case',
            ['==', ['get', 'kind'], 'destination'],
            9,
            7,
          ],
          'circle-color': 'rgba(0,0,0,0)',
          'circle-stroke-color': [
            'case',
            ['==', ['get', 'kind'], 'destination'],
            _hex(p.driverRing),
            _hex(p.routeLine),
          ],
          'circle-stroke-width': [
            'case',
            ['==', ['get', 'kind'], 'destination'],
            2,
            4,
          ],
        },
      };

  /// Miolo dos pontos: destino preenchido de teal; origem e motorista
  /// brancos com o anel da marca.
  static Map<String, dynamic> _routeMarkerCore(_MapPalette p) => {
        'id': 'route-marker-core',
        'type': 'circle',
        'source': MapLayers.routeSourceId,
        'filter': ['!=', ['get', 'kind'], 'route'],
        'paint': {
          'circle-radius': [
            'case',
            ['==', ['get', 'kind'], 'destination'],
            8,
            5,
          ],
          'circle-color': [
            'case',
            ['==', ['get', 'kind'], 'destination'],
            _hex(p.routeLine),
            _hex(p.driverRing),
          ],
        },
      };

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

  /// Nome do elemento, em latim quando existir.
  static List<dynamic> _nameExpression() => [
        'coalesce',
        ['get', 'name:latin'],
        ['get', 'name'],
      ];

  static List<dynamic> _roadClassFilter(List<String> classes) => [
        'match',
        ['get', 'class'],
        classes,
        true,
        false,
      ];

  /// Cor do MapLibre: `#RRGGBB` (o `Color` do Flutter é ARGB).
  static String _hex(Color c) =>
      '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';
}

/// Paleta do mapa (uma por tema).
class _MapPalette {
  const _MapPalette({
    required this.background,
    required this.water,
    required this.waterLine,
    required this.landcover,
    required this.landuse,
    required this.building,
    required this.buildingOutline,
    required this.roadCasing,
    required this.roadMinor,
    required this.roadMajor,
    required this.roadTrunk,
    required this.roadLabel,
    required this.label,
    required this.labelHalo,
    required this.heatLabel,
    required this.heatLabelHalo,
    required this.driverRing,
    required this.routeCasing,
    required this.routeLine,
  });

  final Color background;
  final Color water;
  final Color waterLine;
  final Color landcover;
  final Color landuse;
  final Color building;
  final Color buildingOutline;
  final Color roadCasing;
  final Color roadMinor;
  final Color roadMajor;
  final Color roadTrunk;
  final Color roadLabel;
  final Color label;
  final Color labelHalo;

  /// Texto do rótulo da zona quente (contraste com o mapa).
  final Color heatLabel;
  final Color heatLabelHalo;

  /// Contorno do marcador (contraste com a cor do status).
  final Color driverRing;

  /// Contorno do traçado da rota (sob a linha teal).
  final Color routeCasing;

  /// Cor da linha da rota (teal da marca, escurecido no tema claro).
  final Color routeLine;
}
