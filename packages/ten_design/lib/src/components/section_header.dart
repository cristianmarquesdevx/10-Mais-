import 'package:flutter/material.dart';

import '../tokens/colors.dart';
import '../tokens/spacing.dart';
import '../tokens/typography.dart';

/// Título de seção com ação opcional à direita.
class SectionHeader extends StatelessWidget {
  const SectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.action,
  });

  final String title;
  final String? subtitle;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.s),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: AppType.title.copyWith(color: t.ink)),
                if (subtitle != null) ...[
                  const SizedBox(height: AppSpace.xs),
                  Text(subtitle!, style: labelStyle(context)),
                ],
              ],
            ),
          ),
          if (action != null) action!,
        ],
      ),
    );
  }
}

/// Atalho de estilo de legenda já com a cor do tema aplicada.
abstract final class AppStyleLabel {
  static TextStyle of(BuildContext context) =>
      AppType.label.copyWith(color: tokensOf(context).muted);
}
