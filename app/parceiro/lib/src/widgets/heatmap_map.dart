import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../api/client.dart';
import '../theme/theme.dart';

/// Mapa do parceiro (ponto de troca do MapProvider — R1): tiles reais do
/// OpenStreetMap (tiles padrão, escurecidos no cliente) com nomes reais de
/// ruas/bairros, camada de calor por zona, marcador pulsante do parceiro e
/// atribuição OSM obrigatória.
///
/// A animação (pulso do marcador + calor) só roda quando há zonas —
/// testes ficam livres de ticker infinito.
class HeatmapMap extends StatefulWidget {
  const HeatmapMap({
    super.key,
    required this.zones,
    this.center = const GeoPoint(-8.7607, -63.9039), // Porto Velho
    this.showLocation = true,
    this.showAttribution = true,
  });

  final List<HeatZone> zones;
  final GeoPoint center;
  final bool showLocation;

  /// O painel desenha o mapa atrás dos botões flutuantes e repete a
  /// atribuição no rodapé: ali o crédito embutido no mapa ficaria coberto.
  final bool showAttribution;

  @override
  State<HeatmapMap> createState() => _HeatmapMapState();
}

class _HeatmapMapState extends State<HeatmapMap>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  );

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(HeatmapMap old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    if (widget.zones.isEmpty) {
      _ctrl.stop();
      _ctrl.value = 0;
    } else if (!_ctrl.isAnimating) {
      _ctrl.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return ColoredBox(
      // Base visível mesmo sem rede: escura no tema escuro, clara no claro.
      color: dark ? AppColorsDark.graphiteDeep : AppColors.background,
      child: FlutterMap(
        options: MapOptions(
          initialCenter: LatLng(widget.center.lat, widget.center.lon),
          initialZoom: 13.4,
          interactionOptions: const InteractionOptions(
            flags: InteractiveFlag.pinchZoom |
                InteractiveFlag.drag |
                InteractiveFlag.doubleTapZoom,
          ),
        ),
        children: [
          // OSM padrão (ruas/nomes reais). No tema escuro o tile recebe o
          // filtro de modo escuro do flutter_map; no claro ficam os tiles
          // originais (mapa claro), mantendo o tema todo claro.
          // CARTO/Stadia exigem chave e desenham "API KEY REQUIRED" no mapa.
          TileLayer(
            urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
            userAgentPackageName: 'app.dezemais.parceiro',
            tileBuilder: dark ? darkModeTileBuilder : null,
          ),
          // Calor por zona + rótulos (reagem ao ticker via rebuild da camada).
          AnimatedBuilder(
            animation: _ctrl,
            builder: (context, _) => CircleLayer(
              circles: [
                for (final z in widget.zones)
                  CircleMarker(
                    point: LatLng(z.lat, z.lon),
                    // Raio em metros proporcional ao peso da zona.
                    radius: 260 + 900 * z.weight,
                    useRadiusInMeter: true,
                    color: heatColor(z.weight).withValues(
                        alpha:
                            0.10 + 0.26 * z.weight * (0.8 + 0.2 * _ctrl.value)),
                    borderColor: heatColor(z.weight).withValues(alpha: 0.45),
                    borderStrokeWidth: 1,
                  ),
              ],
            ),
          ),
          if (widget.showLocation)
            MarkerLayer(markers: [
              Marker(
                point: LatLng(widget.center.lat, widget.center.lon),
                width: 64,
                height: 64,
                child: _PulsingMe(animation: _ctrl),
              ),
            ]),
          MarkerLayer(
            // Rótulos das zonas quentes acima do círculo correspondente.
            markers: [
              for (final z in widget.zones)
                if (z.label != null && z.weight >= 0.25)
                  Marker(
                    point: LatLng(z.lat, z.lon),
                    width: 190,
                    height: 26,
                    alignment: Alignment(0, -1.4 - 0.9 * z.weight),
                    child: _ZoneLabel(zone: z),
                  ),
            ],
          ),
          if (widget.showAttribution)
            const SimpleAttributionWidget(
              source: Text('© OpenStreetMap contributors'),
              alignment: Alignment.bottomRight,
            ),
        ],
      ),
    );
  }
}

/// Rótulo da zona: nome + chamadas/h, com leve sombra sobre os tiles.
class _ZoneLabel extends StatelessWidget {
  const _ZoneLabel({required this.zone});

  final HeatZone zone;

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: t.surface.withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(AppSpace.radiusChip),
        border: Border.all(color: t.hairline.withValues(alpha: 0.35)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        child: Text(
          '${zone.label} · ${zone.callsLastHour} chamadas/h',
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: t.ink,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

/// Marcador do parceiro: anel verde + pulso.
class _PulsingMe extends StatelessWidget {
  const _PulsingMe({required this.animation});

  final Animation<double> animation;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) {
        final t = Curves.easeInOut.transform(animation.value);
        return CustomPaint(painter: _PulsePainter(progress: t));
      },
    );
  }
}

class _PulsePainter extends CustomPainter {
  _PulsePainter({required this.progress});

  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    canvas.drawCircle(
      c,
      18 + 14 * progress,
      Paint()..color = AppColors.earn.withValues(alpha: 0.22 * (1 - progress)),
    );
    canvas.drawCircle(
        c, 16, Paint()..color = AppColors.earn.withValues(alpha: 0.16));
    canvas.drawCircle(
      c,
      8,
      Paint()
        ..color = AppColors.earn
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );
    canvas.drawCircle(c, 4.5, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(_PulsePainter old) => old.progress != progress;
}

/// Rampas de cor do calor: ciano (frio) → verde → amarelo → vermelho (quente).
Color heatColor(double w) {
  final h = (210 - 210 * w.clamp(0, 1)).toDouble();
  return HSVColor.fromAHSV(1, h, 0.85, 1).toColor();
}
