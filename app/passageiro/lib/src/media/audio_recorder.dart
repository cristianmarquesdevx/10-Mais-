import 'dart:typed_data';

import 'audio_recorder_stub.dart'
    if (dart.library.js_interop) 'audio_recorder_web.dart' as impl;

/// Captura de áudio da corrida (segurança). A implementação real usa
/// MediaRecorder/getUserMedia no web; outras plataformas ficam indisponíveis
/// até o módulo de mídia nativa entrar (ponto de troca isolado aqui).
abstract class AudioRecorder {
  /// Implementação da plataforma (web: MediaRecorder; demais: indisponível).
  static AudioRecorder platform() => impl.createAudioRecorder();

  bool get supported;

  /// Pede permissão e inicia a gravação. Lança [StateError] se já gravando.
  Future<void> start();

  /// Para e devolve os bytes (ou null se nada foi capturado).
  Future<AudioCapture?> stop();

  /// Descarta a gravação em curso (não envia nada).
  void cancel();
}

class AudioCapture {
  const AudioCapture(
      {required this.bytes, required this.duration, required this.mime});

  final Uint8List bytes;
  final Duration duration;
  final String mime;
}
