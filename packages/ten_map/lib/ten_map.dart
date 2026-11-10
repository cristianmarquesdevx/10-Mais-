/// Mapa compartilhado do 10 é +.
///
/// Fonte única da base vetorial "Console Noturno" (MapLibre), do fallback
/// raster e das camadas GeoJSON usadas pelos apps `passageiro` e `parceiro`.
/// O app do motorista acrescenta as camadas Radar (calor + marcador) via
/// `MapStyles.consoleNoturnoStyle(radar: true)`; o do passageiro usa só a
/// base e a rota.
library;

export 'src/base_map_view.dart';
export 'src/map_attribution.dart';
export 'src/map_capabilities.dart';
export 'src/map_layers.dart';
export 'src/map_provider.dart';
export 'src/map_styles.dart';
export 'src/map_viewport.dart';
export 'src/route_map_view.dart';
