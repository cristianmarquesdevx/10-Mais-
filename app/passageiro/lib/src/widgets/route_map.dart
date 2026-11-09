import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../api/route_service.dart';
import '../map/route_map_view.dart';
import '../theme/theme.dart';

/// Mapa real (OpenStreetMap) com a rota de carro traçada entre [origin] e
/// [destination] — o traçado vem do OSRM por ruas, não de uma linha reta.
///
/// Sem [destination] o mapa só localiza a origem (estado de espera do C2).
/// Enquanto a rota carrega, mostra o chip "Traçando rota…"; se o servidor de
/// rotas falhar, desenha o traçado aproximado e avisa no chip.
///
/// O **desenho** é do [RouteMapView] (MapLibre no Android/iOS, raster no
/// fallback): esta widget cuida só do traçado e do chip.
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

  /// Posição do motorista (opcional) — desenhada como carro no mapa.
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

    return ClipRRect(
      borderRadius: BorderRadius.circular(AppSpace.radiusSheet),
      child: SizedBox(
        height: widget.height,
        child: Stack(
          children: [
            RouteMapView(
              points: points,
              origin: widget.origin,
              destination: dest,
              driver: widget.driver,
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
