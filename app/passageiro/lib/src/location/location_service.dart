import 'dart:async';

import 'package:geolocator/geolocator.dart';

/// Uma leitura de GPS já validada. `accuracyM` é a precisão informada pelo
/// aparelho — a UI usa isso para não fingir precisão que não existe.
class LocationFix {
  const LocationFix({
    required this.lat,
    required this.lon,
    required this.accuracyM,
    required this.at,
  });

  final double lat;
  final double lon;
  final double accuracyM;
  final DateTime at;
}

/// Por que não foi possível localizar. A tela decide a mensagem por este
/// enum — nunca por texto de exceção.
enum LocationFailure {
  permissionDenied,
  permissionDeniedForever,
  serviceDisabled,
  timeout,
  unavailable,
}

class LocationException implements Exception {
  const LocationException(this.failure);

  final LocationFailure failure;

  @override
  String toString() => 'LocationException($failure)';
}

/// Captura de posição real. Sem plugin (testes, web sem permissão, emulador
/// sem GPS), os métodos lançam [LocationException] — quem chama decide entre
/// mostrar "indisponível" ou usar um fallback explícito.
class LocationService {
  const LocationService();

  Future<LocationFix> current({
    Duration timeout = const Duration(seconds: 10),
    LocationAccuracy accuracy = LocationAccuracy.high,
  }) async {
    try {
      final enabled = await Geolocator.isLocationServiceEnabled();
      if (!enabled) {
        throw const LocationException(LocationFailure.serviceDisabled);
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied) {
        throw const LocationException(LocationFailure.permissionDenied);
      }
      if (permission == LocationPermission.deniedForever) {
        throw const LocationException(LocationFailure.permissionDeniedForever);
      }

      // O timeout é do próprio plugin (timeLimit): um Timer do Dart aqui
      // sobreviveria à tela e vazaria para testes/segundo plano.
      final p = await Geolocator.getCurrentPosition(
        locationSettings: LocationSettings(
          accuracy: accuracy,
          timeLimit: timeout,
        ),
      );
      return _fromPosition(p);
    } on LocationException {
      rethrow;
    } on TimeoutException {
      throw const LocationException(LocationFailure.timeout);
    } on LocationServiceDisabledException {
      throw const LocationException(LocationFailure.serviceDisabled);
    } catch (_) {
      // MissingPluginException (testes/web sem plugin), PlatformException etc.
      throw const LocationException(LocationFailure.unavailable);
    }
  }

  /// Versão que nunca lança: usada em telas onde a ausência de GPS não pode
  /// derrubar o fluxo (o chamador mostra o estado vazio).
  Future<LocationFix?> tryCurrent({
    Duration timeout = const Duration(seconds: 8),
    LocationAccuracy accuracy = LocationAccuracy.high,
  }) async {
    try {
      return await current(timeout: timeout, accuracy: accuracy);
    } catch (_) {
      return null;
    }
  }

  static LocationFix _fromPosition(Position p) => LocationFix(
        lat: p.latitude,
        lon: p.longitude,
        accuracyM: p.accuracy,
        at: DateTime.now(),
      );

  /// Abre as configurações (permissão negada para sempre / GPS desligado).
  Future<void> openSettings() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        await Geolocator.openLocationSettings();
      } else {
        await Geolocator.openAppSettings();
      }
    } catch (_) {
      // sem UI de settings (testes) — não há o que abrir
    }
  }
}
