import 'package:flutter/material.dart';

import '../../main.dart';
import '../api/client.dart';
import '../media/still_capture.dart';
import '../theme/theme.dart';
import 'document_capture_screen.dart';

/// P1 Onboarding/KYC — o cadastro do parceiro com a CAPTURA GUIADA (F9).
///
/// O que a tela faz, na ordem:
///   1. o parceiro tira a foto de cada documento (câmera nativa, com aviso
///      de borrão/reflexo);
///   2. o app SUBE o arquivo no bucket privado do KYC (o upload vem antes
///      do registro: o servidor valida que o objeto existe);
///   3. o app abre o caso e REGISTRA cada documento com o path do arquivo.
///
/// 5 faixas de decisão: AUTO_APPROVED (automático) · APPROVED (aprovado pela
/// operação) · IN_REVIEW (na fila, com posição e prazo) · RESUBMIT
/// (documentação reenviada, volta para a fila) · REJECTED (recusado — só aí
/// o parceiro pode reenviar o documento).
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key, this.capture, this.pipeline});

  /// A captura a usar na tela de captura. Nulo = a nativa da plataforma.
  ///
  /// Existe para o TESTE do fluxo (capturar → subir → registrar): o
  /// aparelho usa a câmera de verdade.
  final StillCapture? capture;

  /// Como a foto é medida e mostrada. Nulo = a implementação de produção.
  final PhotoPipeline? pipeline;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  bool _submitting = false;
  KycCase? _case;
  String? _error;

  /// O que a tela avisa depois de uma ação (ex.: "sem câmera, o cadastro
  /// entrou sem documento").
  String? _notice;

  /// As fotos capturadas, por tipo de documento.
  final Map<String, CapturedDocument> _captured = {};

  /// Os documentos que o cadastro exige. O tipo é o que o servidor conhece
  /// (`CNH`, `SELFIE`, …) — o mesmo do `kyc_documents.doc_type`.
  static const List<({String type, String title, String hint})> _docs = [
    (
      type: 'CNH',
      title: 'Documento com foto',
      hint: 'CNH ou RG — frente e verso, sem flash'
    ),
    (
      type: 'SELFIE',
      title: 'Selfie',
      hint: 'Sua foto olhando para a câmera, com boa luz'
    ),
  ];

  /// O caso está NA FILA da operação (em análise ou já reenviado)?
  static bool _naFila(String? status) =>
      status == 'IN_REVIEW' || status == 'RESUBMIT';

  /// A câmera está capturando? O botão de envio trava enquanto a foto não
  /// é tirada — não há o que enviar.
  bool get _capturando => _submitting;

  Future<void> _capturar(String type, String title, String hint) async {
    final shot = await Navigator.of(context).push<CapturedDocument>(
      MaterialPageRoute<CapturedDocument>(
        builder: (_) => DocumentCaptureScreen(
          docType: type,
          title: title,
          hint: hint,
          capture: widget.capture,
          pipeline: widget.pipeline,
        ),
      ),
    );
    if (shot == null || !mounted) return;
    setState(() {
      _captured[type] = shot;
      _error = null;
      _notice = null;
    });
  }

  /// Sobe os arquivos capturados e devolve o path de cada um.
  ///
  /// O upload vem ANTES do registro do documento: o servidor confere que o
  /// objeto existe no bucket, e um path sem objeto é recusado.
  ///
  /// Sem backend de Storage configurado, o documento é registrado sem
  /// arquivo (o servidor marca `PENDENTE`) — o registro honesto de sempre.
  Future<({Map<String, String> paths, Map<String, dynamic> flags, List<String> avisos})>
      _subirArquivos(ApiClient api) async {
    final paths = <String, String>{};
    final flags = <String, dynamic>{};
    final avisos = <String>[];

    for (final doc in _docs) {
      final cap = _captured[doc.type];
      if (cap == null) continue;
      try {
        final path = await api.uploadKycDocument(
          docType: doc.type,
          bytes: cap.bytes,
        );
        paths[doc.type] = path;
        flags[doc.type] = cap.quality?.toFlags() ?? const <String, dynamic>{};
      } on ApiProblem catch (p) {
        if (p.code != 'storage_not_configured') rethrow;
        avisos.add(
            '${doc.title}: a foto não pôde ser enviada (${p.code}) — o registro fica pendente.');
      }
    }
    return (paths: paths, flags: flags, avisos: avisos);
  }

  /// Reenvia a documentação de um caso recusado. No backend real o caso
  /// volta para a fila (RESUBMIT, com posição e prazo novos).
  ///
  /// Se o servidor não responder com o caso (modo demonstração), o estado
  /// NÃO é inventado: a faixa continua mostrando a recusa. Mentir sobre a
  /// fila é pior do que uma tela a menos.
  Future<void> _resubmit(KycCase current) async {
    final api = AppScope.apiOf(context);
    final subido = await _subirArquivos(api);

    for (final doc in _docs) {
      final path = subido.paths[doc.type];
      if (path == null) continue; // sem foto: não há o que reenviar
      await api.registerKycDocument(
        current.caseId,
        docType: doc.type,
        storagePath: path,
        qualityFlags: (subido.flags[doc.type] as Map<String, dynamic>?) ??
            const <String, dynamic>{},
      );
    }

    final atualizado = await api.resubmitDocument(current.caseId);
    if (!mounted) return;
    setState(() {
      _case = atualizado ?? current;
      _notice = subido.avisos.isEmpty
          ? null
          : subido.avisos.join(' ');
    });
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Documentação reenviada.')));
  }

  Future<void> _submit() async {
    final atual = _case;
    // Caso RECUSADO: o botão reenvia o documento — não abre um caso novo
    // (o servidor devolveria o mesmo caso).
    if (atual != null && atual.status == 'REJECTED') {
      setState(() {
        _submitting = true;
        _error = null;
      });
      try {
        await _resubmit(atual);
      } on ApiProblem catch (p) {
        if (mounted) setState(() => _error = p.code);
      } catch (_) {
        if (mounted) setState(() => _error = 'offline');
      } finally {
        if (mounted) setState(() => _submitting = false);
      }
      return;
    }

    setState(() {
      _submitting = true;
      _error = null;
      _notice = null;
    });
    try {
      final api = AppScope.apiOf(context);

      // 1) Sobe os arquivos (o id do caso só existe depois do passo 2).
      final subido = await _subirArquivos(api);

      // 2) Abre o caso (na fila da operação, com prazo).
      final c = await api.submitKyc();

      // 3) Registra cada documento com o path do arquivo.
      for (final doc in _docs) {
        final path = subido.paths[doc.type];
        if (path == null) continue;
        await api.registerKycDocument(
          c.caseId,
          docType: doc.type,
          storagePath: path,
          qualityFlags: (subido.flags[doc.type] as Map<String, dynamic>?) ??
              const <String, dynamic>{},
        );
      }

      if (!mounted) return;
      setState(() {
        _case = c;
        _notice = subido.avisos.isEmpty
            ? null
            : subido.avisos.join(' ');
      });
      if (c.status == 'AUTO_APPROVED' && context.mounted) {
        // Aprovação automática (demonstração): o parceiro já pode online, a
        // tela sai. A aprovação MANUAL fica na tela: ela é a informação que
        // o parceiro esperava ver depois de horas na fila.
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Aprovado! Você já pode ficar online.')));
        Navigator.pop(context);
      } else if (c.status == 'APPROVED') {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Aprovado pela operação. Você já pode ficar online.')));
      }
    } on ApiProblem catch (p) {
      if (mounted) setState(() => _error = p.code);
    } catch (_) {
      if (mounted) setState(() => _error = 'offline');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = _case;
    return Scaffold(
      appBar: AppBar(title: const Text('Cadastro de parceiro')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpace.l),
        children: [
          const Text('Documentos', style: AppType.title),
          const SizedBox(height: AppSpace.xs),
          Text(
            'Tire a foto de cada documento. A app avisa se a foto saiu borrada '
            'ou com reflexo — o arquivo vai para a fila da operação.',
            style: AppType.label.copyWith(color: AppColors.muted),
          ),
          const SizedBox(height: AppSpace.s),
          Card(
            child: Column(children: [
              for (var i = 0; i < _docs.length; i++) ...[
                if (i > 0) const Divider(height: 1),
                _DocumentTile(
                  doc: _docs[i],
                  captured: _captured[_docs[i].type],
                  enabled: !_capturando,
                  onCapture: () => _capturar(
                    _docs[i].type,
                    _docs[i].title,
                    _docs[i].hint,
                  ),
                ),
              ],
            ]),
          ),
          const SizedBox(height: AppSpace.l),
          if (c != null) _CaseStatus(kycCase: c),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpace.m),
              child: Text('Erro: $_error',
                  style: const TextStyle(color: AppColors.danger)),
            ),
          if (_notice != null)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpace.m),
              child: Text(_notice!,
                  style: AppType.label.copyWith(color: AppColors.warning)),
            ),
          FilledButton.icon(
            // Com o caso NA FILA (em análise ou reenviado), o botão fica
            // travado: quem manda no ritmo do caso é a operação, não o
            // parceiro. Só a recusa libera um novo envio.
            onPressed: _submitting || _naFila(_case?.status)
                ? null
                : _submit,
            icon: _submitting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.upload_file_outlined),
            label: Text(
              _case?.status == 'REJECTED'
                  ? 'Reenviar documento'
                  : _naFila(_case?.status)
                      ? 'Em análise'
                      : 'Enviar documentação',
            ),
          ),
          const SizedBox(height: AppSpace.m),
          const Text(
            'Enviado? A análise automática leva minutos; na fila manual, '
            'o prazo aparece aqui. Em análise você ainda não pode ficar online.',
            style: AppType.label,
          ),
        ],
      ),
    );
  }
}

