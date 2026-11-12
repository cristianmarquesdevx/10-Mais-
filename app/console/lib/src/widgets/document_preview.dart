import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:ten_design/ten_design.dart';

import '../api/console_api.dart';

/// O documento do parceiro, VISTO pela operação.
///
/// Este é o widget que fecha a lacuna mais grave do console: a pessoa da
/// operação aprova uma CNH — ela precisa VER a CNH. O arquivo vive num
/// bucket PRIVADO; quem autoriza é a RLS do Storage (o dono da pasta ou o
/// papel de operação), e o console baixa com o PRÓPRIO token do agente.
///
/// Três estados, sempre honestos:
///   * carregando — o arquivo vem do servidor;
///   * pronto — a imagem, com a opção de ampliar;
///   * falha — o motivo e o botão de tentar de novo.
///
/// Nenhum estado "finge" o documento: um objeto que não é imagem (ou que o
/// servidor recusou) aparece como FALHA, nunca como uma foto em branco.
class DocumentPreview extends StatefulWidget {
  const DocumentPreview({
    super.key,
    required this.api,
    required this.path,
    required this.label,
  });

  final ConsoleApi api;

  /// O nome do objeto no bucket (o que a API devolveu).
  final String path;

  /// O rótulo do documento (ex.: "CNH (documento com foto)").
  final String label;

  @override
  State<DocumentPreview> createState() => _DocumentPreviewState();
}

class _DocumentPreviewState extends State<DocumentPreview> {
  Uint8List? _bytes;
  bool _loading = true;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant DocumentPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    // O caminho mudou (outro documento): os bytes antigos NÃO são deste
    // arquivo. Sem isto, a tela mostraria a CNH com o rótulo da CRLV.
    if (oldWidget.path != widget.path) {
      _bytes = null;
      _failed = false;
      _loading = true;
      _load();
    }
  }

  Future<void> _load() async {
    final path = widget.path;
    setState(() {
      _loading = true;
      _failed = false;
    });
    final bytes = await widget.api.documentBytes(path);
    if (!mounted) return;
    // O widget pode ter sido trocado (outro path) enquanto o download
    // corria: a resposta velha não pode virar a imagem da tela.
    if (path != widget.path) return;
    if (bytes == null || !looksLikeImage(bytes)) {
      setState(() {
        _bytes = null;
        _failed = true;
        _loading = false;
      });
      return;
    }
    setState(() {
      _bytes = bytes;
      _failed = false;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    final bytes = _bytes;
    return Semantics(
      label: 'Documento: ${widget.label}',
      button: bytes != null,
      child: InkWell(
        key: const ValueKey('document-preview'),
        onTap: bytes == null
            ? null
            : () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    fullscreenDialog: true,
                    builder: (_) => DocumentViewer(
                      bytes: bytes,
                      label: widget.label,
                    ),
                  ),
                ),
        borderRadius: BorderRadius.circular(AppSpace.radiusCard),
        child: Container(
          width: double.infinity,
          // A caixa tem ALTURA MÍNIMA, não fixa: o estado de falha precisa
          // de mais espaço com a fonte do sistema grande (a 2.0 o aviso
          // estourava os 200 px e o layout quebrava).
          constraints: const BoxConstraints(minHeight: 200),
          decoration: BoxDecoration(
            color: t.background,
            borderRadius: BorderRadius.circular(AppSpace.radiusCard),
            border: Border.all(color: t.hairline.withValues(alpha: 0.35)),
          ),
          clipBehavior: Clip.antiAlias,
          child: _loading
              ? SizedBox(height: 200, child: _Loading(t: t))
              : _failed
                  ? _Failed(t: t, onRetry: _load)
                  : SizedBox(
                      height: 200,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          Image.memory(
                            bytes!,
                            fit: BoxFit.cover,
                            // Um JPEG que o aparelho não decodifica não pode
                            // virar tela branca: mostra o aviso.
                            errorBuilder: (_, __, ___) => const _DecodeFailed(),
                          ),
                          const Positioned(
                            left: AppSpace.s,
                            bottom: AppSpace.s,
                            child: _Tag(
                              icon: Icons.zoom_out_map,
                              label: 'Toque para ampliar',
                            ),
                          ),
                        ],
                      ),
                    ),
        ),
      ),
    );
  }
}

