import 'dart:typed_data';

import 'video_recorder_stub.dart'
    if (dart.library.js_interop) 'video_recorder_web.dart' as impl;

/// Câmera escolhida pelo parceiro — frontal (selfie) ou traseira (estrada).
enum CameraSide { front, rear }

/// Gravação de vídeo opcional da corrida (segurança). Web: getUserMedia com
/// facingMode + MediaRecorder; demais plataformas ficam indisponíveis até o
/// módulo de mídia nativa (ponto de troca isolado aqui).
abstract class VideoRecorder {
  static VideoRecorder platform() => impl.createVideoRecorder();

  bool get supported;

  /// Id da platform view com o preview ao vivo (null se sem preview).
  String? get previewViewId;

  /// Liga a câmera (preview) sem gravar.
  Future<void> openCamera(CameraSide side);

  /// Inicia a gravação (mantém a câmera atual).
  Future<void> start();

  /// Para e devolve os bytes (ou null se nada foi capturado).
  Future<VideoCapture?> stop();

  /// Troca frontal/traseira durante o preview (e a gravação, se ativa).
  Future<void> switchCamera(CameraSide side);

  /// Fecha câmera e descarta a gravação em curso.
  void close();
}

class VideoCapture {
  const VideoCapture({
    required this.bytes,
    required this.duration,
    required this.mime,
    required this.camera,
  });

  final Uint8List bytes;
  final Duration duration;
  final String mime;
  final CameraSide camera;
}
