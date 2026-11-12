import 'package:flutter/material.dart';

import '../tokens/colors.dart';
import '../tokens/spacing.dart';
import '../tokens/typography.dart';
import 'status_chip.dart';

/// Estado vazio/erro/sem dados: ícone, título, explicação e ação opcional.
///
/// Toda lista ou busca sem resultado usa este widget — nada de tela em branco
/// nem de texto solto no meio do layout.
///
/// O [tone] decide a cor do ícone. O padrão é a marca (`brand`); um estado de
/// ERRO usa `danger` — teal é marca de ação, nunca de erro (a regra de marca
/// do projeto: teal só em CTA primário, link, marcador e ícone de ação).
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.action,
    this.tone = StatusTone.brand,
  });

  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  /// O tom do ícone. `danger` é o estado de erro; `brand`, o de vazio.
  final StatusTone tone;

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    final (fundo, tinta) = switch (tone) {
      StatusTone.brand => (t.primary, t.primaryInk),
      StatusTone.danger => (t.danger, t.danger),
      StatusTone.warning => (t.warning, t.warning),
      StatusTone.success => (t.earn, t.earn),
      StatusTone.neutral => (t.hairline, t.muted),
    };
    return Padding(
      padding: const EdgeInsets.all(AppSpace.xl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: fundo.withValues(alpha: 0.10),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 30, color: tinta),
          ),
          const SizedBox(height: AppSpace.l),
          Text(
            title,
            textAlign: TextAlign.center,
            style: AppType.title.copyWith(color: t.ink),
          ),
          const SizedBox(height: AppSpace.s),
          Text(
            message,
            textAlign: TextAlign.center,
            style: AppType.body.copyWith(color: t.muted),
          ),
          if (action != null) ...[
            const SizedBox(height: AppSpace.l),
            action!,
          ],
        ],
      ),
    );
  }
}
