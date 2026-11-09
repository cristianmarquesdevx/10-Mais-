import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
// O MapLibre tem o **próprio** `LatLng`/`LatLngBounds`: prefixado, para não
// brigar com o `latlong2` (que é o tipo do traçado) nem com o `flutter_map`.
import 'package:maplibre_gl/maplibre_gl.dart' as ml;

import '../theme/theme.dart';
import 'map_capabilities.dart';
import 'map_layers.dart';
import 'map_styles.dart';

/// Mapa da rota do passageiro (destino, viagem e recibo) — **mesma base visual** do mapa do
/// motorista, agora vetorial.
///
/// A tela nunca escolhe entre MapLibre e raster: ela entrega o traçado e os
/// pontos para este widget, e ele decide o que dá para desenhar **naquele**
/// device:
///
/// - **vetorial** (MapLibre, Android/iOS): style JSON "Console Noturno" da
///   marca + camada da rota (traçado teal, origem, destino e motorista);
/// - **raster** (flutter_map + tiles do OSM): fallback — entra em cena no
///   teste de widget (host Windows) e quando o plugin vetorial não está
///   disponível.
///
/// Em ambos os backends a informação é a mesma: o traçado por ruas e os
/// três pontos.
class RouteMapView extends StatelessWidget {
  const RouteMapView({
    super.key,
    required this.points,
    this.origin,
    this.destination,
    this.driver,
    this.padding = 28,
    this.showAttribution = true,
  });

  /// Traçado por ruas (OSRM). Vazio = ainda não carregou (ou falhou).
  final List<LatLng> points;

  /// Embarque (ponto do passageiro).
  final LatLng? origin;

  /// Destino da corrida.
  final LatLng? destination;

  /// Posição do motorista.
  final LatLng? driver;

  /// Margem (em px) entre o traçado e a borda da câmera.
  final double padding;

  /// O crédito do OpenStreetMap aparece no canto (política do OSM).
  final bool showAttribution;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    if (supportsVectorMap) {
      return _VectorRouteMap(
        points: points,
        origin: origin,
        destination: destination,
        driver: driver,
        padding: padding,
        dark: dark,
        showAttribution: showAttribution,
      );
    }
    return _RasterRouteMap(
      points: points,
      origin: origin,
      destination: destination,
      driver: driver,
      padding: padding,
      showAttribution: showAttribution,
    );
  }
}

/// Mapa vetorial (MapLibre): style da marca + camada da rota.
class _VectorRouteMap extends StatefulWidget {
  const _VectorRouteMap({
    required this.points,
    required this.origin,
    required this.destination,
    required this.driver,
    required this.padding,
    required this.dark,
    required this.showAttribution,
  });

  final List<LatLng> points;
  final LatLng? origin;
  final LatLng? destination;
  final LatLng? driver;
  final double padding;
  final bool dark;
  final bool showAttribution;

  @override
  State<_VectorRouteMap> createState() => _VectorRouteMapState();
}

class _VectorRouteMapState extends State<_VectorRouteMap> {
  ml.MapLibreMapController? _controller;

  /// O estilo já carregou? Sem isso, `setGeoJsonSource` estoura
  /// `STYLE_NOT_READY` — e dado nenhum é perdido: o `onStyleLoaded` reenvia.
  bool _styleReady = false;

  @override
  void didUpdateWidget(_VectorRouteMap old) {
    super.didUpdateWidget(old);

    if (old.dark != widget.dark) {
      // Troca de tema = troca de paleta: o estilo é recarregado e o dado
      // da fonte da rota é reenviado no `onStyleLoaded`.
      _styleReady = false;
      _controller?.setStyle(_styleJson());
    }

    if (!identical(old.points, widget.points) ||
        old.origin != widget.origin ||
        old.destination != widget.destination ||
        old.driver != widget.driver) {
      _pushRoute();
      _fitCamera();
    }
  }

  String _styleJson() => MapStyles.consoleNoturnoStyleJson(dark: widget.dark);

  Future<void> _onStyleLoaded() async {
    _styleReady = true;
    await _pushRoute();
    _fitCamera();
  }

  Future<void> _pushRoute() async {
    final c = _controller;
    if (c == null || !_styleReady) return;
    try {
      await c.setGeoJsonSource(
        MapLayers.routeSourceId,
        MapLayers.routeGeoJson(
          points: widget.points,
          origin: widget.origin,
          destination: widget.destination,
          driver: widget.driver,
        ),
      );
    } catch (_) {
      // Estilo recarregando: o `onStyleLoaded` reenvia o dado.
    }
  }

