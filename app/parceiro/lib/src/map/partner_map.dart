import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../api/client.dart';
import '../widgets/heatmap_map.dart';
import 'map_capabilities.dart';
import 'map_layers.dart';
import 'map_provider.dart';
import 'map_styles.dart';

/// Mapa do motorista — **ponto de troca único** do backend de mapa.
///
/// A tela nunca escolhe entre MapLibre e raster: ela pede um [MapProvider]
/// e este widget decide o que dá para desenhar **naquele** device:
///
/// - **vetorial** (MapLibre, Android/iOS): style JSON "Console Noturno" da
///   marca, com as camadas Radar (demanda + marcador) — é o mapa do piloto;
/// - **raster** (flutter_map + tiles do OSM): fallback. Entra em cena no
///   teste de widget (host Windows), em plataforma sem plugin e quando o
///   estilo vetorial falha.
///
/// Em ambos os backends o app mostra **a mesma informação**: as mesmas zonas
/// de demanda, com a **mesma rampa de cor**, e o marcador com a **mesma
/// cor de status**. O que muda é só como o desenho é feito.
class PartnerMap extends StatelessWidget {
  const PartnerMap({
    super.key,
    required this.zones,
    this.provider = MapProviders.openFreeMap,
    this.center = const GeoPoint(-8.7607, -63.9039), // Porto Velho
    this.online = true,
    this.showAttribution = true,
    this.headingDeg = 0,
  });

  /// Zonas de demanda (calor).
  final List<HeatZone> zones;

  /// Provedor de tiles/estilo. Trocar de provedor não toca na UI.
  final MapProvider provider;

  /// Posição do motorista (centro da câmera).
  final GeoPoint center;

  /// Motorista online: marcador teal; offline: cinza.
  final bool online;

  /// O painel desenha o mapa atrás dos botões e repete a atribuição no
  /// rodapé: ali o crédito embutido no mapa ficaria coberto.
  final bool showAttribution;

  /// Direção do movimento do motorista (graus, 0 = norte).
  final double headingDeg;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final vector = provider.isVector && supportsVectorMap;

    return Stack(
      fit: StackFit.expand,
      children: [
        if (vector)
          _VectorPartnerMap(
            zones: zones,
            center: center,
            online: online,
            headingDeg: headingDeg,
            dark: dark,
          )
        else
          HeatmapMap(
            zones: zones,
            center: center,
            online: online,
            showAttribution: showAttribution,
          ),
      ],
    );
  }
}

/// Mapa vetorial (MapLibre) — style JSON da marca + camadas Radar.
///
/// O estilo é **estático** (base do mapa); a camada de demanda e o marcador
/// são fontes GeoJSON vazias no estilo que o app preenche em runtime com
/// `setGeoJsonSource`. Assim o estilo não precisa ser reconstruído a cada
/// atualização de 25 s — só o dado muda.
class _VectorPartnerMap extends StatefulWidget {
  const _VectorPartnerMap({
    required this.zones,
    required this.center,
    required this.online,
    required this.headingDeg,
    required this.dark,
  });

  final List<HeatZone> zones;
  final GeoPoint center;
  final bool online;
  final double headingDeg;
  final bool dark;

  @override
  State<_VectorPartnerMap> createState() => _VectorPartnerMapState();
}

class _VectorPartnerMapState extends State<_VectorPartnerMap> {
  MapLibreMapController? _controller;

  /// O estilo já carregou? Sem isso, `setGeoJsonSource` estoura
  /// `STYLE_NOT_READY` — e dado nenhum é perdido: o `onStyleLoaded` reenvia.
  bool _styleReady = false;

  @override
  void didUpdateWidget(_VectorPartnerMap old) {
    super.didUpdateWidget(old);

    if (old.dark != widget.dark) {
      // Troca de tema = troca de paleta: o estilo é recarregado e o dado
      // das fontes Radar é reenviado no `onStyleLoaded`.
      _styleReady = false;
      _controller?.setStyle(_styleJson());
    }

    if (!identical(old.zones, widget.zones)) {
      _pushDemand();
    }
    if (old.online != widget.online ||
        old.headingDeg != widget.headingDeg ||
        old.center != widget.center) {
      _pushDriver();
    }
  }

  String _styleJson() => MapStyles.consoleNoturnoStyleJson(dark: widget.dark);

  Future<void> _onStyleLoaded() async {
    _styleReady = true;
    await _pushDemand();
    await _pushDriver();
  }

  Future<void> _pushDemand() async {
    final c = _controller;
    if (c == null || !_styleReady) return;
    try {
      await c.setGeoJsonSource(
        MapLayers.demandSourceId,
        MapLayers.demandGeoJson(widget.zones),
      );
    } catch (_) {
      // Estilo recarregando: o `onStyleLoaded` reenvia o dado.
    }
  }

  Future<void> _pushDriver() async {
    final c = _controller;
    if (c == null || !_styleReady) return;
    try {
      await c.setGeoJsonSource(
        MapLayers.driverSourceId,
        MapLayers.driverGeoJson(
          lat: widget.center.lat,
          lon: widget.center.lon,
          headingDeg: widget.headingDeg,
          online: widget.online,
        ),
      );
    } catch (_) {
      // Idem: o `onStyleLoaded` reenvia o dado.
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        MapLibreMap(
          styleString: _styleJson(),
          initialCameraPosition: CameraPosition(
            target: LatLng(widget.center.lat, widget.center.lon),
            zoom: MapStyles.initialZoom,
          ),
          onMapCreated: (c) => _controller = c,
          onStyleLoadedCallback: _onStyleLoaded,
          // A atribuição é repetida no rodapé do painel; aqui ficaria coberta
          // pelo dock flutuante.
          attributionEnabled: false,
          logoEnabled: false,
          compassEnabled: false,
          minMaxZoomPreference: const MinMaxZoomPreference(3, 18),
        ),
        // O marcador é desenhado pelo MapLibre (não é um widget), então o
        // leitor de tela recebe a posição por um nó sobreposto no centro —
        // que é onde a câmera aponta para o motorista.
        Positioned.fill(
          child: IgnorePointer(
            child: Center(
              child: Semantics(
                label: widget.online
                    ? 'Sua posição: motorista online'
                    : 'Sua posição: motorista offline',
                child: const SizedBox(width: 48, height: 48),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
