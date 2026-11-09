import 'package:flutter/foundation.dart';

/// Backend de renderização do mapa.
///
/// - [vector]: tiles vetoriais (MapLibre) com style JSON da marca;
/// - [raster]: tiles de imagem (flutter_map), usado como fallback e nas
///   telas que ainda não migraram.
enum MapBackend { vector, raster }

/// Provedor de mapa: **onde** os tiles vêm e **como** são desenhados.
///
/// A tela do mapa nunca fala com o provedor diretamente: ela pede um
/// [MapProvider] e o [PartnerMap] decide o backend. Trocar de tiles (hoje
/// OpenFreeMap; depois Protomaps self-host) é trocar esta classe — sem
/// tocar na UI.
@immutable
class MapProvider {
  const MapProvider({
    required this.id,
    required this.label,
    required this.backend,
    required this.attribution,
    this.styleUrl,
    this.rasterTileUrl,
    this.maxZoom = 14,
    this.minZoom = 0,
    this.offlineCapable = false,
    this.notes = '',
  });

  /// Identificador estável (persistido em preferências, no futuro).
  final String id;

  /// Nome curto para a UI ("OpenFreeMap", "OSM").
  final String label;

  /// Como o mapa é desenhado.
  final MapBackend backend;

  /// Texto de atribuição **obrigatório**: os dados são do OpenStreetMap e
  /// o crédito tem que aparecer (política do OSM).
  final String attribution;

  /// URL do style JSON (backend vetorial).
  final String? styleUrl;

  /// URL do template de tiles raster `{z}/{x}/{y}` (fallback).
  final String? rasterTileUrl;

  final int minZoom;
  final int maxZoom;

  /// O provedor permite cache/offline? A política de tiles do OSMF proíbe
  /// prefetch no servidor público — só provider próprio (PMTiles) autoriza.
  final bool offlineCapable;

  /// Observação interna (custo, licença, plano).
  final String notes;

  bool get isVector => backend == MapBackend.vector;

  @override
  bool operator ==(Object other) =>
      other is MapProvider &&
      other.id == id &&
      other.backend == backend &&
      other.styleUrl == styleUrl &&
      other.rasterTileUrl == rasterTileUrl;

  @override
  int get hashCode => Object.hash(id, backend, styleUrl, rasterTileUrl);

  @override
  String toString() => 'MapProvider($id, ${backend.name})';
}

/// Provedores disponíveis.
abstract final class MapProviders {
  /// **Vetorial** — OpenFreeMap: tiles vetoriais OpenMapTiles, sem chave de
  /// API e sem conta. O estilo é o "Console Noturno" da marca (gerado em
  /// `map_styles.dart`), não o estilo pronto do provedor.
  ///
  /// Plano: migrar para Protomaps self-host (≈ US$ 3–10/mês) quando a
  /// frota crescer; aí a política de cache/offline passa a valer.
  static const openFreeMap = MapProvider(
    id: 'openfreemap',
    label: 'OpenFreeMap',
    backend: MapBackend.vector,
    attribution: '© OpenStreetMap contributors',
    styleUrl: 'https://tiles.openfreemap.org/styles/dark',
    rasterTileUrl: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
    maxZoom: 14,
    offlineCapable: false,
    notes: 'Grátis no piloto; sem chave. Migrar para Protomaps self-host '
        'quando a frota crescer (cache/offline só é legal com provider '
        'próprio).',
  );

  /// **Raster** — tiles padrão do OpenStreetMap. É o fallback: se o MapLibre
  /// não estiver disponível (plataforma sem suporte, erro de estilo), o
  /// app continua mostrando o mapa.
  ///
  /// Atenção: o tile público do OSMF **proíbe** prefetch/cache offline.
  static const osmRaster = MapProvider(
    id: 'osm-raster',
    label: 'OpenStreetMap',
    backend: MapBackend.raster,
    attribution: '© OpenStreetMap contributors',
    rasterTileUrl: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
    maxZoom: 19,
    offlineCapable: false,
    notes: 'Fallback raster. Sem cache offline (política do OSMF).',
  );
}
