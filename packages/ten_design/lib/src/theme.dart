import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'tokens/colors.dart';
import 'tokens/spacing.dart';

// ---------------------------------------------------------------------------
// ThemeData dos dois apps. Nenhum app declara cor de widget: se uma tela
// precisa de uma cor, ela vem de `tokensOf(context)`.
//
// Contraste dos CTA (verificado em test/contrast_test.dart):
//   FilledButton  → `onPrimary` sobre `primary`      = 4,70:1 (AA)
//   GradientButton→ `onPrimary` sobre o gradiente   = 4,70:1 – 7,70:1 (AA)
//   OutlinedButton→ `primaryInk` sobre `surface`    = 5,14:1 (AA)
// Branco sobre o teal de marca (3,53:1) NÃO é usado em corpo de texto.
// ---------------------------------------------------------------------------

ThemeData buildLightTheme() => _buildTheme(
      brightness: Brightness.light,
      primary: AppColors.primary,
      onPrimary: AppColors.onPrimary,
      primaryInk: AppColors.primaryInk,
      surface: AppColors.surface,
      background: AppColors.background,
      ink: AppColors.ink,
      hairline: AppColors.hairline,
      danger: AppColors.danger,
    );

ThemeData buildDarkTheme() => _buildTheme(
      brightness: Brightness.dark,
      primary: AppColorsDark.primary,
      onPrimary: AppColorsDark.onPrimary,
      primaryInk: AppColorsDark.primaryInk,
      surface: AppColorsDark.surface,
      background: AppColorsDark.background,
      ink: AppColorsDark.ink,
      hairline: AppColorsDark.hairline,
      danger: AppColorsDark.danger,
    );

ThemeData _buildTheme({
  required Brightness brightness,
  required Color primary,
  required Color onPrimary,
  required Color primaryInk,
  required Color surface,
  required Color background,
  required Color ink,
  required Color hairline,
  required Color danger,
}) {
  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: ColorScheme.fromSeed(
      seedColor: primary,
      primary: primary,
      onPrimary: onPrimary,
      error: danger,
      surface: surface,
      brightness: brightness,
    ),
    scaffoldBackgroundColor: background,
    fontFamily: null,
  );

  OutlineInputBorder inputBorder() => OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppSpace.radiusCard),
        borderSide: BorderSide(color: hairline),
      );

  return base.copyWith(
    textTheme: base.textTheme.apply(bodyColor: ink, displayColor: ink),
    appBarTheme: AppBarTheme(
      backgroundColor: surface,
      foregroundColor: ink,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: surface,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppSpace.radiusSheet),
        side: BorderSide(color: ink.withValues(alpha: 0.06)),
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
        backgroundColor: primary,
        foregroundColor: onPrimary,
        disabledBackgroundColor: hairline.withValues(alpha: 0.35),
        disabledForegroundColor: ink.withValues(alpha: 0.5),
        elevation: 0,
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppSpace.radiusPill),
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(AppSpace.target),
        foregroundColor: primaryInk,
        side: BorderSide(color: hairline),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppSpace.radiusPill),
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: primaryInk),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: surface,
      border: inputBorder(),
      enabledBorder: inputBorder(),
      focusedBorder: inputBorder().copyWith(
        borderSide: BorderSide(color: primaryInk, width: 2),
      ),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}

/// Compatibilidade: versão antiga do tema claro.
ThemeData buildAppTheme() => buildLightTheme();
