import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

/// Limiar da heurística de BORRÃO (variância do Laplaciano).
///
/// É uma heurística de CLIENTE, não uma regra do servidor: ela avisa o
/// parceiro que a foto está ruim (e deixa a operação ver a medida), mas quem
/// aprova é a pessoa. O valor é a MESMA constante em `scripts/contract.py`,
/// e `scripts/test_contract.py` confere que os dois continuam iguais.
const double kycBlurThreshold = 120;

/// Limiar da heurística de REFLEXO (fração de pixels estourados).
///
/// Um flash no documento estourou o branco: a região vira uma mancha clara
/// sem detalhe. Acima desta fração do quadro, a foto é marcada.
const double kycGlareRatioThreshold = 0.10;

/// A medida da qualidade de uma foto de documento.
///
/// O que a tela mostra é a CONSEQUÊNCIA (borrão? reflexo?), mas o que vai
/// para o servidor são as MEDIDAS — assim a operação decide olhando o
/// número, não confiando na palavra do app.
class DocumentQuality {
  const DocumentQuality({required this.blurScore, required this.glareRatio});

  /// Variância do Laplaciano: quanto MAIOR, mais nítida. Foto borrada tem
  /// variância baixa (as bordas somem).
  final double blurScore;

  /// Fração (0..1) dos pixels estourados (branco sem detalhe).
  final double glareRatio;

  bool get isBlurry => blurScore < kycBlurThreshold;

  bool get hasGlare => glareRatio > kycGlareRatioThreshold;

  /// A foto está boa para enviar? (aviso, não bloqueio)
  bool get isAcceptable => !isBlurry && !hasGlare;

  /// As flags que vão no `quality_flags` do documento.
  Map<String, dynamic> toFlags() => {
        'blur': isBlurry,
        'glare': hasGlare,
        'blur_score': blurScore.round(),
        'glare_ratio': double.parse(glareRatio.toStringAsFixed(4)),
      };

  /// Mede a foto.
  ///
  /// Devolve `null` quando a imagem não pôde ser decodificada: aí a
  /// qualidade é DESCONHECIDA, e a tela diz isso — em vez de fingir que a
  /// foto está boa.
  static Future<DocumentQuality?> measure(Uint8List bytes) async {
    if (bytes.isEmpty) return null;
    ui.Codec? codec;
    ui.Image? image;
    try {
      codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      image = frame.image;
      return await measureImage(image);
    } catch (_) {
      return null;
    } finally {
      image?.dispose();
      codec?.dispose();
    }
  }

  /// Mede uma imagem JÁ decodificada.
  ///
  /// A captura nativa entrega bytes (e quem decodifica é a tela); o caminho
  /// da imagem pronta existe para quem já tem a imagem na mão — sem
  /// decodificar de novo. A MEDIDA é a mesma nos dois caminhos.
  static Future<DocumentQuality?> measureImage(ui.Image image) async {
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) return null;
    return _fromRgba(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      image.width,
      image.height,
    );
  }

  /// A partir dos pixels RGBA crus.
  static DocumentQuality _fromRgba(Uint8List px, int width, int height) {
    // A análise roda numa grade: o documento é grande e a medida não precisa
    // de cada pixel (a borda da foto é o que diz se está nítido).
    final step = math.max(1, math.min(width, height) ~/ 160);
    final samples = <double>[];
    var saturated = 0;
    var counted = 0;

    for (var y = step; y < height - step; y += step) {
      for (var x = step; x < width - step; x += step) {
        final i = (y * width + x) * 4;
        final r = px[i], g = px[i + 1], b = px[i + 2];

        // Laplaciano de 4 vizinhos no cinza: a borda forte dá valor grande.
        final c = _gray(px, i);
        samples.add((4 * c -
                _gray(px, i - 4) -
                _gray(px, i + 4) -
                _gray(px, i - width * 4) -
                _gray(px, i + width * 4))
            .toDouble());

        if (_isSaturated(r, g, b)) saturated++;
        counted++;
      }
    }

    final glare = counted == 0 ? 0.0 : saturated / counted;
    return DocumentQuality(
      blurScore: _variance(samples),
      glareRatio: glare,
    );
  }

  static int _gray(Uint8List px, int i) {
    final r = px[i], g = px[i + 1], b = px[i + 2];
    // Luminância BT.601 (o mesmo peso do olho para o cinza).
    return ((r * 299 + g * 587 + b * 114) ~/ 1000).clamp(0, 255);
  }

  /// Pixel ESTOURADO: o topo da escala, queimado pelo flash.
  ///
  /// O que separa o reflexo do papel de verdade é o CLIPPING: um papel
  /// fotografado com luz normal fica entre ~220 e ~248; o que o flash estoura
  /// vai a 255 e não tem mais detalhe nenhum para recuperar. Por isso o
  /// detector exige o topo da escala — e não "branco", que seria o papel
  /// inteiro (e marcaria todo documento como reflexo).
  ///
  /// A saturação máxima e a luminância mínima são constantes TÉCNICAS do
  /// detector (não são o limiar de reflexo do contrato — esse é a FRAÇÃO do
  /// quadro estourado, [kycGlareRatioThreshold]).
  static const double _maxSaturatedSaturation = 0.06;
  static const int _blownOutLuma = 252;

  static bool _isSaturated(int r, int g, int b) {
    final max = r > g ? (r > b ? r : b) : (g > b ? g : b);
    final min = r < g ? (r < b ? r : b) : (g < b ? g : b);
    if (max == 0) return false;
    final sat = (max - min) / max;
    final luma = (r * 299 + g * 587 + b * 114) ~/ 1000;
    return luma >= _blownOutLuma && sat < _maxSaturatedSaturation;
  }

  static double _variance(List<double> values) {
    if (values.length < 4) return 0;
    var sum = 0.0;
    for (final v in values) {
      sum += v;
    }
    final mean = sum / values.length;
    var acc = 0.0;
    for (final v in values) {
      final d = v - mean;
      acc += d * d;
    }
    return acc / values.length;
  }
}
