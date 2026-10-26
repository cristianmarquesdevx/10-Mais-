import 'dart:math' as math;
// latlong2 exporta um `Path<LatLng>` que sombreia o Path do dart:ui usado
// pelo Canvas — o desenho do feixe precisa do Path de pintura.
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../theme/theme.dart';

/// Varredura do radar desenhada SOBRE o mapa, ancorada na posição real do
/// passageiro (não no centro da tela): se o mapa for arrastado, os anéis
/// acompanham o ponto geográfico.
///
/// O raio é o mesmo do pedido de busca — o anel externo mostra até onde a
/// consulta alcançou, em metros de verdade.
class RadarHud extends StatelessWidget {
  const RadarHud({
    super.key,
    required this.camera,
    required this.center,
    required this.radiusKm,
    required this.progress,
  });

  final MapCamera? camera;
  final LatLng? center;
  final double radiusKm;
  final double progress;

  @override
  Widget build(BuildContext context) {
    if (camera == null || center == null) return const SizedBox.shrink();
    final t = tokensOf(context);
    return IgnorePointer(
      // `willChange`: o desenho muda a cada quadro, então não vale a pena o
      // Flutter tentar guardar o raster do HUD em cache (ele seria refeito do
      // zero no quadro seguinte). Só a camada do radar repinta — o mapa por
      // baixo fica intacto.
      child: RepaintBoundary(
        child: CustomPaint(
          willChange: true,
          painter: _RadarPainter(
            camera: camera!,
            center: center!,
            radiusKm: radiusKm,
            progress: progress,
            base: t.primary,
            dark: Theme.of(context).brightness == Brightness.dark,
          ),
        ),
      ),
    );
  }
}

class _RadarPainter extends CustomPainter {
  _RadarPainter({
    required this.camera,
    required this.center,
    required this.radiusKm,
    required this.progress,
    required this.base,
    required this.dark,
  });

  final MapCamera camera;
  final LatLng center;
  final double radiusKm;
  final double progress;
  final Color base;
  final bool dark;

  /// 1 grau de latitude ≈ 111,32 km — projeção suficiente para o raio local.
  static const _kmPerDegLat = 111.32;

  @override
  void paint(Canvas canvas, Size size) {
    final c = camera.latLngToScreenOffset(center);
    final north = camera.latLngToScreenOffset(
      LatLng(center.latitude + radiusKm / _kmPerDegLat, center.longitude),
    );
    final r = (north - c).distance;
    if (!r.isFinite || r < 12) return;

    canvas.save();
    canvas.clipRect(Offset.zero & size);

    // Disco muito leve: dá leitura do alcance sem esconder as ruas.
    canvas.drawCircle(
      c,
      r,
      Paint()..color = base.withValues(alpha: dark ? 0.10 : 0.05),
    );

    // Anéis (1/3, 2/3 e borda do raio consultado).
    for (final f in const [1 / 3, 2 / 3, 1.0]) {
      canvas.drawCircle(
        c,
        r * f,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = f == 1.0 ? 1.4 : 1.0
          ..color = base.withValues(alpha: f == 1.0 ? 0.55 : 0.28),
      );
    }

    // Feixe girando: três fatias sólidas em vez de um SweepGradient.
    // Criar um shader novo a cada quadro é a operação mais cara deste desenho
    // e, num emulador com renderização por software, era o que derrubava o
    // AVD na tela de busca quando havia motorista no mapa. As fatias dão a
    // mesma leitura de varredura sem alocar shader nenhum.
    final angle = progress * 2 * math.pi;
    const span = 0.85; // abertura do feixe, em radianos (~49°)
    const slices = 3;
    final rect = Rect.fromCircle(center: c, radius: r);
    for (var i = 0; i < slices; i++) {
      final from = i / slices;
      final to = (i + 1) / slices;
      final path = ui.Path()
        ..moveTo(c.dx, c.dy)
        ..arcTo(rect, angle - span * (1 - from), span * (to - from), false)
        ..close();
      // A fatia da frente (a que acabou de varrer) é a mais forte.
      canvas.drawPath(
        path,
        Paint()..color = base.withValues(alpha: (dark ? 0.30 : 0.20) * to),
      );
    }

    final tip = c + Offset(math.cos(angle), math.sin(angle)) * r;
    canvas.drawLine(
      c,
      tip,
      Paint()
        ..color = base.withValues(alpha: dark ? 0.75 : 0.55)
        ..strokeWidth = 1.6
        ..strokeCap = StrokeCap.round,
    );

    // Ponto do passageiro (anel branco) — o pino do mapa fica por cima.
    canvas.drawCircle(
      c,
      7,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = base.withValues(alpha: 0.9),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_RadarPainter old) =>
      old.progress != progress ||
      old.center != center ||
      old.radiusKm != radiusKm ||
      old.base != base ||
      old.camera.zoom != camera.zoom ||
      old.camera.center != camera.center ||
      old.dark != dark;
}
