import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../api/route_service.dart';
import '../theme/theme.dart';

/// Mapa real (OpenStreetMap) com a rota de carro traçada entre [origin] e
/// [destination] — o traçado vem do OSRM por ruas, não de uma linha reta.
///
/// Sem [destination] o mapa só localiza a origem (estado de espera do C2).
/// Enquanto a rota carrega, mostra o chip "Traçando rota…"; se o servidor de
/// rotas falhar, desenha o traçado aproximado e avisa no chip.
class RouteMap extends StatefulWidget {
  const RouteMap({
    super.key,
    required this.origin,
    this.destination,
    this.driver,
    this.height = 220,
    this.showHint = true,
    this.service,
    this.onRoute,
  });

  final LatLng origin;
  final LatLng? destination;

  /// Posição do parceiro (opcional) — desenhada como carro no mapa.
  final LatLng? driver;

  final double height;
  final bool showHint;
  final RouteService? service;

  /// Entrega o traçado para a tela exibir km/min junto do preço.
  final ValueChanged<RouteResult?>? onRoute;

  @override
  State<RouteMap> createState() => _RouteMapState();
}

class _RouteMapState extends State<RouteMap> {
  late final RouteService _service = widget.service ?? RouteService();

  RouteResult? _route;
  bool _loading = false;
  int _requestId = 0;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(RouteMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    final moved = oldWidget.origin != widget.origin ||
        oldWidget.destination != widget.destination;
    if (moved) _sync();
  }

  void _sync() {
    final dest = widget.destination;
    if (dest == null) {
      _requestId++;
      setState(() {
        _route = null;
        _loading = false;
      });
      _emitRoute(null);
      return;
    }
    final id = ++_requestId;
    setState(() => _loading = true);
    _service.route(widget.origin, dest).then((route) {
      if (!mounted || id != _requestId) return;
      setState(() {
        _route = route;
        _loading = false;
      });
      _emitRoute(route);
    });
  }

  /// Nunca chama o setState da tela-mãe durante o build: o primeiro `_sync`
  /// roda no initState, que acontece no meio do build do parent.
  void _emitRoute(RouteResult? route) {
    if (widget.onRoute == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onRoute?.call(route);
    });
  }

  @override
  Widget build(BuildContext context) {
    final dest = widget.destination;
    final route = _route;
    final points = route?.points ?? [widget.origin];
    final hasRoute = dest != null && points.length > 1;
    // Enquadramento calculado aqui: o mapa ocupa a largura da tela menos os
    // 16dp de padding lateral do scaffold.
    final cam = hasRoute
        ? cameraFor(
            points, Size(MediaQuery.sizeOf(context).width - 32, widget.height))
        : null;

    return ClipRRect(
      borderRadius: BorderRadius.circular(AppSpace.radiusSheet),
      child: SizedBox(
        height: widget.height,
        child: Stack(
          children: [
            // A câmera é recriada quando o traçado muda (key) e já nasce no
            // centro/zoom calculados. `fitCamera`/`move` em postFrame pegavam
            // câmera sem tamanho e abriam o mapa no mundo inteiro.
            FlutterMap(
              key: ValueKey(hasRoute
                  ? 'route-${points.length}-'
                      '${route!.distanceMeters.toStringAsFixed(1)}'
                  : 'origin-${widget.origin.latitude}'),
              options: MapOptions(
                initialCenter: cam?.center ?? widget.origin,
                initialZoom: cam?.zoom ?? 14.4,
                interactionOptions: const InteractionOptions(
                  flags: InteractiveFlag.pinchZoom |
                      InteractiveFlag.drag |
                      InteractiveFlag.doubleTapZoom,
                ),
              ),
              children: [
                // OSM padrão + modo escuro do flutter_map (sem chave de API).
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'app.dezemais.parceiro',
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
                  Marker(
                    point: widget.origin,
                    width: 26,
                    height: 26,
                    child: const _OriginDot(),
                  ),
                  if (dest != null)
                    Marker(
                      point: dest,
                      width: 38,
                      height: 38,
                      alignment: Alignment.topCenter,
                      child: const _DestPin(),
                    ),
                  if (widget.driver != null)
                    Marker(
                      point: widget.driver!,
                      width: 36,
                      height: 36,
                      child: const _DriverPin(),
                    ),
                ]),
                const SimpleAttributionWidget(
                  source: Text(
                    'OpenStreetMap contributors',
                    style: TextStyle(fontSize: 9, color: Colors.white70),
                  ),
                  backgroundColor: Color(0x990B1220),
                  alignment: Alignment.bottomRight,
                ),
              ],
            ),
            Positioned(
              left: AppSpace.m,
              top: AppSpace.m,
              child: _StatusChip(
                loading: _loading,
                route: route,
                waiting: dest == null && widget.showHint,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({
    required this.loading,
    required this.route,
    required this.waiting,
  });

  final bool loading;
  final RouteResult? route;
  final bool waiting;

  @override
  Widget build(BuildContext context) {
    final (text, icon, color) = loading
        ? ('Traçando rota…', null, AppColors.onGraphite)
        : route != null
            ? (
                '${route!.approx ? 'Rota aproximada' : 'Rota real'} · ${route!.label}',
                route!.approx ? Icons.moving_outlined : Icons.route_rounded,
                route!.approx ? AppColors.onGraphiteMuted : AppColors.primary,
              )
            : waiting
                ? (
                    'Escolha o destino',
                    Icons.search_rounded,
                    AppColors.onGraphiteMuted,
                  )
                : (
                    'Sua localização',
                    Icons.my_location_rounded,
                    AppColors.onGraphiteMuted
                  );
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpace.m, vertical: AppSpace.xs + 2),
      decoration: BoxDecoration(
        color: const Color(0xE6232C30),
        borderRadius: BorderRadius.circular(AppSpace.radiusChip),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (loading)
          const SizedBox(
            width: 11,
            height: 11,
            child: CircularProgressIndicator(
                strokeWidth: 1.6, color: AppColors.onGraphite),
          )
        else if (icon != null)
          Icon(icon, size: 13, color: color),
        if (loading || icon != null) const SizedBox(width: 6),
        Text(
          text,
          style: const TextStyle(
            fontSize: 11,
            height: 1.1,
            fontWeight: FontWeight.w600,
            color: AppColors.onGraphite,
          ),
        ),
      ]),
    );
  }
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

/// Câmera (centro + zoom) que enquadra [points] numa área [size].
///
/// Web Mercator: fracção do mundo ocupada pelo traçado vs. pixels
/// disponíveis. Clamp 8–16,5 cobre de uma viagem intermunicipal a uma rua
/// específica sem nunca abrir no mundo inteiro.
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
    minLat = math.min(minLat, p.latitude);
    maxLat = math.max(maxLat, p.latitude);
    minLon = math.min(minLon, p.longitude);
    maxLon = math.max(maxLon, p.longitude);
  }
  final center = LatLng((minLat + maxLat) / 2, (minLon + maxLon) / 2);
  final usableW = math.max(40.0, size.width - padding * 2);
  final usableH = math.max(40.0, size.height - padding * 2);
  double zoomFor(double worldFraction, double pixels) => worldFraction <= 1e-9
      ? 18
      : math.log(pixels / (256 * worldFraction)) / math.ln2;
  final zLon = zoomFor((maxLon - minLon).abs() / 360, usableW);
  final zLat =
      zoomFor((mercY(maxLat) - mercY(minLat)).abs() / (2 * math.pi), usableH);
  return (center: center, zoom: math.min(zLon, zLat).clamp(8.0, 16.5));
}
