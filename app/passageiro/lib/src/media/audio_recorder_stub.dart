import 'audio_recorder.dart';

/// Plataformas sem web: mídia indisponível até o módulo nativo (ponto de
/// troca). O UI mostra o estado "indisponível" sem quebrar.
AudioRecorder createAudioRecorder() => _StubAudioRecorder();

class _StubAudioRecorder implements AudioRecorder {
  @override
  bool get supported => false;

  @override
  Future<void> start() async =>
      throw UnsupportedError('Gravação de áudio indisponível nesta plataforma');

  @override
  Future<AudioCapture?> stop() async => null;

  @override
  void cancel() {}
}
