import 'package:flutter/material.dart';
import 'package:ten_design/ten_design.dart';

import '../api/console_api.dart';
import '../sla.dart';
import '../state/console_controller.dart';
import '../widgets/decision_sheet.dart';
import '../widgets/document_preview.dart';

/// O detalhe do caso: a documentação que a operação precisa olhar e a
/// DECISÃO (aprovar, recusar ou pedir reenvio).
///
/// A decisão é o ato que muda o mundo: `partners.kyc_status` passa a valer
/// para o despacho (só `APPROVED` recebe oferta), o caso sai da fila, o
/// rastro vai para o log de auditoria e o parceiro é notificado.
///
/// A API e o controller chegam pelo CONSTRUTOR (e não por um
/// `InheritedWidget`): a tela carrega o caso já no `initState`, e buscar a
/// dependência herdada ali não é permitido pelo Flutter.
class CaseScreen extends StatefulWidget {
  const CaseScreen({
    super.key,
    required this.caseId,
    required this.api,
    required this.controller,
  });

  final String caseId;
  final ConsoleApi api;
  final ConsoleController controller;

  @override
  State<CaseScreen> createState() => _CaseScreenState();
}

class _CaseScreenState extends State<CaseScreen> {
  CaseDetail? _detail;
  String? _error;
  bool _loading = true;
  bool _deciding = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final d = await widget.api.caseDetail(widget.caseId);
      if (!mounted) return;
      setState(() => _detail = d);
    } on ApiProblem catch (p) {
      if (mounted) setState(() => _error = p.code);
    } catch (_) {
      if (mounted) setState(() => _error = 'offline');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _decide(DecisionRequest request) async {
    setState(() => _deciding = true);
    try {
      await widget.api.review(
        widget.caseId,
        decision: request.decision,
        rejectionCode: request.rejectionCode,
        note: request.note,
      );
      if (!mounted) return;
      // A fila mudou: a tela anterior recarrega ao voltar.
      await widget.controller.load(silent: true);
      if (!mounted) return;
      Navigator.of(context).pop(true);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.check_circle_outline, color: Colors.white),
              const SizedBox(width: AppSpace.s),
              Expanded(child: Text(_successMessage(request.decision))),
            ],
          ),
        ),
      );
    } on ApiProblem catch (p) {
      if (!mounted) return;
      setState(() => _error = p.code);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.error_outline, color: Colors.white),
              const SizedBox(width: AppSpace.s),
              Expanded(child: Text(_problemMessage(p))),
            ],
          ),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = 'offline');
    } finally {
      if (mounted) setState(() => _deciding = false);
    }
  }

  static String _successMessage(String decision) => switch (decision) {
        'APPROVED' => 'Cadastro aprovado. O parceiro já pode ficar online.',
        'REJECTED' => 'Cadastro recusado. O parceiro foi notificado.',
        _ => 'Reenvio pedido. O caso voltou para a fila.',
      };

  String _problemMessage(ApiProblem p) => switch (p.code) {
        'rejection_code_required' => 'Escolha o motivo da recusa.',
        'kyc_case_not_in_queue' => 'Este caso já foi decidido.',
        'forbidden' => 'Você não pode decidir este caso.',
        'offline' => 'Sem conexão com o servidor.',
        _ => p.title,
      };

  Future<void> _approve() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Aprovar cadastro?'),
        content: const Text(
            'O parceiro passa a poder ficar online e receber ofertas. '
            'A decisão fica no log de auditoria.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            key: const ValueKey('approve-confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Aprovar'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await _decide(const DecisionRequest(decision: 'APPROVED'));
    }
  }

  Future<void> _reject() async {
    final req = await showDecisionSheet(
      context,
      decision: 'REJECTED',
      title: 'Recusar cadastro',
      confirmLabel: 'RECUSAR',
    );
    if (req != null) await _decide(req);
  }

  Future<void> _requestResubmit() async {
    final req = await showDecisionSheet(
      context,
      decision: 'RESUBMIT',
      title: 'Pedir novo envio',
      confirmLabel: 'PEDIR REENVIO',
    );
    if (req != null) await _decide(req);
  }

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Caso do KYC')),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppColors.primaryInk),
            )
          : _error != null && _detail == null
              ? EmptyState(
                  icon: Icons.error_outline,
                  tone: StatusTone.danger,
                  title: 'Não foi possível abrir o caso',
                  message: 'O servidor respondeu com o código "$_error".',
                  action: OutlinedButton.icon(
                    onPressed: _load,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Tentar de novo'),
                    style: OutlinedButton.styleFrom(foregroundColor: t.ink),
                  ),
                )
              : _body(t),
    );
  }

  Widget _body(ColorSchemeColorTokens t) {
    final d = _detail;
    if (d == null) return const SizedBox.shrink();
    final now = DateTime.now();
    final overdue = d.sla != null && d.sla!.isBefore(now);
    // O gesto de voltar fica embaixo do conteúdo: sem esta folga, o último
    // botão fica sob a barra do sistema (e o toque cai no gesto).
    final bottomInset = MediaQuery.of(context).padding.bottom;
    return ListView(
      padding: EdgeInsets.fromLTRB(
          AppSpace.l, AppSpace.l, AppSpace.l, AppSpace.xl + bottomInset),
      children: [
        _IdentityCard(detail: d),
        const SizedBox(height: AppSpace.l),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text('Caso do KYC',
                        style: AppType.title.copyWith(color: t.ink)),
                  ),
                  StatusChip(
                    label: _statusLabel(d.status),
                    tone: _statusTone(d.status),
                  ),
                ],
              ),
              const SizedBox(height: AppSpace.s),
              Text(
                'ID ${d.caseId}',
                style: AppType.caption.copyWith(color: t.muted),
              ),
              const SizedBox(height: AppSpace.m),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _Meta(
                    icon: Icons.timeline_outlined,
                    text: d.position == null
                        ? 'fora da fila'
                        : 'posição ${d.position}',
                  ),
                  const SizedBox(height: AppSpace.xs),
                  _Meta(
                    icon: Icons.timer_outlined,
                    text: slaLabel(d.sla, now),
                    color: overdue ? t.danger : t.muted,
                  ),
                ],
              ),
              if (d.rejectionCode != null) ...[
                const SizedBox(height: AppSpace.m),
                Text('Motivo da recusa anterior',
                    style: AppType.label.copyWith(color: t.muted)),
                const SizedBox(height: AppSpace.xs),
                Text(d.rejectionCode!,
                    style: AppType.body.copyWith(color: t.ink)),
              ],
            ],
          ),
        ),
        const SizedBox(height: AppSpace.l),
        const SectionHeader(title: 'Documentação'),
        const SizedBox(height: AppSpace.s),
        if (d.documents.isEmpty)
          AppCard(
            child: Text(
              'Nenhum documento registrado. O parceiro ainda não enviou a '
              'documentação.',
              style: AppType.body.copyWith(color: t.muted),
            ),
          )
        else
          ...d.documents.map((doc) => Padding(
                padding: const EdgeInsets.only(bottom: AppSpace.s),
                child: _DocumentCard(doc: doc, api: widget.api),
              )),
        if (_error != null) ...[
          const SizedBox(height: AppSpace.m),
          _ErrorBanner(code: _error!, onRetry: _load),
        ],
        const SizedBox(height: AppSpace.l),
        _decisionButtons(t),
      ],
    );
  }

  Widget _decisionButtons(ColorSchemeColorTokens t) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // CTA primário: o gradiente da marca (o `FilledButton` do tema é
          // teal chapado).
          GradientButton(
            key: const ValueKey('approve'),
            onPressed: _deciding ? null : _approve,
            // O ícone volta: o CTA primário é a ação mais importante da
            // tela e precisa dizer, no olhar, o que ela faz.
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.check_circle_outline, size: 20),
                SizedBox(width: AppSpace.s),
                Text('APROVAR CADASTRO'),
              ],
            ),
          ),
          const SizedBox(height: AppSpace.s),
          OutlinedButton.icon(
            key: const ValueKey('reject'),
            onPressed: _deciding ? null : _reject,
            icon: const Icon(Icons.cancel_outlined),
            label: const Text('RECUSAR'),
            style: OutlinedButton.styleFrom(foregroundColor: t.ink),
          ),
          const SizedBox(height: AppSpace.s),
          OutlinedButton.icon(
            key: const ValueKey('resubmit'),
            onPressed: _deciding ? null : _requestResubmit,
            icon: const Icon(Icons.replay_outlined),
            label: const Text('PEDIR NOVO ENVIO'),
            style: OutlinedButton.styleFrom(foregroundColor: t.ink),
          ),
        ],
      );

  static String _statusLabel(String status) => switch (status) {
        'IN_REVIEW' => 'EM ANÁLISE',
        'RESUBMIT' => 'REENVIO PENDENTE',
        'APPROVED' => 'APROVADO',
        'REJECTED' => 'RECUSADO',
        'AUTO_APPROVED' => 'APROVADO',
        _ => status,
      };

  /// O tom do status. "EM ANÁLISE" é NEUTRO de propósito: teal é marca de
  /// ação, e o chip marcaria a fila inteira de teal.
  static StatusTone _statusTone(String status) => switch (status) {
        'APPROVED' || 'AUTO_APPROVED' => StatusTone.success,
        'REJECTED' => StatusTone.danger,
        'RESUBMIT' => StatusTone.warning,
        _ => StatusTone.neutral,
      };

  static String _docLabel(String docType) => switch (docType) {
        'CNH' => 'CNH (documento com foto)',
        'CRLV' => 'CRLV',
        'SELFIE' => 'Selfie',
        'PROOF_ADDRESS' => 'Comprovante de endereço',
        'OTHER' => 'Outro documento',
        _ => docType,
      };

  static String _hhmm(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}'
      ' ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}

