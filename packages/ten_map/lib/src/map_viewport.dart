import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:latlong2/latlong.dart';

/// Estado de câmera do mapa, suficiente para projetar coordenadas na tela.
///
/// O mapa compartilhado tem dois backends — vetorial (MapLibre) e raster
/// (`flutter_map`) — e as telas desenham coisas **em Flutter** por cima dos
/// dois: pinos do radar, a varredura, o pulso do "você". Em vez de cada tela
/// depender do tipo de câmera de um backend, o [BaseMapView] emite este
/// viewport e quem desenha só precisa saber projetar.
///
/// A conta é a Web Mercator (EPSG:3857) com o mundo de **256 px no zoom 0** —
/// a convenção do OSM/`flutter_map`. O backend MapLibre usa 512 px por tile
/// (mundo de `512·2^zoom`), então o mapa converte o zoom na fronteira: para
/// ele, `zoom - 1`. Assim `13.4` significa a mesma área nos dois backends.
///
/// Sem rotação e sem inclinação: o mapa do produto é sempre "norte para cima".
@immutable
class MapViewport {
  const MapViewport({
    required this.center,
    required this.zoom,
    required this.size,
  });

  /// Lado do mundo em pixels no zoom 0 (convenção OSM).
  static const int tileSize = 256;

  /// Metros por pixel no equador, no zoom 0 (raio equatorial WGS84).
  static const double equatorMetersPerPixel = 156543.03392804097;

  /// Latitude máxima representável na projeção (limite da Web Mercator).
  static const double maxLatitude = 85.05112878;

  /// Ponto que fica no centro da tela.
  final LatLng center;

  /// Zoom na convenção OSM (`mundo = 256·2^zoom`).
  final double zoom;

  /// Tamanho lógico do mapa na tela.
  final Size size;

  /// Largura do mundo em pixels no zoom atual.
  double get worldSize => tileSize * math.pow(2, zoom).toDouble();

  /// Ponto no plano Mercator, em pixels do mundo.
  Offset _world(LatLng point) {
    final lat = point.latitude.clamp(-maxLatitude, maxLatitude);
    final sinLat = math.sin(lat * math.pi / 180);
    final x = (point.longitude + 180) / 360 * worldSize;
    final y = (0.5 - math.log((1 + sinLat) / (1 - sinLat)) / (4 * math.pi)) *
        worldSize;
    return Offset(x, y);
  }

  /// Onde [point] cai na tela, em pixels lógicos, com a origem no canto
  /// superior esquerdo do mapa.
  Offset project(LatLng point) =>
      size.center(Offset.zero) + _world(point) - _world(center);

  /// Quantos pixels valem [km] quilômetros na latitude de [at] (padrão: o
  /// centro do mapa). É o raio do radar desenhado em escala real.
  double pixelsForKm(double km, {LatLng? at}) {
    final latitude = (at ?? center).latitude.clamp(-maxLatitude, maxLatitude);
    final metersPerPixel = equatorMetersPerPixel *
        math.cos(latitude * math.pi / 180) /
        math.pow(2, zoom);
    return km * 1000 / metersPerPixel;
  }

  MapViewport copyWith({LatLng? center, double? zoom, Size? size}) =>
      MapViewport(
        center: center ?? this.center,
        zoom: zoom ?? this.zoom,
        size: size ?? this.size,
      );

  @override
  bool operator ==(Object other) =>
      other is MapViewport &&
      other.center == center &&
      other.zoom == zoom &&
      other.size == size;

  @override
  int get hashCode => Object.hash(center, zoom, size);

  @override
  String toString() =>
      'MapViewport($center, z=$zoom, ${size.width}x${size.height})';
}