/// O arquivo É imagem, mas o aparelho não conseguiu decodificar.
///
/// Este aviso fica DENTRO da caixa de 200 px (é o `errorBuilder` da
/// imagem): por isso ele é compacto e o texto corta — o botão de tentar de
/// novo está no estado de falha do preview, logo abaixo.
class _DecodeFailed extends StatelessWidget {
  const _DecodeFailed();

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.l),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.broken_image_outlined, size: 28, color: t.danger),
            const SizedBox(height: AppSpace.xs),
            Flexible(
              child: Text(
                'Este arquivo não pôde ser aberto.',
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AppType.label.copyWith(color: t.danger),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A tela cheia do documento: a operação precisa ver os detalhes da foto
/// (a validade no canto, a foto legível) antes de decidir.
class DocumentViewer extends StatelessWidget {
  const DocumentViewer({super.key, required this.bytes, required this.label});

  final Uint8List bytes;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(label, style: const TextStyle(fontSize: 16)),
      ),
      body: Center(
        child: InteractiveViewer(
          maxScale: 6,
          child: Image.memory(
            bytes,
            fit: BoxFit.contain,
            errorBuilder: (_, __, ___) => const Text(
              'Não foi possível abrir o arquivo.',
              style: TextStyle(color: Colors.white, fontSize: 16),
            ),
          ),
        ),
      ),
    );
  }
}

class _Loading extends StatelessWidget {
  const _Loading({required this.t});

  final ColorSchemeColorTokens t;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // O spinner é teal SOBRE a superfície clara: precisa do tom escuro
          // (`primaryInk`) para ter contraste — teal puro sobre teal é 1:1.
          const SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(
              strokeWidth: 2.4,
              color: AppColors.primaryInk,
            ),
          ),
          const SizedBox(height: AppSpace.s),
          Text(
            'Carregando documento…',
            style: AppType.label.copyWith(color: t.muted),
          ),
        ],
      ),
    );
  }
}

class _Failed extends StatelessWidget {
  const _Failed({required this.t, required this.onRetry});

  final ColorSchemeColorTokens t;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(AppSpace.l),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.broken_image_outlined, size: 32, color: t.danger),
          const SizedBox(height: AppSpace.s),
          Text(
            'Não foi possível carregar o documento.',
            textAlign: TextAlign.center,
            style: AppType.label.copyWith(color: t.danger),
          ),
          const SizedBox(height: AppSpace.s),
          OutlinedButton.icon(
            key: const ValueKey('document-retry'),
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text('Tentar de novo'),
            style: OutlinedButton.styleFrom(foregroundColor: t.ink),
          ),
        ],
      ),
    );
  }
}

/// A etiqueta sobre a imagem ("toque para ampliar").
class _Tag extends StatelessWidget {
  const _Tag({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(AppSpace.radiusPill),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpace.m,
          vertical: AppSpace.xs,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: Colors.white),
            const SizedBox(width: AppSpace.xs),
            Text(
              label,
              style: AppType.caption.copyWith(color: Colors.white),
            ),
          ],
        ),
      ),
    );
  }
}

/// O objeto é uma imagem? O bucket guarda foto do documento; um conteúdo que
/// não é imagem (ou um erro do servidor) precisa aparecer como FALHA — não
/// como uma moldura vazia que a pessoa toma por "documento carregado".
bool looksLikeImage(Uint8List b) {
  if (b.length < 4) return false;
  // JPEG
  if (b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) return true;
  // PNG
  if (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) return true;
  // WEBP (RIFF....WEBP)
  if (b.length >= 12 &&
      b[0] == 0x52 &&
      b[1] == 0x49 &&
      b[2] == 0x46 &&
      b[3] == 0x46 &&
      b[8] == 0x57 &&
      b[9] == 0x45 &&
      b[10] == 0x42 &&
      b[11] == 0x50) {
    return true;
  }
  return false;
}
