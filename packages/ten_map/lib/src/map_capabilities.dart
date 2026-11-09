import 'map_capabilities_stub.dart'
    if (dart.library.io) 'map_capabilities_io.dart' as impl;

/// A plataforma atual tem backend de mapa **vetorial** (MapLibre nativo)?
///
/// - Android/iOS: sim — o MapLibre desenha no próprio Android/iOS.
/// - Web: não (o app do motorista não tem build web).
/// - **Teste de widget**: não. O host do `flutter test` é o Windows, então
///   `dart:io` responde `isWindows` e o app cai no fallback raster — o teste
///   não tenta falar com o plugin nativo.
///
/// O fallback existe por dois motivos: plataforma sem plugin e **erro de
/// estilo** (tiles fora do ar não podem deixar o motorista sem mapa).
bool get supportsVectorMap => impl.supportsVectorMap;
