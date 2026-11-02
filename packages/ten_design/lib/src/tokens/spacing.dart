import 'package:flutter/material.dart';

import 'colors.dart';

/// Grade de 4 dp, raios e alvo mínimo de toque (48 dp, Material e HIG).
abstract final class AppSpace {
  static const xs = 4.0, s = 8.0, m = 12.0, l = 16.0, xl = 24.0, xxl = 32.0;
  static const radiusCard = 12.0, radiusSheet = 18.0, radiusChip = 999.0;
  static const radiusPill = 999.0;

  /// Alvo mínimo de toque. Nada clicável pode ser menor que isto.
  static const target = 48.0;
}

/// Sombras por tema. Não use `Colors.black` direto: a sombra acompanha o ink.
List<BoxShadow> get appShadow => [
      BoxShadow(
        color: AppColors.ink.withValues(alpha: 0.06),
        blurRadius: 16,
        offset: const Offset(0, 4),
      ),
    ];

List<BoxShadow> appShadowDark() => [
      BoxShadow(
        color: AppColorsDark.ink.withValues(alpha: 0.15),
        blurRadius: 16,
        offset: const Offset(0, 4),
      ),
    ];
