import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ---------------------------------------------------------------------------
// Preferência de tema (claro / escuro / seguir sistema), persistida localmente.
// ---------------------------------------------------------------------------
enum ThemeModePref { light, dark, system }

class ThemePrefs {
  static const _key = 'theme_mode';

  static Future<ThemeModePref> getMode() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString(_key);
    switch (value) {
      case 'dark':
        return ThemeModePref.dark;
      case 'system':
        return ThemeModePref.system;
      default:
        return ThemeModePref.light;
    }
  }

  static Future<void> setMode(ThemeModePref mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, mode.name);
  }
}

/// Modo ativo em memória: o seletor (Perfil) escreve e o app escuta.
///
/// Antes o tema era lido só no `initState` do app: escolher "Escuro" mudava a
/// preferência salva, mas a tela continuava clara até reabrir o app.
final ValueNotifier<ThemeModePref> themeModeNotifier =
    ValueNotifier<ThemeModePref>(ThemeModePref.light);

// ---------------------------------------------------------------------------
// Tokens de cor: tema claro (marca "10 é +" em teal #05998C).
// ---------------------------------------------------------------------------
abstract final class AppColors {
  static const primary = Color(0xFF05998C);
  static const primaryDark = Color(0xFF047A70);
  static const primarySoft = Color(0xFF4FC9BC);
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
// Tokens de cor: tema escuro (contraste WCAG AA; mantém o teal de marca).
// ---------------------------------------------------------------------------
abstract final class AppColorsDark {
  static const primary = Color(0xFF05998C);
  static const primaryDark = Color(0xFF047A70);
  static const primarySoft = Color(0xFF4FC9BC);
  static const earn = Color(0xFF4FD6C8);
  static const warning = Color(0xFFB4780E);
  static const danger = Color(0xFFE57373);
  static const ink = Color(0xFFF8FAFC);
  static const muted = Color(0xFF94A3B8);
  static const hairline = Color(0xFF334155);
  static const surface = Color(0xFF0F172A);
  static const background = Color(0xFF020617);
  static const graphite = Color(0xFF1E293B);
  static const graphiteDeep = Color(0xFF0F172A);
  static const onGraphite = Color(0xFFF8FAFC);
  static const onGraphiteMuted = Color(0xFF64748B);
}

/// Retorna os tokens ativos conforme o brilho do tema.
ColorSchemeColorTokens tokensOf(BuildContext context) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  return isDark ? _DarkTokens() : _LightTokens();
}

abstract class ColorSchemeColorTokens {
  Color get primary;
  Color get primaryDark;
  Color get primarySoft;
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
  Color get primaryDark => AppColors.primaryDark;
  @override
  Color get primarySoft => AppColors.primarySoft;
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
  Color get primaryDark => AppColorsDark.primaryDark;
  @override
  Color get primarySoft => AppColorsDark.primarySoft;
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
// Gradientes da marca.
// ---------------------------------------------------------------------------
abstract final class AppGradients {
  static const primary = LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [Color(0xFF05998C), Color(0xFF35C4B6)],
  );
  static const earn = LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [Color(0xFF03655E), Color(0xFF047A70)],
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

// ---------------------------------------------------------------------------
// Tipografia (sem cor fixa — a cor vem do tema via tokensOf).
// ---------------------------------------------------------------------------
abstract final class AppType {
  static const body = TextStyle(fontSize: 16, height: 1.4);
  static const onDark = TextStyle(fontSize: 16, height: 1.4);
  static const titleOnDark =
      TextStyle(fontSize: 25, fontWeight: FontWeight.w700);
  static const label = TextStyle(fontSize: 14, height: 1.3);
  static const title = TextStyle(fontSize: 20, fontWeight: FontWeight.w600);
  static const display = TextStyle(
    fontSize: 31,
    fontWeight: FontWeight.w700,
    fontFeatures: [FontFeature.tabularFigures()],
  );
  static const money = TextStyle(
    fontSize: 25,
    fontWeight: FontWeight.w700,
    fontFeatures: [FontFeature.tabularFigures()],
  );
  static const countdown = TextStyle(
    fontSize: 20,
    fontWeight: FontWeight.w700,
    fontFeatures: [FontFeature.tabularFigures()],
  );
}

TextStyle bodyStyle(BuildContext context) {
  final t = tokensOf(context);
  return AppType.body.copyWith(color: t.ink);
}

TextStyle titleStyle(BuildContext context) {
  final t = tokensOf(context);
  return AppType.title.copyWith(color: t.ink);
}

TextStyle labelStyle(BuildContext context) {
  final t = tokensOf(context);
  return AppType.label.copyWith(color: t.muted);
}

/// Grade 4 dp; raios 8 (card) / 12 (sheet) / 999 (chips).
abstract final class AppSpace {
  static const xs = 4.0, s = 8.0, m = 12.0, l = 16.0, xl = 24.0, xxl = 32.0;
  static const radiusCard = 12.0, radiusSheet = 18.0, radiusChip = 999.0;
  static const radiusPill = 999.0;
  static const target = 48.0;
}

/// Sombras (tema claro, mantido para compatibilidade).
List<BoxShadow> get appShadow => [
      BoxShadow(
        color: AppColors.ink.withValues(alpha: 0.06),
        blurRadius: 16,
        offset: const Offset(0, 4),
      ),
    ];

/// Sombras (tema escuro).
List<BoxShadow> appShadowDark() => [
      BoxShadow(
        color: AppColorsDark.ink.withValues(alpha: 0.15),
        blurRadius: 16,
        offset: const Offset(0, 4),
      ),
    ];

// ---------------------------------------------------------------------------
// ThemeData
// ---------------------------------------------------------------------------
ThemeData buildLightTheme() {
  final base = ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    colorScheme: ColorScheme.fromSeed(
      seedColor: AppColors.primary,
      primary: AppColors.primary,
      error: AppColors.danger,
      surface: AppColors.surface,
      brightness: Brightness.light,
    ),
    scaffoldBackgroundColor: AppColors.background,
    fontFamily: null,
  );
  return base.copyWith(
    textTheme: base.textTheme.apply(
      bodyColor: AppColors.ink,
      displayColor: AppColors.ink,
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppSpace.radiusSheet),
        side: BorderSide(color: AppColors.ink.withValues(alpha: 0.05)),
      ),
      margin: EdgeInsets.zero,
    ),
    pageTransitionsTheme: const PageTransitionsTheme(builders: {
      TargetPlatform.android: ZoomPageTransitionsBuilder(),
      TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
      TargetPlatform.windows: ZoomPageTransitionsBuilder(),
      TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
      TargetPlatform.linux: ZoomPageTransitionsBuilder(),
    }),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(AppSpace.target),
        backgroundColor: AppColors.primary,
        elevation: 0,
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppSpace.radiusPill)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(AppSpace.target),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppSpace.radiusPill)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.surface,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppSpace.radiusCard),
        borderSide: const BorderSide(color: AppColors.hairline),
      ),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}

