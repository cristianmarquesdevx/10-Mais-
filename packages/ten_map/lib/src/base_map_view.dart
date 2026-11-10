import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
// O MapLibre tem o **próprio** `LatLng`/`CameraPosition`: prefixado, para não
// brigar com o `latlong2` (que é o tipo do traçado) nem com o `flutter_map`.
import 'package:maplibre_gl/maplibre_gl.dart' as ml;

import 'map_attribution.dart';
import 'map_capabilities.dart';
import 'map_styles.dart';
import 'map_viewport.dart';

/// Marcador desenhado pelo app **por cima** do mapa.
///
/// O mapa compartilhado não sabe o que é um motorista nem um passageiro: ele
/// só sabe onde um marcador está. O desenho continua em Flutter (mesmo pino,
/// mesma etiqueta de distância nos dois backends) — a coordenada é projetada
/// pelo [MapViewport] que o mapa emite.
@immutable
class MapMarker {
  const MapMarker({
    required this.point,
    required this.width,
    required this.height,
    required this.child,
    this.alignment = Alignment.center,
  });

  /// Posição geográfica do marcador.
  final LatLng point;

  /// Caixa do marcador, em pixels lógicos.
  final double width;
  final double height;

  /// Desenho do marcador.
  final Widget child;

  /// Ancagem do marcador na [point] (`Alignment.center` = centro).
  final Alignment alignment;
}

/// Mapa base compartilhado — a base visual "Console Noturno" da marca.
///
/// A tela nunca escolhe entre MapLibre e raster: ela entrega o centro, o
/// zoom e os marcadores, e este widget decide o que dá para desenhar
/// **naquele** device:
///
/// - **vetorial** (MapLibre, Android/iOS): style JSON "Console Noturno" da
///   marca, com ruas, água e prédios;
/// - **raster** (`flutter_map` + tiles do OSM): fallback — entra em cena no
///   teste de widget (host Windows), em plataforma sem plugin e quando o
///   estilo vetorial falha.
///
/// Os marcadores são **sempre** desenhados em Flutter, por cima do mapa, e
/// posicionados pela projeção do [MapViewport] — o mesmo pino e a mesma
/// etiqueta de distância nos dois backends.
///
/// O [zoom] segue a convenção do OSM (`flutter_map`): mundo de `256·2^zoom`
/// pixels. O MapLibre usa 512 px por tile, então o zoom é convertido na
/// fronteira (`zoom - 1`) para os dois mostrarem **a mesma área**.
class BaseMapView extends StatefulWidget {
  const BaseMapView({
    super.key,
    required this.center,
    this.zoom = 14,
    this.markers = const <MapMarker>[],
    this.onViewport,
    this.showAttribution = true,
    this.userAgentPackageName = 'app.dezemais',
    this.dark,
  });

  /// Centro do mapa (o ponto que fica no meio da tela).
  final LatLng center;

  /// Zoom inicial, na convenção OSM.
  final double zoom;

  /// Marcadores desenhados por cima do mapa.
  final List<MapMarker> markers;

  /// Avisa a cada mudança de câmera (com o tamanho real do mapa).
  final ValueChanged<MapViewport>? onViewport;

  /// Desenha o crédito do OpenStreetMap.
  final bool showAttribution;

  /// User-agent enviado ao OSM no fallback raster (política de tiles).
  final String userAgentPackageName;

  /// Tema do estilo vetorial. `null` = segue o tema do app.
  final bool? dark;

  @override
  State<BaseMapView> createState() => _BaseMapViewState();
}

class _BaseMapViewState extends State<BaseMapView> {
  /// Controller do backend vetorial (MapLibre).
  ml.MapLibreMapController? _libre;

  /// Controller do backend raster (`flutter_map`).
  final MapController _raster = MapController();

  /// Câmera corrente, em semântica OSM.
  late LatLng _camCenter = widget.center;
  late double _camZoom = widget.zoom;

  /// Tamanho real do mapa na tela (o HUD e os marcadores dependem dele).
  Size? _size;

  /// Último tema aplicado ao estilo vetorial.
  bool? _darkApplied;

