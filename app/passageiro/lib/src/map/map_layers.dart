import 'package:latlong2/latlong.dart';

/// Camadas de **dado** do mapa do passageiro.
///
/// O passageiro não tem a camada Radar (demanda) do motorista: aqui mora só
/// a rota (traçado + origem/destino/parceiro). O desenho (style JSON) está
/// em `map_styles.dart`.
abstract final class MapLayers {
  /// Id da fonte GeoJSON da rota (deve bater com o style JSON).
  static const routeSourceId = 'route';

  /// GeoJSON da rota percorrida e dos pontos que importam.
  ///
  /// - `LineString` (`kind: 'route'`): o traçado por ruas (OSRM);
  /// - `Point` (`kind: 'origin' | 'destination' | 'driver'`): origem,
  ///   destino e a posição do motorista.
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

  /// Coleção GeoJSON vazia — valor inicial das fontes no style JSON.
  static Map<String, dynamic> emptyGeoJson() => {
        'type': 'FeatureCollection',
        'features': <Map<String, dynamic>>[],
      };
}
