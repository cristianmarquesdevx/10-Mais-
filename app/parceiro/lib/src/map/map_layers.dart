import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../api/client.dart';

/// Camadas "Radar" do mapa: a **demanda** (calor) e o **marcador** do
/// motorista.
///
/// Aqui mora só **dado** (GeoJSON) e a **paleta**. O desenho (style JSON)
/// está em `map_styles.dart`. Separar os dois permite que o mapa vetorial
/// (MapLibre) e o fallback raster mostrem exatamente a mesma informação —
/// e que a suíte de teste verifique a rampa de cor sem emulador.
abstract final class MapLayers {
  // -------------------------------------------------------------------------
  // Paleta (direção visual "Mix": Console Noturno + elementos Radar)
  // -------------------------------------------------------------------------

  /// Demanda baixa: teal claro.
  static const heatLow = Color(0xFF5CCFC3);

  /// Demanda média: âmbar.
  static const heatMid = Color(0xFFFFB84D);

  /// Demanda alta: coral.
  static const heatHigh = Color(0xFFFF6B5A);

  /// Motorista **online**: teal da marca.
  static const driverOnline = Color(0xFF05998C);

  /// Motorista **offline**: cinza (legível no tile claro e no escuro).
  static const driverOffline = Color(0xFF8C9A9C);

  /// Id da fonte GeoJSON da demanda (deve bater com o style JSON).
  static const demandSourceId = 'demand';

  /// Id da fonte GeoJSON do motorista (deve bater com o style JSON).
  static const driverSourceId = 'driver';

  /// Id da fonte GeoJSON da rota (deve bater com o style JSON).
  static const routeSourceId = 'route';

  // -------------------------------------------------------------------------
  // Rampa de calor
  // -------------------------------------------------------------------------

  /// Cor da rampa para um peso 0..1.
  ///
  /// Substitui a rampa HSV arco-íris (magenta/verde-lima), que brigava com
  /// o teal da marca. A mesma função serve o vetorial e o raster.
  static Color heatColor(double w) {
    final x = w.clamp(0, 1).toDouble();
    if (x < 0.5) {
      return Color.lerp(heatLow, heatMid, x / 0.5)!;
    }
    return Color.lerp(heatMid, heatHigh, (x - 0.5) / 0.5)!;
  }

  /// Mesma rampa em `#RRGGBB` (formato que o style JSON do MapLibre usa).
  static String heatColorHex(double w) {
    final c = heatColor(w);
    return '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}'
        .toUpperCase();
  }

  /// Cor do marcador conforme o status operacional.
  static Color driverColor(bool online) =>
      online ? driverOnline : driverOffline;

  /// Mesma cor em `#RRGGBB`.
  static String driverColorHex(bool online) {
    final c = driverColor(online);
    return '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}'
        .toUpperCase();
  }

  // -------------------------------------------------------------------------
  // Demanda (calor)
  // -------------------------------------------------------------------------

  /// GeoJSON das zonas quentes.
  ///
  /// `calls_last_hour` viaja como propriedade para o rótulo da camada — é o
  /// número que o motorista usa para decidir. `label` pode ser nulo: o
  /// rótulo mostra só as chamadas.
  static Map<String, dynamic> demandGeoJson(List<HeatZone> zones) => {
        'type': 'FeatureCollection',
        'features': [
          for (final z in zones)
            {
              'type': 'Feature',
              'geometry': {
                'type': 'Point',
                'coordinates': [z.lon, z.lat],
              },
              'properties': {
                'weight': z.weight.clamp(0, 1).toDouble(),
                'label': z.label ?? '',
                'calls': z.callsLastHour,
              },
            },
        ],
      };

  // -------------------------------------------------------------------------
  // Rota (traçado + pontos)
  // -------------------------------------------------------------------------

  /// GeoJSON da rota percorrida e dos pontos que importam.
  ///
  /// - `LineString` (`kind: 'route'`): o traçado por ruas (OSRM);
  /// - `Point` (`kind: 'origin' | 'destination' | 'driver'`): origem,
  ///   destino e a posição do parceiro.
  ///
  /// Aqui mora só o **dado**: quem desenha (e com que cor) é o style JSON.
  static Map<String, dynamic> routeGeoJson({
    required List<LatLng> points,
    LatLng? origin,
    LatLng? destination,
    LatLng? driver,
  }) =>
      {
        'type': 'FeatureCollection',
        'features': [
          if (points.length > 1)
            {
              'type': 'Feature',
              'geometry': {
                'type': 'LineString',
                'coordinates': [
                  for (final p in points) [p.longitude, p.latitude],
                ],
              },
              'properties': {'kind': 'route'},
            },
          for (final m in [
            (kind: 'origin', at: origin),
            (kind: 'destination', at: destination),
            (kind: 'driver', at: driver),
          ])
            if (m.at != null)
              {
                'type': 'Feature',
                'geometry': {
                  'type': 'Point',
                  'coordinates': [m.at!.longitude, m.at!.latitude],
                },
                'properties': {'kind': m.kind},
              },
        ],
      };

  // -------------------------------------------------------------------------
  // Marcador do motorista
  // -------------------------------------------------------------------------

  /// GeoJSON do marcador: seta (heading), halo e ponto.
  ///
  /// A seta é um triângulo calculado em Dart — assim o heading é exato e não
  /// depende de imagem/ícone no estilo (que exigiria sprite).
  ///
  /// Geometrias diferentes na mesma fonte: a seta é `Polygon` (camada
  /// `fill`) e o halo/ponto são `Point` (camadas `circle`).
  static Map<String, dynamic> driverGeoJson({
    required double lat,
    required double lon,
    double headingDeg = 0,
    required bool online,
  }) {
    final color = driverColorHex(online);
    final headingRad = headingDeg * math.pi / 180;

    // Direção do heading: 0° = norte, 90° = leste (sentido horário).
    final east = math.sin(headingRad);
    final north = math.cos(headingRad);

    const metersPerDegLat = 111320.0;
    final metersPerDegLon = 111320.0 * math.cos(lat * math.pi / 180).abs();

    // Setas de 26 m de comprimento e 9 m de meia-base.
    const len = 26.0;
    const halfBase = 9.0;
    const back = 4.0;

    List<double> point(double e, double n) => [
          lon + e / metersPerDegLon,
          lat + n / metersPerDegLat,
        ];

    final tip = point(east * len, north * len);
    final left = point(
      -north * halfBase - east * back,
      east * halfBase - north * back,
    );
    final right = point(
      north * halfBase - east * back,
      -east * halfBase - north * back,
    );

    return {
      'type': 'FeatureCollection',
      'features': [
        {
          'type': 'Feature',
          'geometry': {
            'type': 'Polygon',
            'coordinates': [
              [tip, left, right, tip],
            ],
          },
          'properties': {'kind': 'arrow', 'color': color},
        },
        {
          'type': 'Feature',
          'geometry': {
            'type': 'Point',
            'coordinates': [lon, lat],
          },
          'properties': {'kind': 'halo', 'color': color},
        },
        {
          'type': 'Feature',
          'geometry': {
            'type': 'Point',
            'coordinates': [lon, lat],
          },
          'properties': {'kind': 'dot', 'color': color},
        },
      ],
    };
  }

  /// Coleção GeoJSON vazia — valor inicial das fontes no style JSON.
  static Map<String, dynamic> emptyGeoJson() => {
        'type': 'FeatureCollection',
        'features': <Map<String, dynamic>>[],
      };
}
