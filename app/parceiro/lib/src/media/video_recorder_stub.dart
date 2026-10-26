import 'video_recorder.dart';

/// Plataformas sem web: mídia indisponível até o módulo nativo.
VideoRecorder createVideoRecorder() => _StubVideoRecorder();

class _StubVideoRecorder implements VideoRecorder {
  @override
  bool get supported => false;

  @override
  String? get previewViewId => null;

  @override
  Future<void> openCamera(CameraSide side) async =>
      throw UnsupportedError('Câmera indisponível nesta plataforma');

  @override
  Future<void> start() async =>
      throw UnsupportedError('Câmera indisponível nesta plataforma');

  @override
  Future<VideoCapture?> stop() async => null;

  @override
  Future<void> switchCamera(CameraSide side) async {}

  @override
  void close() {}
}
