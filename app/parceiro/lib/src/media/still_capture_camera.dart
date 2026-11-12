import 'package:camera/camera.dart';
import 'package:flutter/widgets.dart';

import 'still_capture.dart';

/// Captura nativa (plugin `camera`): Android, iOS e web.
///
/// Onde o plugin não existe (desktop), a abertura falha e o `supported` fica
/// falso — o aparelho é tratado como "sem câmera", não como quebrado.
StillCapture createStillCapture() => _CameraStillCapture();

class _CameraStillCapture implements StillCapture {
  CameraController? _controller;
  CameraLens _lens = CameraLens.rear;
  bool _available = false;

  @override
  bool get supported => _available;

  @override
  Future<void> open({CameraLens lens = CameraLens.rear}) async {
    _lens = lens;
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        _available = false;
        throw StillCaptureException(
          'Nenhuma câmera encontrada neste aparelho.',
          code: 'no_camera',
        );
      }
      final controller = CameraController(
        _pick(cameras, _lens),
        ResolutionPreset.high,
        enableAudio: false,
      );
      await controller.initialize();
      _controller = controller;
      _available = true;
    } on CameraException catch (e) {
      _available = false;
      throw StillCaptureException(
        _messageFor(e),
        code: e.code,
      );
    } catch (_) {
      // Sem o plugin registrado (desktop) ou com falha do driver: o mesmo
      // tratamento — a câmera não está disponível.
      _available = false;
      throw StillCaptureException(
        'Câmera indisponível neste aparelho.',
        code: 'unavailable',
      );
    }
  }

  @override
  Widget? preview() {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return null;
    return CameraPreview(c);
  }

  @override
  Future<StillShot?> capture() async {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return null;
    final shot = await c.takePicture();
    return StillShot(bytes: await shot.readAsBytes());
  }

  @override
  Future<void> switchLens() async {
    final c = _controller;
    if (c == null) return;
    final cameras = await availableCameras();
    final other = _pick(cameras, _lens == CameraLens.rear
        ? CameraLens.front
        : CameraLens.rear);
    await c.dispose();
    final next = CameraController(
      other,
      ResolutionPreset.high,
      enableAudio: false,
    );
    await next.initialize();
    _controller = next;
    _lens = _lens == CameraLens.rear ? CameraLens.front : CameraLens.rear;
  }

  @override
  void close() {
    final c = _controller;
    _controller = null;
    _available = false;
    c?.dispose();
  }

  /// A câmera que serve para o documento: a TRASEIRA (a frente do papel).
  /// A frontal é para a selfie.
  CameraDescription _pick(List<CameraDescription> cameras, CameraLens lens) {
    final wanted = lens == CameraLens.rear
        ? CameraLensDirection.back
        : CameraLensDirection.front;
    return cameras.firstWhere(
      (c) => c.lensDirection == wanted,
      orElse: () => cameras.first,
    );
  }

  /// A mensagem que a pessoa entende. O código do plugin (`CameraAccessDenied`,
  /// `CameraAccessDeniedWithoutPrompt`, …) vira texto de tela.
  static String _messageFor(CameraException e) => switch (e.code) {
        'CameraAccessDenied' =>
          'Permissão de câmera negada. Autorize nas configurações do aparelho.',
        'CameraAccessDeniedWithoutPrompt' =>
          'Permissão de câmera negada. Autorize nas configurações do aparelho.',
        'CameraAccessRestricted' =>
          'A câmera está bloqueada por uma restrição do aparelho.',
        'AudioAccessDenied' =>
          'A câmera abriu, mas o microfone foi negado (a foto não usa áudio).',
        _ => 'Não foi possível abrir a câmera: ${e.description ?? e.code}.',
      };
}
