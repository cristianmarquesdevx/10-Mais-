import 'package:flutter/widgets.dart';

import 'still_capture.dart';

/// Plataforma sem câmera: a captura fica indisponível até o módulo nativo.
///
/// O stub é HONESTO: `supported = false` e a tela avisa que a câmera não
/// existe ali. Devolver uma foto de mentira seria o oposto do registro
/// honesto que o produto faz em todo o resto.
StillCapture createStillCapture() => _StubStillCapture();

class _StubStillCapture implements StillCapture {
  @override
  bool get supported => false;

  @override
  Future<void> open({CameraLens lens = CameraLens.rear}) async =>
      throw StillCaptureException(
        'Câmera indisponível nesta plataforma.',
        code: 'unsupported',
      );

  @override
  Widget? preview() => null;

  @override
  Future<StillShot?> capture() async => null;

  @override
  Future<void> switchLens() async {}

  @override
  void close() {}
}
