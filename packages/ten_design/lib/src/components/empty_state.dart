import 'package:flutter/material.dart';

import '../tokens/colors.dart';
import '../tokens/spacing.dart';
import '../tokens/typography.dart';

/// Estado vazio/erro/sem dados: ícone, título, explicação e ação opcional.
///
/// Toda lista ou busca sem resultado usa este widget — nada de tela em branco
/// nem de texto solto no meio do layout.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
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
              color: t.primary.withValues(alpha: 0.10),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 30, color: t.primaryInk),
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
