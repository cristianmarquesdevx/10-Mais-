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
///
/// A folha é uma SUPERFÍCIE do tema (não um retângulo solto), rola quando o
/// teclado abre e respeita o gesto de baixo.
Future<DecisionRequest?> showDecisionSheet(
  BuildContext context, {
  required String decision,
  required String title,
  required String confirmLabel,
}) {
  final t = tokensOf(context);
  final dark = Theme.of(context).brightness == Brightness.dark;
  return showModalBottomSheet<DecisionRequest>(
    context: context,
    isScrollControlled: true,
    backgroundColor: t.surface,
    barrierColor: Colors.black.withValues(alpha: 0.45),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(AppSpace.radiusSheet),
      ),
    ),
    elevation: 12,
    builder: (_) => _DecisionSheet(
      decision: decision,
      title: title,
      confirmLabel: confirmLabel,
      shadow: dark ? appShadowDark() : appShadow,
    ),
  );
}

class _DecisionSheet extends StatefulWidget {
  const _DecisionSheet({
    required this.decision,
    required this.title,
    required this.confirmLabel,
    required this.shadow,
  });

  final String decision;
  final String title;
  final String confirmLabel;
  final List<BoxShadow> shadow;

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
    return DecoratedBox(
      decoration: BoxDecoration(
        color: t.surface,
        boxShadow: widget.shadow,
      ),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
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
                Row(
                  key: const ValueKey('decision-error'),
                  children: [
                    Icon(Icons.error_outline, size: 16, color: t.danger),
                    const SizedBox(width: AppSpace.xs),
                    Expanded(
                      child: Text(_error!,
                          style: AppType.label.copyWith(color: t.danger)),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: AppSpace.l),
              GradientButton(
                key: const ValueKey('decision-confirm'),
                onPressed: _confirm,
                child: Text(widget.confirmLabel),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
