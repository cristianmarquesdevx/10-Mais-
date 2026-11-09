import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:maplibre_gl/maplibre_gl.dart' as ml;
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
    final dark = Theme.of(context).brightness == Brightness.dark;
    final me = _me;

    if (supportsVectorMap) {
      return _VectorCityMap(center: me, dark: dark, animation: _ctrl);
    }

    return ColoredBox(
      color: dark ? AppColors.graphiteDeep : AppColors.background,
      child: FlutterMap(
        options: MapOptions(
          initialCenter: me,
          initialZoom: 14.2,
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
            tileBuilder: dark ? darkModeTileBuilder : null,
          ),
          MarkerLayer(markers: [
            Marker(
              point: me,
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

/// Mapa vetorial do passageiro: mesma base do motorista, sem camada de calor.
class _VectorCityMap extends StatefulWidget {
  const _VectorCityMap({
    required this.center,
    required this.dark,
    required this.animation,
  });

  final LatLng center;
  final bool dark;
  final Animation<double> animation;

  @override
  State<_VectorCityMap> createState() => _VectorCityMapState();
}

class _VectorCityMapState extends State<_VectorCityMap> {
  ml.MapLibreMapController? _controller;

  /// Onde o ponto "você" caiu na tela, em px lógicos. `null` até o mapa
  /// informar a câmera (antes disso o centro do widget já é a posição certa).
  Offset? _dot;

  /// Descarta respostas fora de ordem quando a câmera se move rápido.
  int _syncToken = 0;

  @override
  Widget build(BuildContext context) {
    final center = ml.LatLng(
      widget.center.latitude,
      widget.center.longitude,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        // O mapa é arrastável: o marcador não pode ficar preso no centro da
        // tela (o raster desenhava o marcador na coordenada, então o arrasto
        // o levava junto). Aqui a coordenada é projetada depois de cada
        // movimento da câmera.
        final dot = _dot ?? constraints.biggest.center(Offset.zero);
        return Stack(
          fit: StackFit.expand,
          children: [
            ml.MapLibreMap(
              styleString:
                  MapStyles.consoleNoturnoStyleJson(dark: widget.dark),
              initialCameraPosition: ml.CameraPosition(
                target: center,
                zoom: 14.2,
              ),
              compassEnabled: false,
              logoEnabled: false,
              attributionEnabled: false,
              rotateGesturesEnabled: false,
              onMapCreated: (c) {
                _controller = c;
                // Depois do primeiro frame o mapa já tem viewport: só então
                // `toScreenLocation` responde.
                WidgetsBinding.instance
                    .addPostFrameCallback((_) => _syncDot());
              },
              onCameraIdle: _syncDot,
            ),
            // O marcador do passageiro continua em Flutter para manter o pulso
            // (e o mesmo desenho nos dois backends).
            Positioned(
              left: dot.dx - 32,
              top: dot.dy - 32,
              width: 64,
              height: 64,
              child: IgnorePointer(
                child: _PulsingMe(
                  animation: widget.animation,
                  color: AppColors.primary,
                ),
              ),
            ),
            Positioned(
              right: 8,
              bottom: 6,
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
      },
    );
  }

  Future<void> _syncDot() async {
    final c = _controller;
    if (c == null) return;
    final token = ++_syncToken;
    try {
      final p = await c.toScreenLocation(
        ml.LatLng(widget.center.latitude, widget.center.longitude),
      );
      if (!mounted || token != _syncToken) return;
      setState(() => _dot = Offset(p.x.toDouble(), p.y.toDouble()));
    } catch (_) {
      // Estilo/câmera ainda carregando: o próximo `onCameraIdle` corrige.
    }
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
