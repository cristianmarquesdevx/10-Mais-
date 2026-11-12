import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../media/document_quality.dart';
import '../media/still_capture.dart';
import '../theme/theme.dart';

/// Como a foto tirada é MEDIDA e MOSTRADA.
///
/// A implementação de produção ([PhotoPipeline.real]) decodifica os bytes,
/// mede a nitidez e o reflexo e mostra a prévia.
///
/// O seam existe porque a DECODIFICAÇÃO de imagem não completa no ambiente
/// de teste do Flutter (ela fica pendurada esperando o event loop real):
/// o teste do fluxo injeta uma implementação de mentira, e a implementação
/// real tem o seu próprio teste (test/document_quality_test.dart). A tela
/// continua orquestrando o mesmo passo nos dois casos.
class PhotoPipeline {
  const PhotoPipeline({required this.measure, required this.preview});

  /// A medida da qualidade da foto (null = desconhecida).
  final Future<DocumentQuality?> Function(Uint8List bytes) measure;

  /// A prévia da foto na tela.
  final Widget Function(BuildContext context, Uint8List bytes) preview;

  /// A implementação de produção.
  static PhotoPipeline real() => PhotoPipeline(
        measure: DocumentQuality.measure,
        preview: (context, bytes) {
          final t = tokensOf(context);
          return Image.memory(
            bytes,
            fit: BoxFit.contain,
            errorBuilder: (_, __, ___) => Container(
              color: t.graphiteDeep,
              alignment: Alignment.center,
              child: Icon(Icons.broken_image_outlined,
                  color: t.onGraphiteMuted, size: 48),
            ),
          );
        },
      );
}

/// Uma foto capturada e medida.
class CapturedDocument {
  const CapturedDocument({required this.bytes, required this.quality});

  /// O arquivo que sobe para o Storage.
  final Uint8List bytes;

  /// A medida da qualidade. `null` = DESCONHECIDA (a imagem não pôde ser
  /// decodificada): a tela diz que não sabe, em vez de fingir que está boa.
  final DocumentQuality? quality;
}

/// A captura guiada do documento (F9).
///
/// O passo é: abrir a câmera → tirar a foto → a app mede a nitidez e o
/// reflexo → a pessoa refaz se a foto ficou ruim (ou segue, se o aviso não
///IMPORTAR). A foto NUNCA é inventada: sem câmera, a tela diz que a
/// captura não está disponível.
class DocumentCaptureScreen extends StatefulWidget {
  const DocumentCaptureScreen({
    super.key,
    required this.docType,
    required this.title,
    this.hint,
    this.capture,
    this.pipeline,
  });

  /// O tipo do documento (CNH, SELFIE, …) — vai no nome do arquivo.
  final String docType;

  final String title;

  /// A dica mostrada acima do preview.
  final String? hint;

  /// A captura a usar. Nulo = a nativa da plataforma ([StillCapture.platform]).
  ///
  /// Existe para o TESTE: o fluxo inteiro (capturar → medir → enviar) é
  /// exercitado com uma câmera de mentira, e a captura nativa é o que roda
  /// no aparelho. Nenhuma tela inventa bytes.
  final StillCapture? capture;

  /// Como a foto é medida e mostrada. Nulo = a implementação de produção
  /// ([PhotoPipeline.real]).
  final PhotoPipeline? pipeline;

  @override
  State<DocumentCaptureScreen> createState() => _DocumentCaptureScreenState();
}

class _DocumentCaptureScreenState extends State<DocumentCaptureScreen> {
  StillCapture? _capture;
  bool _opening = true;
  bool _busy = false;
  String? _error;

  CapturedDocument? _shot;

  @override
  void initState() {
    super.initState();
    _open();
  }

  @override
  void dispose() {
    _capture?.close();
    super.dispose();
  }

  Future<void> _open() async {
    final capture = widget.capture ?? StillCapture.platform();
    try {
      await capture.open();
      if (!mounted) {
        capture.close();
        return;
      }
      setState(() {
        _capture = capture;
        _opening = false;
        _error = null;
      });
    } on StillCaptureException catch (e) {
      capture.close();
      if (!mounted) return;
      setState(() {
        _opening = false;
        _error = e.message;
      });
    } catch (e) {
      capture.close();
      if (!mounted) return;
      setState(() {
        _opening = false;
        _error = 'Não foi possível abrir a câmera.';
      });
    }
  }

