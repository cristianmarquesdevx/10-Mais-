import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:ten_map/ten_map.dart';

import '../theme/theme.dart';

/// Mapa do passageiro — **mesma base visual** do mapa do motorista.
///
/// No Android/iOS usa MapLibre com o style JSON "Console Noturno"; no host de
/// teste (Windows) cai no raster do OpenStreetMap. A única diferença para o
/// mapa do motorista é a ausência da camada de calor de chamadas: ela é uma
/// informação operacional exclusiva do parceiro.
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
    final me = _me;

    // O mapa compartilhado escolhe o backend (vetorial no Android/iOS, raster
    // no fallback) e posiciona o marcador pela projeção da câmera — o pulso
    // continua sendo um widget Flutter, igual nos dois backends.
    return BaseMapView(
      center: me,
      zoom: 14.2,
      userAgentPackageName: 'app.dezemais.passageiro',
      markers: [
        MapMarker(
          point: me,
          width: 64,
          height: 64,
          child: _PulsingMe(animation: _ctrl, color: AppColors.primary),
        ),
      ],
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