/// QUEM é o parceiro: nome, telefone e a conta.
///
/// Sem isto a operação via "Parceiro 77777777" — e não consegue nem
/// ligar para quem mandou o documento.
class _IdentityCard extends StatelessWidget {
  const _IdentityCard({required this.detail});

  final CaseDetail detail;

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    final phone = detail.partnerPhone?.trim();
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Parceiro', style: AppType.label.copyWith(color: t.muted)),
          const SizedBox(height: AppSpace.xs),
          Text(
            detail.displayName,
            key: const ValueKey('partner-name'),
            style: AppType.title.copyWith(color: t.ink),
          ),
          const SizedBox(height: AppSpace.s),
          Row(
            children: [
              Icon(Icons.phone_outlined, size: 16, color: t.muted),
              const SizedBox(width: AppSpace.xs),
              Expanded(
                child: Text(
                  (phone == null || phone.isEmpty)
                      ? 'Telefone não informado'
                      : phone,
                  key: const ValueKey('partner-phone'),
                  style: AppType.body.copyWith(
                    color: (phone == null || phone.isEmpty) ? t.muted : t.ink,
                  ),
                ),
              ),
            ],
          ),
          if ((detail.partnerUserId ?? '').isNotEmpty) ...[
            const SizedBox(height: AppSpace.xs),
            Text(
              'Conta ${shortId(detail.partnerUserId!)}',
              style: AppType.caption.copyWith(color: t.muted),
            ),
          ],
        ],
      ),
    );
  }
}

