import 'package:flutter/material.dart';
import 'package:ten_design/ten_design.dart';

import '../api/console_api.dart';
import '../sla.dart';
import '../state/console_controller.dart';
import '../widgets/decision_sheet.dart';

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
        SnackBar(content: Text(_successMessage(request.decision))),
      );
    } on ApiProblem catch (p) {
      if (!mounted) return;
      setState(() => _error = p.code);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_problemMessage(p))),
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
          ? const Center(child: CircularProgressIndicator())
          : _error != null && _detail == null
              ? EmptyState(
                  icon: Icons.error_outline,
                  title: 'Não foi possível abrir o caso',
                  message: 'O servidor respondeu com o código "$_error".',
                  action: OutlinedButton.icon(
                    onPressed: _load,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Tentar de novo'),
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
    return ListView(
      padding: const EdgeInsets.all(AppSpace.l),
      children: [
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
              Wrap(
                spacing: AppSpace.s,
                runSpacing: AppSpace.xs,
                children: [
                  _Meta(
                    icon: Icons.timeline_outlined,
                    text: d.position == null
                        ? 'fora da fila'
                        : 'posição ${d.position}',
                  ),
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
                child: AppCard(
                  child: Row(
                    children: [
                      Icon(Icons.description_outlined, color: t.primaryInk),
                      const SizedBox(width: AppSpace.m),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(_docLabel(doc.docType),
                                style: AppType.body.copyWith(color: t.ink)),
                            const SizedBox(height: AppSpace.xs),
                            Text(
                              'Enviado em ${_hhmm(doc.createdAt)}',
                              style: AppType.caption.copyWith(color: t.muted),
                            ),
                          ],
                        ),
                      ),
                      // O registro honesto: documento SEM arquivo é
                      // pendente, e a operação precisa ver isso antes de
                      // aprovar.
                      StatusChip(
                        label: doc.uploadPending
                            ? 'ARQUIVO PENDENTE'
                            : 'ARQUIVO OK',
                        tone: doc.uploadPending
                            ? StatusTone.warning
                            : StatusTone.success,
                        icon: doc.uploadPending
                            ? Icons.schedule_outlined
                            : Icons.check_circle_outline,
                      ),
                    ],
                  ),
                ),
              )),
        const SizedBox(height: AppSpace.xl),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpace.m),
            child: Text('Erro: $_error',
                style: AppType.label.copyWith(color: t.danger)),
          ),
        _decisionButtons(t),
      ],
    );
  }

  Widget _decisionButtons(ColorSchemeColorTokens t) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FilledButton.icon(
            key: const ValueKey('approve'),
            onPressed: _deciding ? null : _approve,
            icon: const Icon(Icons.check_circle_outline),
            label: const Text('APROVAR CADASTRO'),
          ),
          const SizedBox(height: AppSpace.s),
          OutlinedButton.icon(
            key: const ValueKey('reject'),
            onPressed: _deciding ? null : _reject,
            icon: const Icon(Icons.cancel_outlined),
            label: const Text('RECUSAR'),
          ),
          const SizedBox(height: AppSpace.s),
          OutlinedButton.icon(
            key: const ValueKey('resubmit'),
            onPressed: _deciding ? null : _requestResubmit,
            icon: const Icon(Icons.replay_outlined),
            label: const Text('PEDIR NOVO ENVIO'),
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

  static StatusTone _statusTone(String status) => switch (status) {
        'APPROVED' || 'AUTO_APPROVED' => StatusTone.success,
        'REJECTED' => StatusTone.danger,
        'RESUBMIT' => StatusTone.warning,
        _ => StatusTone.brand,
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
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 15, color: c),
        const SizedBox(width: AppSpace.xs),
        Text(text, style: AppType.label.copyWith(color: c)),
      ],
    );
  }
}