  @override
  void didUpdateWidget(BaseMapView old) {
    super.didUpdateWidget(old);

    if (widget.center != old.center || widget.zoom != old.zoom) {
      _camCenter = widget.center;
      _camZoom = widget.zoom;
      _moveCamera();
      _publish();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final dark = _darkMode();
    if (_darkApplied == null) {
      _darkApplied = dark;
      return;
    }
    if (_darkApplied != dark) {
      // Troca de tema = troca de paleta: o estilo é recarregado (a câmera e
      // os marcadores continuam onde estavam).
      _darkApplied = dark;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _libre?.setStyle(MapStyles.consoleNoturnoStyleJson(dark: dark));
      });
    }
  }

  /// Tema do estilo: o app pode forçar, senão segue o tema do sistema.
  bool _darkMode() =>
      widget.dark ?? Theme.of(context).brightness == Brightness.dark;

  @override
  void dispose() {
    _raster.dispose();
    super.dispose();
  }

  /// Converte o zoom OSM para o do MapLibre (mundo de 512 px por tile).
  static double _libreZoom(double osmZoom) => osmZoom - 1;

  void _moveCamera() {
    final target = ml.LatLng(widget.center.latitude, widget.center.longitude);
    final libre = _libre;
    if (libre != null) {
      libre.moveCamera(
        ml.CameraUpdate.newLatLngZoom(target, _libreZoom(widget.zoom)),
      );
      return;
    }
    try {
      _raster.move(widget.center, widget.zoom);
    } catch (_) {
      // Mapa raster ainda não montado: a câmera inicial já serve.
    }
  }

  /// Publica o viewport atual e reposiciona os marcadores.
  void _publish() {
    final size = _size;
    if (size == null) return;
    final viewport = MapViewport(
      center: _camCenter,
      zoom: _camZoom,
      size: size,
    );
    _notify(viewport);
    _repaint();
  }

  /// Notifica quem está ouvindo. Durante o build do frame, o `setState` de
  /// quem ouve seria um erro — a notificação espera o frame seguinte.
  void _notify(MapViewport viewport) {
    if (_building) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onViewport?.call(viewport);
      });
      return;
    }
    widget.onViewport?.call(viewport);
  }

  /// Repinta os marcadores na nova escala.
  void _repaint() {
    if (_building) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
      return;
    }
    setState(() {});
  }

  /// O mapa está dentro do build/paint deste frame?
  bool get _building {
    final phase = SchedulerBinding.instance.schedulerPhase;
    return phase == SchedulerPhase.persistentCallbacks ||
        phase == SchedulerPhase.midFrameMicrotasks;
  }

  void _publishLater() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _publish();
    });
  }

  @override
  Widget build(BuildContext context) {
    final dark = _darkMode();

    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        if (_size != size) {
          _size = size;
          // O tamanho mudou (rotação, split): o viewport precisa ser
          // republished para os marcadores e o HUD usarem a escala nova.
          _publishLater();
        }
        final viewport = MapViewport(
          center: _camCenter,
          zoom: _camZoom,
          size: size,
        );
        final vector = supportsVectorMap;
        return Stack(
          fit: StackFit.expand,
          children: [
            vector ? _vectorMap(dark) : _rasterMap(dark),
            // O crédito cita a fonte **real** de cada backend: o vetorial
            // serve tiles do OpenFreeMap, o raster do OSM.
            if (widget.showAttribution)
              MapAttribution(
                label: vector
                    ? '© OpenStreetMap · OpenFreeMap'
                    : '© OpenStreetMap contributors',
              ),
            _markerLayer(viewport),
          ],
        );
      },
    );
  }

  /// Backend vetorial: MapLibre com o style JSON da marca.
  Widget _vectorMap(bool dark) => ml.MapLibreMap(
        styleString: MapStyles.consoleNoturnoStyleJson(dark: dark),
        initialCameraPosition: ml.CameraPosition(
          target: ml.LatLng(widget.center.latitude, widget.center.longitude),
          zoom: _libreZoom(widget.zoom),
        ),
        // Sem isso o mapa não avisa a câmera em movimento — e o HUD do radar
        // perderia o usuário de vista no meio do arrasto.
        trackCameraPosition: true,
        onMapCreated: (controller) {
          _libre = controller;
          // O centro pode ter mudado enquanto o mapa vetorial carregava: a
          // câmera vai para onde a tela pede agora.
          _moveCamera();
          _publish();
        },
        onCameraMove: (position) {
          _camCenter = LatLng(
            position.target.latitude,
            position.target.longitude,
          );
          // MapLibre: mundo de 512 px por tile ≡ OSM `zoom + 1`.
          _camZoom = position.zoom + 1;
          _publish();
        },
        onCameraIdle: () {
          final position = _libre?.cameraPosition;
          if (position == null) return;
          _camCenter = LatLng(
            position.target.latitude,
            position.target.longitude,
          );
          _camZoom = position.zoom + 1;
          _publish();
        },
        attributionEnabled: false,
        logoEnabled: false,
        compassEnabled: false,
        rotateGesturesEnabled: false,
        tiltGesturesEnabled: false,
        minMaxZoomPreference: const ml.MinMaxZoomPreference(3, 18),
      );

  /// Backend raster: `flutter_map` com os tiles do OSM.
  Widget _rasterMap(bool dark) => FlutterMap(
        mapController: _raster,
        options: MapOptions(
          initialCenter: widget.center,
          initialZoom: widget.zoom,
          onMapReady: () {
            final camera = _raster.camera;
            _camCenter = camera.center;
            _camZoom = camera.zoom;
            _moveCamera();
            _publish();
          },
          onPositionChanged: (camera, _) {
            _camCenter = camera.center;
            _camZoom = camera.zoom;
            _publish();
          },
          interactionOptions: const InteractionOptions(
            flags: InteractiveFlag.pinchZoom |
                InteractiveFlag.drag |
                InteractiveFlag.doubleTapZoom,
          ),
        ),
        children: [
          TileLayer(
            urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
            userAgentPackageName: widget.userAgentPackageName,
            tileBuilder: dark ? darkModeTileBuilder : null,
          ),
        ],
      );

  /// Marcadores do app, projetados pela câmera atual.
  Widget _markerLayer(MapViewport viewport) {
    if (widget.markers.isEmpty) return const SizedBox.shrink();
    final children = <Widget>[];
    for (final marker in widget.markers) {
      final p = viewport.project(marker.point);
      // Fora da tela (com folga): não vale a pena montar o widget.
      if (p.dx < -marker.width ||
          p.dy < -marker.height ||
          p.dx > viewport.size.width + marker.width ||
          p.dy > viewport.size.height + marker.height) {
        continue;
      }
      children.add(Positioned(
        left: p.dx - marker.width * (marker.alignment.x + 1) / 2,
        top: p.dy - marker.height * (marker.alignment.y + 1) / 2,
        width: marker.width,
        height: marker.height,
        child: marker.child,
      ));
    }
    return Positioned.fill(
      child: IgnorePointer(
        child: Stack(children: children),
      ),
    );
  }
}