/// Um documento do caso: o tipo, quando chegou, se HÁ arquivo — e o arquivo.
class _DocumentCard extends StatelessWidget {
  const _DocumentCard({required this.doc, required this.api});

  final KycDocument doc;
  final ConsoleApi api;

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    final (label, tone, icon) = doc.uploadPending
        ? ('ARQUIVO PENDENTE', StatusTone.warning, Icons.schedule_outlined)
        : doc.hasFile
            ? ('ARQUIVO OK', StatusTone.success, Icons.check_circle_outline)
            : ('SEM ARQUIVO', StatusTone.danger, Icons.error_outline);
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.description_outlined, color: t.primaryInk),
              const SizedBox(width: AppSpace.m),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_CaseScreenState._docLabel(doc.docType),
                        style: AppType.body.copyWith(color: t.ink)),
                    const SizedBox(height: AppSpace.xs),
                    Text(
                      'Enviado em ${_CaseScreenState._hhmm(doc.createdAt)}',
                      style: AppType.caption.copyWith(color: t.muted),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpace.s),
              StatusChip(label: label, tone: tone, icon: icon),
            ],
          ),
          if (doc.isViewable) ...[
            const SizedBox(height: AppSpace.m),
            DocumentPreview(
              api: api,
              path: doc.storagePath!,
              label: _CaseScreenState._docLabel(doc.docType),
            ),
          ],
        ],
      ),
    );
  }
}

/// O erro que sobrou na tela: com ícone, com o código e com a ação.
class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.code, required this.onRetry});

  final String code;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    return AppCard(
      child: Row(
        children: [
          Icon(Icons.error_outline, color: t.danger),
          const SizedBox(width: AppSpace.m),
          Expanded(
            child: Text(
              'Não foi possível falar com o servidor (código "$code").',
              style: AppType.label.copyWith(color: t.danger),
            ),
          ),
          const SizedBox(width: AppSpace.s),
          IconButton(
            tooltip: 'Tentar de novo',
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
    );
  }
}

/// Uma linha de metadado: ícone + texto. O texto é `Flexible` para quebrar
/// em vez de estourar quando a fonte do sistema está grande.
class _Meta extends StatelessWidget {
  const _Meta({required this.icon, required this.text, this.color});

  final IconData icon;
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    final c = color ?? t.muted;
    return Row(
      children: [
        Icon(icon, size: 15, color: c),
        const SizedBox(width: AppSpace.xs),
        Flexible(
          child: Text(text, style: AppType.label.copyWith(color: c)),
        ),
      ],
    );
  }
}
