import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parceiro/src/media/document_quality.dart';

/// A heurística de qualidade da foto do documento (F9).
///
/// Os limiares são CONTRATO (espelham `scripts/contract.py`, conferido por
/// `scripts/test_contract.py`). O que este teste prova é que a medida
/// DISCRIMINA: uma foto nítida passa, uma foto borrada é marcada, e uma
/// foto estourada pelo flash é marcada.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Desenha com o [Canvas] do Flutter e devolve os bytes PNG.
  Future<Uint8List> imagem(
    int w,
    int h,
    void Function(Canvas, Size) desenhar,
  ) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    desenhar(canvas, Size(w.toDouble(), h.toDouble()));
    final picture = recorder.endRecording();
    final img = await picture.toImage(w, h);
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    img.dispose();
    picture.dispose();
    return data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }

  /// Foto NÍTIDA: papel de verdade (238 — o branco de um papel fotografado
  /// com luz normal, longe do clipping) com texto preto e denso. As bordas
  /// fortes em todas as direções são o que um documento tem.
  Future<Uint8List> nitida() => imagem(160, 160, (canvas, size) {
        canvas.drawRect(
          Offset.zero & size,
          Paint()..color = const Color(0xFFEEEEEE),
        );
        final preto = Paint()..color = const Color(0xFF101010);
        for (var y = 8; y < 152; y += 12) {
          for (var x = 8; x < 152; x += 10) {
            canvas.drawRect(
              Rect.fromLTWH(x.toDouble(), y.toDouble(), 6, 4),
              preto,
            );
          }
        }
      });

  /// Foto BORRADA: um gradiente liso. Sem borda, sem detalhe — o Laplaciano
  /// não acha nada e a variância cai.
  Future<Uint8List> borrada() => imagem(160, 160, (canvas, size) {
        for (var y = 0; y < 160; y++) {
          final v = (100 + (y * 40 / 160)).round();
          canvas.drawRect(
            Rect.fromLTWH(0, y.toDouble(), 160, 1),
            Paint()..color = Color.fromARGB(255, v, v, v),
          );
        }
      });

  /// Foto com REFLEXO: o papel estourado pelo flash (branco puro, clipped no
  /// topo da escala, na maior parte do quadro).
  Future<Uint8List> estourada() => imagem(160, 160, (canvas, size) {
        canvas.drawRect(
            Offset.zero & size, Paint()..color = const Color(0xFFFFFFFF));
        final preto = Paint()..color = const Color(0xFF000000);
        // Só uma faixa de texto no meio: o resto do papel está estourado.
        for (var y = 70; y < 90; y += 4) {
          canvas.drawRect(Rect.fromLTWH(20, y.toDouble(), 120, 2), preto);
        }
      });

  group('medida', () {
    test('foto nítida não é marcada como borrada', () async {
      final q = await DocumentQuality.measure(await nitida());

      expect(q, isNotNull);
      expect(q!.blurScore, greaterThan(kycBlurThreshold));
      expect(q.isBlurry, isFalse);
    });

    test('foto borrada é marcada', () async {
      final q = await DocumentQuality.measure(await borrada());

      expect(q, isNotNull);
      expect(q!.blurScore, lessThan(kycBlurThreshold));
      expect(q.isBlurry, isTrue);
      expect(q.isAcceptable, isFalse);
    });

    test('foto estourada pelo flash é marcada', () async {
      final q = await DocumentQuality.measure(await estourada());

      expect(q, isNotNull);
      expect(q!.glareRatio, greaterThan(kycGlareRatioThreshold));
      expect(q.hasGlare, isTrue);
      expect(q.isAcceptable, isFalse);
    });

    test('foto nítida e sem flash é aceitável', () async {
      final q = await DocumentQuality.measure(await nitida());

      expect(q!.isAcceptable, isTrue);
      expect(q.hasGlare, isFalse);
    });

    test('imagem que não decodifica vira qualidade DESCONHECIDA', () async {
      // Bytes que não são imagem: a medida é desconhecida — a tela diz que
      // não sabe, em vez de fingir que a foto está boa.
      final q = await DocumentQuality.measure(Uint8List.fromList([1, 2, 3]));

      expect(q, isNull);
    });

    test('bytes vazios não quebram', () async {
      expect(await DocumentQuality.measure(Uint8List(0)), isNull);
    });
  });

  group('flags para o servidor', () {
    test('as flags carregam a MEDIDA, não a opinião', () async {
      final q = await DocumentQuality.measure(await nitida());
      final flags = q!.toFlags();

      expect(flags['blur'], isFalse);
      expect(flags['glare'], isFalse);
      expect(flags['blur_score'], isA<int>());
      expect(flags['glare_ratio'], isA<double>());
    });

    test('foto ruim marca a flag correspondente', () async {
      final q = await DocumentQuality.measure(await borrada());
      final flags = q!.toFlags();

      expect(flags['blur'], isTrue);
      expect(flags['glare'], isFalse);
    });
  });
}
