import 'package:flutter/material.dart';
import 'package:ten_design/ten_design.dart';

import '../api/console_api.dart';

/// O que a operação pediu na folha de decisão.
class DecisionRequest {
  const DecisionRequest({required this.decision, this.rejectionCode, this.note});

  /// APPROVED · REJECTED · RESUBMIT.
  final String decision;
  final String? rejectionCode;
  final String? note;
}

/// Folha de decisão com o motivo padronizado.
///
/// Recusa e pedido de reenvio EXIGEM o motivo: o servidor recusa a decisão
/// sem ele (422 `rejection_code_required`), porque recusa sem motivo
/// padronizado é recusa sem ação possível para o parceiro — ele não sabe o
/// que corrigir.
Future<DecisionRequest?> showDecisionSheet(
  BuildContext context, {
  required String decision,
  required String title,
  required String confirmLabel,
}) {
  return showModalBottomSheet<DecisionRequest>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _DecisionSheet(
      decision: decision,
      title: title,
      confirmLabel: confirmLabel,
    ),
  );
}

class _DecisionSheet extends StatefulWidget {
  const _DecisionSheet({
    required this.decision,
    required this.title,
    required this.confirmLabel,
  });

  final String decision;
  final String title;
  final String confirmLabel;

  @override
  State<_DecisionSheet> createState() => _DecisionSheetState();
}

class _DecisionSheetState extends State<_DecisionSheet> {
  final _note = TextEditingController();
  String? _code;
  String? _error;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  void _confirm() {
    if (_code == null) {
      setState(() => _error = 'Escolha o motivo.');
      return;
    }
    Navigator.of(context).pop(
      DecisionRequest(
        decision: widget.decision,
        rejectionCode: _code,
        note: _note.text,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    return Padding(
      padding: EdgeInsets.only(
        left: AppSpace.l,
        right: AppSpace.l,
        top: AppSpace.l,
        bottom: MediaQuery.of(context).viewInsets.bottom + AppSpace.l,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: t.hairline,
                borderRadius: BorderRadius.circular(AppSpace.radiusPill),
              ),
            ),
          ),
          const SizedBox(height: AppSpace.l),
          Text(widget.title, style: AppType.title.copyWith(color: t.ink)),
          const SizedBox(height: AppSpace.xs),
          Text(
            'O parceiro recebe o motivo padronizado e uma nota.',
            style: AppType.label.copyWith(color: t.muted),
          ),
          const SizedBox(height: AppSpace.l),
          DropdownButtonFormField<String>(
            key: const ValueKey('decision-reason'),
            initialValue: _code,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Motivo'),
            items: [
              for (final (code, label) in RejectionCodes.all)
                DropdownMenuItem(value: code, child: Text(label)),
            ],
            onChanged: (v) => setState(() {
              _code = v;
              _error = null;
            }),
          ),
          const SizedBox(height: AppSpace.m),
          TextField(
            key: const ValueKey('decision-note'),
            controller: _note,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'Nota (opcional)',
              hintText: 'Ex.: refaça a foto da CNH sem flash.',
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: AppSpace.m),
            Text(_error!,
                key: const ValueKey('decision-error'),
                style: AppType.label.copyWith(color: t.danger)),
          ],
          const SizedBox(height: AppSpace.l),
          FilledButton(
            key: const ValueKey('decision-confirm'),
            onPressed: _confirm,
            child: Text(widget.confirmLabel),
          ),
        ],
      ),
    );
  }
}
