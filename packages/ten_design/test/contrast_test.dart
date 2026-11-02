import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ten_design/ten_design.dart';

/// Guarda de contraste do design system (WCAG 2.1 AA).
///
/// Estes testes são o gate: mudar um tom sem medir o par deixa a suíte
/// vermelha. Não ajuste o valor esperado para "fazer passar" — ajuste a cor.
double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = math.max(la, lb);
  final lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  const aaText = 4.5;
  const aaComponent = 3.0;

  group('texto sobre superfícies', () {
    test('claro: ink, muted e ações passam em AA', () {
      expect(_contrast(AppColors.onPrimary, AppColors.primary),
          greaterThanOrEqualTo(aaText));
      expect(_contrast(AppColors.primaryInk, AppColors.surface),
          greaterThanOrEqualTo(aaText));
      expect(_contrast(AppColors.ink, AppColors.surface),
          greaterThanOrEqualTo(aaText));
      expect(_contrast(AppColors.muted, AppColors.surface),
          greaterThanOrEqualTo(aaText));
      expect(_contrast(AppColors.ink, AppColors.background),
          greaterThanOrEqualTo(aaText));
    });

    test('claro: cores semânticas passam em AA', () {
      for (final c in [AppColors.earn, AppColors.warning, AppColors.danger]) {
        expect(_contrast(c, AppColors.surface), greaterThanOrEqualTo(aaText));
      }
    });

    test('escuro: ink, muted e ações passam em AA', () {
      expect(_contrast(AppColorsDark.onPrimary, AppColorsDark.primary),
          greaterThanOrEqualTo(aaText));
      expect(_contrast(AppColorsDark.primaryInk, AppColorsDark.surface),
          greaterThanOrEqualTo(aaText));
      expect(_contrast(AppColorsDark.ink, AppColorsDark.surface),
          greaterThanOrEqualTo(aaText));
      expect(_contrast(AppColorsDark.muted, AppColorsDark.surface),
          greaterThanOrEqualTo(aaText));
      expect(_contrast(AppColorsDark.ink, AppColorsDark.background),
          greaterThanOrEqualTo(aaText));
    });

    test('escuro: cores semânticas passam em AA', () {
      for (final c in [
        AppColorsDark.earn,
        AppColorsDark.warning,
        AppColorsDark.danger,
      ]) {
        expect(_contrast(c, AppColorsDark.surface), greaterThanOrEqualTo(aaText));
      }
    });
  });

  group('gradiente da marca', () {
    test('onPrimary passa em AA nas duas pontas', () {
      // Pontas do AppGradients.primary.
      for (final c in [AppColors.primary, AppColors.primarySoft]) {
        expect(_contrast(AppColors.onPrimary, c),
            greaterThanOrEqualTo(aaText));
      }
    });

    test('branco sobre o teal de marca é proibido para texto', () {
      // Documenta o motivo de `onPrimary` ser ink: se alguém trocar para
      // branco, este teste explica o porquê do vermelho.
      expect(_contrast(Colors.white, AppColors.primary), lessThan(aaText));
      expect(_contrast(Colors.white, AppColors.primarySoft), lessThan(aaText));
    });
  });

  group('componentes e foco', () {
    test('teal de marca serve como gráfico/ícone sobre fundo claro (3:1)', () {
      expect(_contrast(AppColors.primary, AppColors.surface),
          greaterThanOrEqualTo(aaComponent));
    });

    test('FilledButton usa onPrimary sobre primary nos dois temas', () {
      for (final theme in [buildLightTheme(), buildDarkTheme()]) {
        final style = theme.filledButtonTheme.style!;
        final bg = style.backgroundColor!.resolve({});
        final fg = style.foregroundColor!.resolve({});
        expect(bg, theme.colorScheme.primary);
        expect(fg, theme.colorScheme.onPrimary);
        expect(_contrast(fg!, bg!), greaterThanOrEqualTo(aaText));
      }
    });

    test('OutlinedButton usa primaryInk com contraste AA', () {
      for (final theme in [buildLightTheme(), buildDarkTheme()]) {
        final fg = theme.outlinedButtonTheme.style!.foregroundColor!
            .resolve({});
        final bg = theme.colorScheme.surface;
        expect(_contrast(fg!, bg), greaterThanOrEqualTo(aaText));
      }
    });
  });
}