ThemeData buildDarkTheme() {
  final base = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: ColorScheme.fromSeed(
      seedColor: AppColorsDark.primary,
      primary: AppColorsDark.primary,
      error: AppColorsDark.danger,
      surface: AppColorsDark.surface,
      brightness: Brightness.dark,
    ),
    scaffoldBackgroundColor: AppColorsDark.background,
    fontFamily: null,
  );
  return base.copyWith(
    textTheme: base.textTheme.apply(
      bodyColor: AppColorsDark.ink,
      displayColor: AppColorsDark.ink,
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: AppColorsDark.surface,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppSpace.radiusSheet),
        side: BorderSide(color: AppColorsDark.ink.withValues(alpha: 0.15)),
      ),
      margin: EdgeInsets.zero,
    ),
    pageTransitionsTheme: const PageTransitionsTheme(builders: {
      TargetPlatform.android: ZoomPageTransitionsBuilder(),
      TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
      TargetPlatform.windows: ZoomPageTransitionsBuilder(),
      TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
      TargetPlatform.linux: ZoomPageTransitionsBuilder(),
    }),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(AppSpace.target),
        backgroundColor: AppColorsDark.primary,
        elevation: 0,
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppSpace.radiusPill)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(AppSpace.target),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppSpace.radiusPill)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColorsDark.surface,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppSpace.radiusCard),
        borderSide: const BorderSide(color: AppColorsDark.hairline),
      ),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}

/// Compatibilidade: retorna o tema claro.
ThemeData buildAppTheme() => buildLightTheme();

// ---------------------------------------------------------------------------
// CTA com gradiente da marca + glow.
// ---------------------------------------------------------------------------
class GradientButton extends StatelessWidget {
  const GradientButton({
    super.key,
    required this.onPressed,
    required this.child,
    this.gradient = AppGradients.primary,
    this.foregroundColor = AppColors.ink,
  });

  final VoidCallback? onPressed;
  final Widget child;
  final Gradient gradient;
  final Color foregroundColor;

  @override
  Widget build(BuildContext context) {
    // Texto do CTA segue a cor pedida por quem usa o botão. Antes o tema
    // escuro forçava branco sobre o gradiente claro (contraste ~3:1).
    final fg = foregroundColor;
    final enabled = onPressed != null;
    return Opacity(
      opacity: enabled ? 1 : 0.55,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: gradient,
          borderRadius: BorderRadius.circular(AppSpace.radiusPill),
          boxShadow: enabled
              ? [
                  BoxShadow(
                    color: AppColors.primary.withValues(alpha: 0.45),
                    blurRadius: 18,
                    offset: const Offset(0, 6),
                  ),
                ]
              : null,
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onPressed,
            borderRadius: BorderRadius.circular(AppSpace.radiusPill),
            child: SizedBox(
              height: AppSpace.target,
              child: Center(
                child: DefaultTextStyle(
                  style: TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w600, color: fg),
                  child: child,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Formata BRL com 2 casas (nunca "R$ 10"). Usa vírgula decimal pt-BR.
String brl(num v) => 'R\$ ${v.toStringAsFixed(2).replaceAll('.', ',')}';
