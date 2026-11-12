import 'package:flutter/material.dart';

import '../tokens/colors.dart';
import '../tokens/spacing.dart';
import '../tokens/typography.dart';

/// Tom semântico do chip. Não existe chip com cor arbitrária.
enum StatusTone { neutral, brand, success, warning, danger }

/// Pílula de status (modo PASSE/COMISSÃO, pagamento, KYC, oferta).
///
/// O texto usa o tom "forte" (o que passa em AA sobre a superfície); o fundo é
/// o mesmo tom com 14% de opacidade.
class StatusChip extends StatelessWidget {
  const StatusChip({
    super.key,
    required this.label,
    this.tone = StatusTone.neutral,
    this.icon,
  });

  final String label;
  final StatusTone tone;
  final IconData? icon;

  Color _color(ColorSchemeColorTokens t) => switch (tone) {
        StatusTone.neutral => t.muted,
        StatusTone.brand => t.primaryInk,
        StatusTone.success => t.earn,
        StatusTone.warning => t.warning,
        StatusTone.danger => t.danger,
      };

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    final color = _color(t);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpace.m,
        vertical: AppSpace.xs,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AppSpace.radiusChip),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: color),
            const SizedBox(width: AppSpace.xs),
          ],
          // `Flexible`: com fonte grande (acessibilidade) ou numa linha
          // apertada, o rótulo encolhe com reticências em vez de estourar
          // o cartão.
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppType.caption.copyWith(
                color: color,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