/// Um documento da lista: o que falta, o que foi tirado e o botão de
/// capturar.
class _DocumentTile extends StatelessWidget {
  const _DocumentTile({
    required this.doc,
    required this.captured,
    required this.enabled,
    required this.onCapture,
  });

  final ({String type, String title, String hint}) doc;
  final CapturedDocument? captured;
  final bool enabled;
  final VoidCallback onCapture;

  @override
  Widget build(BuildContext context) {
    final cap = captured;
    return ListTile(
      leading: Icon(
        cap == null ? Icons.description_outlined : Icons.check_circle_outline,
        color: cap == null ? AppColors.muted : AppColors.earn,
      ),
      title: Text(doc.title),
      subtitle: Text(
        cap == null
            ? doc.hint
            : _qualidade(cap),
        style: AppType.caption.copyWith(
          color: cap == null
              ? AppColors.muted
              : (cap.quality?.isAcceptable ?? true)
                  ? AppColors.earn
                  : AppColors.warning,
        ),
      ),
      trailing: TextButton(
        key: ValueKey('capture-${doc.type}'),
        onPressed: enabled ? onCapture : null,
        child: Text(cap == null ? 'CAPTURAR' : 'REFAZER'),
      ),
    );
  }

  /// O que a tela mostra depois da foto: a medida, em português.
  static String _qualidade(CapturedDocument cap) {
    final q = cap.quality;
    if (q == null) return 'Foto tirada — qualidade não medida';
    if (q.isBlurry) return 'Foto tirada — saiu borrada';
    if (q.hasGlare) return 'Foto tirada — tem reflexo';
    return 'Foto tirada — nítida';
  }
}