  /// Enquadra o traçado (ou o ponto, quando ainda não há rota).
  void _fitCamera() {
    final c = _controller;
    if (c == null) return;
    final pts = _framePoints();
    if (pts.isEmpty) return;
    final bounds = _boundsOf(pts);
    if (bounds == null) return;
    // O ajuste acontece depois do frame: antes disso o controller ainda não
    // tem o tamanho do mapa e a câmera abriria no mundo inteiro.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      try {
        c.moveCamera(
          ml.CameraUpdate.newLatLngBounds(
            bounds,
            left: widget.padding,
            top: widget.padding,
            right: widget.padding,
            bottom: widget.padding,
          ),
        );
      } catch (_) {
        // Sem tamanho pronto: a câmera inicial já serve.
      }
    });
  }

  /// Pontos que a câmera precisa enxergar: o traçado + os três marcadores.
  List<LatLng> _framePoints() {
    final pts = <LatLng>[
      ...widget.points,
      if (widget.origin != null) widget.origin!,
      if (widget.destination != null) widget.destination!,
      if (widget.driver != null) widget.driver!,
    ];
    return pts;
  }

  /// Envelope do traçado (sudoeste → nordeste). `null` se não dá para
  /// calcular (ponto único sem extensão).
  ml.LatLngBounds? _boundsOf(List<LatLng> pts) {
    if (pts.isEmpty) return null;
    var minLat = pts.first.latitude, maxLat = pts.first.latitude;
    var minLon = pts.first.longitude, maxLon = pts.first.longitude;
    for (final p in pts.skip(1)) {
      minLat = p.latitude < minLat ? p.latitude : minLat;
      maxLat = p.latitude > maxLat ? p.latitude : maxLat;
      minLon = p.longitude < minLon ? p.longitude : minLon;
      maxLon = p.longitude > maxLon ? p.longitude : maxLon;
    }
    // Um ponto só (ou quase) não tem envelope: abre no zoom inicial.
    if ((maxLat - minLat).abs() < 1e-7 && (maxLon - minLon).abs() < 1e-7) {
      return null;
    }
    return ml.LatLngBounds(
      southwest: ml.LatLng(minLat, minLon),
      northeast: ml.LatLng(maxLat, maxLon),
    );
  }

  @override
  Widget build(BuildContext context) {
    final initial = widget.origin ??
        widget.destination ??
        (widget.points.isNotEmpty ? widget.points.first : null);
    if (initial == null) {
      // Sem ponto nenhum: não há mapa para abrir (a tela avisa e espera).
      return const ColoredBox(color: Color(0xFF0B1214));
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        ml.MapLibreMap(
          styleString: _styleJson(),
          initialCameraPosition: ml.CameraPosition(
            target: ml.LatLng(initial.latitude, initial.longitude),
            zoom: MapStyles.initialZoom,
          ),
          onMapCreated: (c) {
            _controller = c;
            _pushRoute();
            _fitCamera();
          },
          onStyleLoadedCallback: _onStyleLoaded,
          attributionEnabled: false,
          logoEnabled: false,
          compassEnabled: false,
          minMaxZoomPreference: const ml.MinMaxZoomPreference(3, 18),
        ),
        // O crédito do OpenStreetMap é obrigatório (política do OSM): o
        // MapLibre vem com `attributionEnabled: false` (o botão nativo
        // cobriria o mapa), então o crédito é desenhado aqui.
        if (widget.showAttribution)
          Positioned(
            right: 6,
            bottom: 4,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: const Color(0x990B1220),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                  child: Text(
                    '© OpenStreetMap · OpenFreeMap',
                    style: TextStyle(fontSize: 9, color: Colors.white70),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Fallback raster (flutter_map + tiles do OpenStreetMap).
class _RasterRouteMap extends StatelessWidget {
  const _RasterRouteMap({
    required this.points,
    required this.origin,
    required this.destination,
    required this.driver,
    required this.padding,
    required this.showAttribution,
  });

  final List<LatLng> points;
  final LatLng? origin;
  final LatLng? destination;
  final LatLng? driver;
  final double padding;
  final bool showAttribution;

  @override
  Widget build(BuildContext context) {
    final hasRoute = points.length > 1;
    final origin0 = origin;

    // O enquadramento usa o tamanho **real** do mapa (e não um chute):
    // o `LayoutBuilder` dá a caixa que o mapa ocupa na tela.
    return LayoutBuilder(
      builder: (context, constraints) {
        final cam = _cameraFor(context, constraints.biggest);
        return FlutterMap(
          key: ValueKey(hasRoute
              ? 'route-${points.length}-${points.last.latitude}'
              : 'origin-${origin0?.latitude ?? 0}'),
          options: MapOptions(
            initialCenter: cam?.center ?? origin0 ?? const LatLng(0, 0),
            initialZoom: cam?.zoom ?? 14.4,
            interactionOptions: const InteractionOptions(
              flags: InteractiveFlag.pinchZoom |
                  InteractiveFlag.drag |
                  InteractiveFlag.doubleTapZoom,
            ),
          ),
          children: [
            // OSM padrão (ruas e nomes reais) sem chave de API.
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'app.dezemais.passageiro',
            ),
            if (hasRoute)
              PolylineLayer(polylines: [
                Polyline(
                  points: points,
                  strokeWidth: 9,
                  color: const Color(0xAA0B1220),
                ),
                Polyline(
                  points: points,
                  strokeWidth: 5,
                  color: AppColors.primary,
                  borderStrokeWidth: 0,
                ),
              ]),
            MarkerLayer(markers: [
              if (origin0 != null)
                Marker(
                  point: origin0,
                  width: 26,
                  height: 26,
                  child: const _OriginDot(),
                ),
              if (destination != null)
                Marker(
                  point: destination!,
                  width: 38,
                  height: 38,
                  alignment: Alignment.topCenter,
                  child: const _DestPin(),
                ),
              if (driver != null)
                Marker(
                  point: driver!,
                  width: 36,
                  height: 36,
                  child: const _DriverPin(),
                ),
            ]),
            if (showAttribution)
              const SimpleAttributionWidget(
                source: Text(
                  'OpenStreetMap contributors',
                  style: TextStyle(fontSize: 9, color: Colors.white70),
                ),
                backgroundColor: Color(0x990B1220),
                alignment: Alignment.bottomRight,
              ),
          ],
        );
      },
    );
  }

  /// Câmera que enquadra o traçado na área disponível.
  ({LatLng center, double zoom})? _cameraFor(BuildContext context, Size area) {
    final pts = <LatLng>[
      ...points,
      if (origin != null) origin!,
      if (destination != null) destination!,
    ];
    if (pts.length < 2) return null;
    final size = Size(
      area.width.isFinite && area.width > 0
          ? area.width
          : MediaQuery.sizeOf(context).width,
      area.height.isFinite && area.height > 0 ? area.height : 220,
    );
    return cameraFor(pts, size, padding: padding);
  }
}

/// Enquadramento (centro + zoom) de um traçado numa área — mesma conta do
/// Web Mercator usada antes no `RouteMap`.
///
/// Clamp 8–16,5: de uma viagem intermunicipal a uma rua específica sem
/// nunca abrir no mundo inteiro.
({LatLng center, double zoom}) cameraFor(
  List<LatLng> points,
  Size size, {
  double padding = 32,
}) {
  double mercY(double lat) =>
      math.log(math.tan(math.pi / 4 + lat * math.pi / 360));
  var minLat = points.first.latitude, maxLat = points.first.latitude;
  var minLon = points.first.longitude, maxLon = points.first.longitude;
  for (final p in points.skip(1)) {
    minLat = p.latitude < minLat ? p.latitude : minLat;
    maxLat = p.latitude > maxLat ? p.latitude : maxLat;
    minLon = p.longitude < minLon ? p.longitude : minLon;
    maxLon = p.longitude > maxLon ? p.longitude : maxLon;
  }
  final center = LatLng((minLat + maxLat) / 2, (minLon + maxLon) / 2);
  final usableW = (size.width - padding * 2).clamp(40.0, double.infinity);
  final usableH = (size.height - padding * 2).clamp(40.0, double.infinity);
  double zoomFor(double worldFraction, double pixels) => worldFraction <= 1e-9
      ? 18
      : math.log(pixels / (256 * worldFraction)) / math.ln2;
  final zLon = zoomFor((maxLon - minLon).abs() / 360, usableW);
  final zLat =
      zoomFor((mercY(maxLat) - mercY(minLat)).abs() / (2 * math.pi), usableH);
  return (center: center, zoom: math.min(zLon, zLat).clamp(8.0, 16.5));
}

/// Origem: ponto branco com anel verde — a posição do passageiro.
class _OriginDot extends StatelessWidget {
  const _OriginDot();

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
          border: Border.all(color: AppColors.primary, width: 5),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.35),
              blurRadius: 8,
              offset: const Offset(0, 2)),
          ],
        ),
      );
}

/// Destino: pino verde com bandeira — a ponta aponta para o ponto exato.
class _DestPin extends StatelessWidget {
  const _DestPin();

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.topCenter,
        child: Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            gradient: AppGradients.primary,
            borderRadius: BorderRadius.circular(15),
            border: Border.all(color: Colors.white, width: 2),
            boxShadow: [
              BoxShadow(
                  color: Colors.black.withValues(alpha: 0.4),
                  blurRadius: 10,
                  offset: const Offset(0, 3)),
            ],
          ),
          child: const Icon(Icons.flag_rounded, size: 14, color: AppColors.ink),
        ),
      );
}

/// Parceiro: carro branco com aro verde.
class _DriverPin extends StatelessWidget {
  const _DriverPin();

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
          border: Border.all(color: AppColors.primary, width: 2),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withValues(alpha: 0.35),
                blurRadius: 8,
                offset: const Offset(0, 2)),
          ],
        ),
        child: const Icon(Icons.directions_car_rounded,
            size: 18, color: AppColors.graphiteDeep),
      );
}
