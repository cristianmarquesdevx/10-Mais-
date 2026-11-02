import 'package:flutter/material.dart';

// ---------------------------------------------------------------------------
// Tokens de cor — fonte única do teal da marca.
//
// O TEAL É INEGOCIÁVEL: `AppColors.primary` = #05998C é o valor já adotado pelo
// projeto e não deve ser redefinido aqui sem decisão explícita de marca.
//
// Regras de contraste (WCAG 2.1 AA, medidas em test/contrast_test.dart):
//   * #05998C com texto branco = 3,53:1  → NÃO serve para corpo de texto.
//   * #05998C com `onPrimary` (#12211F) = 4,70:1 → serve para corpo de texto.
//   * #047A70 (`primaryInk`) sobre fundo claro = 5,14:1 → texto/ícone teal.
//   * Branco sobre #047A70 = 5,22:1 (usado quando o fundo é o teal escuro).
// ---------------------------------------------------------------------------
abstract final class AppColors {
  /// Cor da marca. Superfícies, gráficos e ênfase visual.
  static const primary = Color(0xFF05998C);

  /// Teal escuro: texto/ícone sobre fundo claro e fundo de CTA com branco.
  static const primaryInk = Color(0xFF047A70);

  /// Estado pressionado/selecionado do teal.
  static const primaryDark = Color(0xFF047A70);

  /// Teal claro para superfícies suaves e o fim do gradiente da marca.
  static const primarySoft = Color(0xFF4FC9BC);

  /// Texto/ícone sobre `primary` (4,70:1). Nunca branco em corpo de texto.
  static const onPrimary = Color(0xFF12211F);

  static const earn = Color(0xFF06796E);
  static const warning = Color(0xFF9E5D00);
  static const danger = Color(0xFFC62828);
  static const ink = Color(0xFF12211F);
  static const muted = Color(0xFF47605C);
  static const hairline = Color(0xFF97ACA8);
  static const surface = Color(0xFFFBFEFD);
  static const background = Color(0xFFF2F8F7);
  static const graphite = Color(0xFF2C4442);
  static const graphiteDeep = Color(0xFF1F302E);
  static const onGraphite = Color(0xFFF5FBFA);
  static const onGraphiteMuted = Color(0xFFB6CBC7);
}

// ---------------------------------------------------------------------------
// Tema escuro — neutros harmonizados com o teal (antes eram cinzas azulados
// do slate, que brigavam com a marca). Contrastes medidos em contraste AA.
// ---------------------------------------------------------------------------
abstract final class AppColorsDark {
  /// A marca continua a mesma no escuro (5,00:1 sobre `surface`).
  static const primary = Color(0xFF05998C);

  /// Sobre fundo escuro o próprio teal de marca já passa em texto (5,00:1).
  static const primaryInk = Color(0xFF05998C);

  static const primaryDark = Color(0xFF047A70);
  static const primarySoft = Color(0xFF4FC9BC);
  static const onPrimary = Color(0xFF12211F);

  static const earn = Color(0xFF4FD6C8);
  static const warning = Color(0xFFFFC46B);
  static const danger = Color(0xFFFF8A80);
  static const ink = Color(0xFFF2FAF8);
  static const muted = Color(0xFF9CB6B2);
  static const hairline = Color(0xFF2A4340);
  static const surface = Color(0xFF0D1B19);
  static const background = Color(0xFF06100F);
  static const graphite = Color(0xFF142624);
  static const graphiteDeep = Color(0xFF0A1614);
  static const onGraphite = Color(0xFFF2FAF8);
  static const onGraphiteMuted = Color(0xFF8FA9A5);
}

/// Retorna os tokens ativos conforme o brilho do tema.
ColorSchemeColorTokens tokensOf(BuildContext context) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  return isDark ? _DarkTokens() : _LightTokens();
}

/// Conjunto de tokens consumido pelas telas. Novos tokens entram aqui e nos
/// dois conjuntos — é o que impede cor "solta" voltar para as telas.
abstract class ColorSchemeColorTokens {
  Color get primary;
  Color get primaryInk;
  Color get primaryDark;
  Color get primarySoft;
  Color get onPrimary;
  Color get earn;
  Color get warning;
  Color get danger;
  Color get ink;
  Color get muted;
  Color get hairline;
  Color get surface;
  Color get background;
  Color get graphite;
  Color get graphiteDeep;
  Color get onGraphite;
  Color get onGraphiteMuted;
}

class _LightTokens implements ColorSchemeColorTokens {
  @override
  Color get primary => AppColors.primary;
  @override
  Color get primaryInk => AppColors.primaryInk;
  @override
  Color get primaryDark => AppColors.primaryDark;
  @override
  Color get primarySoft => AppColors.primarySoft;
  @override
  Color get onPrimary => AppColors.onPrimary;
  @override
  Color get earn => AppColors.earn;
  @override
  Color get warning => AppColors.warning;
  @override
  Color get danger => AppColors.danger;
  @override
  Color get ink => AppColors.ink;
  @override
  Color get muted => AppColors.muted;
  @override
  Color get hairline => AppColors.hairline;
  @override
  Color get surface => AppColors.surface;
  @override
  Color get background => AppColors.background;
  @override
  Color get graphite => AppColors.graphite;
  @override
  Color get graphiteDeep => AppColors.graphiteDeep;
  @override
  Color get onGraphite => AppColors.onGraphite;
  @override
  Color get onGraphiteMuted => AppColors.onGraphiteMuted;
}

class _DarkTokens implements ColorSchemeColorTokens {
  @override
  Color get primary => AppColorsDark.primary;
  @override
  Color get primaryInk => AppColorsDark.primaryInk;
  @override
  Color get primaryDark => AppColorsDark.primaryDark;
  @override
  Color get primarySoft => AppColorsDark.primarySoft;
  @override
  Color get onPrimary => AppColorsDark.onPrimary;
  @override
  Color get earn => AppColorsDark.earn;
  @override
  Color get warning => AppColorsDark.warning;
  @override
  Color get danger => AppColorsDark.danger;
  @override
  Color get ink => AppColorsDark.ink;
  @override
  Color get muted => AppColorsDark.muted;
  @override
  Color get hairline => AppColorsDark.hairline;
  @override
  Color get surface => AppColorsDark.surface;
  @override
  Color get background => AppColorsDark.background;
  @override
  Color get graphite => AppColorsDark.graphite;
  @override
  Color get graphiteDeep => AppColorsDark.graphiteDeep;
  @override
  Color get onGraphite => AppColorsDark.onGraphite;
  @override
  Color get onGraphiteMuted => AppColorsDark.onGraphiteMuted;
}

// ---------------------------------------------------------------------------
// Gradientes da marca. Todos os textos sobre eles usam `onPrimary`
// (ink): 4,70:1 no teal e 7,70:1 no teal claro — branco cairia para 2,16:1.
// ---------------------------------------------------------------------------
abstract final class AppGradients {
  static const primary = LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [AppColors.primary, AppColors.primarySoft],
  );
  static const earn = LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [Color(0xFF03655E), AppColors.primaryInk],
  );
  static const warn = LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [Color(0xFF9E5D00), Color(0xFFB4780E)],
  );
  static const mapNight = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0xFF0B1220), Color(0xFF111C31)],
  );
  static const dark = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0xFF314047), Color(0xFF232C30)],
  );
}