class _CaseStatus extends StatelessWidget {
  const _CaseStatus({required this.kycCase});
  final KycCase kycCase;

  @override
  Widget build(BuildContext context) {
    final (icon, color, text) = switch (kycCase.status) {
      'AUTO_APPROVED' => (
          Icons.check_circle_outline,
          AppColors.earn,
          'Aprovado automaticamente.'
        ),
      'APPROVED' => (
          Icons.verified_outlined,
          AppColors.earn,
          'Aprovado pela operação.'
        ),
      'IN_REVIEW' => (
          Icons.hourglass_top_outlined,
          AppColors.warning,
          'Em análise — posição na fila: ${kycCase.position ?? '—'}'
        ),
      'RESUBMIT' => (
          Icons.hourglass_top_outlined,
          AppColors.warning,
          'Documentação reenviada — posição na fila: ${kycCase.position ?? '—'}'
        ),
      'REJECTED' => (
          Icons.replay_outlined,
          AppColors.danger,
          'Documentação rejeitada — reenvie apenas o documento indicado.'
        ),
      _ => (Icons.help_outline, AppColors.muted, kycCase.status),
    };
    return Card(
      child: ListTile(
        leading: Icon(icon, color: color),
        title: Text(text),
        subtitle: kycCase.sla != null
            ? Text('SLA até ${kycCase.sla!.toLocal()}')
            : null,
      ),
    );
  }
}
