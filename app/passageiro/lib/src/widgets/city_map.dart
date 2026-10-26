import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../theme/theme.dart';

/// Mapa do passageiro (ponto de troca do MapProvider — R1): tiles reais do
/// OpenStreetMap (tiles padrão, escurecidos no cliente) com nomes reais de
/// ruas/bairros, marcador pulsante do usuário e atribuição OSM no canto.
///
/// Sem "calor de chamadas" — essa camada é exclusiva do parceiro.
class CityMap extends StatefulWidget {
  const CityMap({super.key, this.center = const Offset(0, 0)});

  /// Offset normalizado (-1..1) do marcador relativo ao centro do mapa.
  final Offset center;

  @override
  State<CityMap> createState() => _CityMapState();
}

class _CityMapState extends State<CityMap> with SingleTickerProviderStateMixin {
  /// Porto Velho (praça piloto da demo).
  static const _centro = LatLng(-8.7607, -63.9039);

  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  LatLng get _me => LatLng(
        _centro.latitude + widget.center.dy * 0.008,
        _centro.longitude + widget.center.dx * 0.008,
      );

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: AppColors.graphiteDeep, // base visível mesmo sem rede
      child: FlutterMap(
        options: const MapOptions(
          initialCenter: _centro,
          initialZoom: 14.2,
          interactionOptions: InteractionOptions(
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
          MarkerLayer(markers: [
            Marker(
              point: _me,
              width: 64,
              height: 64,
              child: _PulsingMe(animation: _ctrl, color: AppColors.primary),
            ),
          ]),
          const SimpleAttributionWidget(
            source: Text('© OpenStreetMap contributors'),
            alignment: Alignment.bottomRight,
          ),
        ],
      ),
    );
  }
}

/// Marcador do usuário: anel + pulso (a única animação do mapa).
class _PulsingMe extends StatelessWidget {
  const _PulsingMe({required this.animation, required this.color});

  final Animation<double> animation;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) {
        final t = Curves.easeInOut.transform(animation.value);
        return CustomPaint(painter: _PulsePainter(progress: t, color: color));
      },
    );
  }
}

class _PulsePainter extends CustomPainter {
  _PulsePainter({required this.progress, required this.color});

  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    canvas.drawCircle(
      c,
      18 + 14 * progress,
      Paint()..color = color.withValues(alpha: 0.22 * (1 - progress)),
    );
    canvas.drawCircle(c, 16, Paint()..color = color.withValues(alpha: 0.16));
    canvas.drawCircle(
      c,
      8,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );
    canvas.drawCircle(c, 4.5, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(_PulsePainter old) =>
      old.progress != progress || old.color != color;
}
