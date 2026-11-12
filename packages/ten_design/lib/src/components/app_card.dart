import 'package:flutter/material.dart';

import '../tokens/colors.dart';
import '../tokens/spacing.dart';

/// Cartão padrão: superfície, raio de sheet, borda de 1 px e sombra do tema.
///
/// Substitui os `Container` + `BoxDecoration` copiados em cada tela.
class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(AppSpace.l),
    this.margin,
    this.onTap,
    this.semanticLabel,
    this.borderRadius,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;
  final VoidCallback? onTap;
  final String? semanticLabel;

  /// O raio do cartão. O padrão é o raio de sheet do design system; passa
  /// um valor diferente quando o cartão precisa de outra forma (ex.: um
  /// cartão de imagem, que é retangular).
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final radius = borderRadius ?? BorderRadius.circular(AppSpace.radiusSheet);

    final content = Padding(padding: padding, child: child);

    return Container(
      margin: margin,
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: radius,
        border: Border.all(color: t.hairline.withValues(alpha: 0.35)),
        boxShadow: dark ? appShadowDark() : appShadow,
      ),
      clipBehavior: Clip.antiAlias,
      child: onTap == null
          ? content
          : Semantics(
              button: true,
              label: semanticLabel,
              child: Material(
                type: MaterialType.transparency,
                // O raio acompanha o cartão: sem isto, a onda do toque
                // ("splash") sai quadrada por cima da borda arredondada.
                child: InkWell(
                  onTap: onTap,
                  borderRadius: radius,
                  child: content,
                ),
              ),
            ),
    );
  }
}
