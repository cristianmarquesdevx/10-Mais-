import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import 'still_capture_stub.dart'
    if (dart.library.io) 'still_capture_camera.dart'
    if (dart.library.js_interop) 'still_capture_camera.dart' as impl;

/// Qual câmera está em uso.
enum CameraLens { rear, front }

/// Uma foto capturada (os bytes JPEG).
class StillShot {
  const StillShot({required this.bytes});

  /// O arquivo da foto (é isto que sobe para o Storage).
  final Uint8List bytes;
}

/// Erro de captura — com um código que a tela pode usar para explicar.
class StillCaptureException implements Exception {
  StillCaptureException(this.message, {this.code});

  final String message;
  final String? code;

  @override
  String toString() => 'StillCaptureException($code): $message';
}

/// Captura de FOTO do documento do parceiro (F9).
///
/// Mesma forma do `VideoRecorder`: a interface é a mesma em toda plataforma e
/// a implementação troca no ponto de troca (import condicional). Onde não há
/// câmera, a implementação é um STUB HONESTO — `supported = false` e a tela
/// diz que a captura não está disponível. Ela nunca inventa uma foto.
abstract class StillCapture {
  static StillCapture platform() => impl.createStillCapture();

  /// A câmera está disponível neste aparelho?
  ///
  /// Só é verdade DEPOIS que a câmera abriu com sucesso: permissão negada
  /// e aparelho sem câmera deixam isto falso.
  bool get supported;

  /// Abre a câmera e prepara o preview.
  Future<void> open({CameraLens lens = CameraLens.rear});

  /// O preview ao vivo (null quando a câmera não está aberta).
  Widget? preview();

  /// Captura um frame e devolve os bytes (JPEG).
  Future<StillShot?> capture();

  /// Troca entre a câmera traseira e a frontal.
  Future<void> switchLens();

  /// Fecha a câmera e libera o aparelho.
  void close();
}