  Future<void> _take() async {
    final capture = _capture;
    if (capture == null) return;
    setState(() => _busy = true);
    try {
      final shot = await capture.capture();
      if (shot == null) {
        if (mounted) setState(() => _error = 'A câmera não devolveu a foto.');
        return;
      }

      // A medida e a prévia vêm do pipeline (o de produção, no aparelho).
      final pipeline = widget.pipeline ?? PhotoPipeline.real();
      final quality = await pipeline.measure(shot.bytes);
      if (!mounted) return;
      setState(() {
        _shot = CapturedDocument(bytes: shot.bytes, quality: quality);
        _error = null;
      });
    } on StillCaptureException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Não foi possível tirar a foto.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _refazer() {
    setState(() {
      _shot = null;
      _error = null;
    });
    _capture?.open();
  }

  void _usar() {
    final shot = _shot;
    if (shot == null) return;
    Navigator.of(context).pop(shot);
  }

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        leading: IconButton(
          tooltip: 'Fechar',
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.close),
        ),
      ),
      body: _opening
          ? const Center(child: CircularProgressIndicator())
          : _capture == null
              ? _CameraUnavailable(message: _error ?? 'Câmera indisponível.')
              : _shot != null
                  ? _revisao(t)
                  : _preview(t),
    );
  }

  Widget _preview(ColorSchemeColorTokens t) => Column(
        children: [
          if (widget.hint != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppSpace.l, AppSpace.m, AppSpace.l, AppSpace.s),
              child: Text(
                widget.hint!,
                textAlign: TextAlign.center,
                style: AppType.label.copyWith(color: t.muted),
              ),
            ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(AppSpace.l),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(AppSpace.radiusSheet),
                child: _capture?.preview() ??
                    Container(
                      color: t.graphiteDeep,
                      alignment: Alignment.center,
                      child: Icon(Icons.photo_camera_outlined,
                          color: t.onGraphiteMuted, size: 48),
                    ),
              ),
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpace.l),
              child: Text(_error!,
                  textAlign: TextAlign.center,
                  style: AppType.label.copyWith(color: t.danger)),
            ),
          Padding(
            padding: const EdgeInsets.all(AppSpace.l),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : () => _capture?.switchLens(),
                    icon: const Icon(Icons.cameraswitch_outlined),
                    label: const Text('Virar'),
                  ),
                ),
                const SizedBox(width: AppSpace.m),
                Expanded(
                  flex: 2,
                  child: FilledButton.icon(
                    key: const ValueKey('capture-take'),
                    onPressed: _busy ? null : _take,
                    icon: _busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.camera_alt_outlined),
                    label: const Text('TIRAR FOTO'),
                  ),
                ),
              ],
            ),
          ),
        ],
      );

  /// A foto tirada: a app mostra a MEDIDA e a pessoa decide.
  Widget _revisao(ColorSchemeColorTokens t) {
    final q = _shot!.quality;
    final ruim = q != null && !q.isAcceptable;
    final avisos = <String>[
      if (q?.isBlurry ?? false) 'A foto está borrada — refaça para o texto ler.',
      if (q?.hasGlare ?? false) 'Tem reflexo na foto — apague o flash.',
      if (q == null) 'A qualidade da foto não pôde ser medida.',
    ];
    return Column(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(AppSpace.l),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppSpace.radiusSheet),
              child: (widget.pipeline ?? PhotoPipeline.real())
                  .preview(context, _shot!.bytes),
            ),
          ),
        ),
        if (avisos.isNotEmpty)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.symmetric(horizontal: AppSpace.l),
            padding: const EdgeInsets.all(AppSpace.m),
            decoration: BoxDecoration(
              color: (ruim ? t.warning : t.muted).withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(AppSpace.radiusCard),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final aviso in avisos)
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpace.xs),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          ruim ? Icons.warning_amber_rounded : Icons.info_outline,
                          size: 18,
                          color: ruim ? t.warning : t.muted,
                        ),
                        const SizedBox(width: AppSpace.s),
                        Expanded(
                          child: Text(aviso,
                              style: AppType.label
                                  .copyWith(color: ruim ? t.warning : t.muted)),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        const SizedBox(height: AppSpace.m),
        Padding(
          padding: const EdgeInsets.all(AppSpace.l),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  key: const ValueKey('capture-refazer'),
                  onPressed: _refazer,
                  icon: const Icon(Icons.refresh),
                  label: const Text('REFAZER'),
                ),
              ),
              const SizedBox(width: AppSpace.m),
              Expanded(
                child: FilledButton.icon(
                  key: const ValueKey('capture-use'),
                  onPressed: _usar,
                  icon: const Icon(Icons.check),
                  label: const Text('USAR ESTA'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// A câmera não está disponível: a tela diz isso (com o motivo) em vez de
/// deixar um retângulo vazio.
class _CameraUnavailable extends StatelessWidget {
  const _CameraUnavailable({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.no_photography_outlined, size: 48, color: t.muted),
            const SizedBox(height: AppSpace.l),
            Text('Câmera indisponível',
                style: AppType.title.copyWith(color: t.ink)),
            const SizedBox(height: AppSpace.s),
            Text(message,
                textAlign: TextAlign.center,
                style: AppType.body.copyWith(color: t.muted)),
          ],
        ),
      ),
    );
  }
}
