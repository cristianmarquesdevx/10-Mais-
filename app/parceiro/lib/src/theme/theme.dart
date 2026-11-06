import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Tokens, tipografia e componentes agora vêm do design system compartilhado
// (packages/ten_design). Este arquivo mantém só o que é comportamento do app:
// preferência de tema e formatação em BRL. Nada de cor ou estilo aqui.
export 'package:ten_design/ten_design.dart';

// ---------------------------------------------------------------------------
// Preferência de tema (claro / escuro / seguir sistema), persistida localmente.
// ---------------------------------------------------------------------------
enum ThemeModePref { light, dark, system }

/// Conversão para o `themeMode` do MaterialApp. Ficava em `main.dart`, onde
/// era fácil (e aconteceu) fixar `ThemeMode.light` e desligar o modo escuro.
extension ThemeModePrefX on ThemeModePref {
  ThemeMode get materialMode => switch (this) {
        ThemeModePref.light => ThemeMode.light,
        ThemeModePref.dark => ThemeMode.dark,
        ThemeModePref.system => ThemeMode.system,
      };
}

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
final ValueNotifier<ThemeModePref> themeModeNotifier =
    ValueNotifier<ThemeModePref>(ThemeModePref.light);

/// Formata BRL com 2 casas e separador de milhar no padrão pt-BR
/// ("R$ 1.234,56"). Sem ICU: o formato é fixo e não muda com o locale do
/// aparelho — o valor no cartão de saldo precisa ser sempre legível.
String brl(num v) {
  final neg = v < 0;
  final cents = (v.abs() * 100).round();
  final reais = cents ~/ 100;
  final centavos = cents % 100;
  final miles = reais ~/ 1000;
  final resto = (reais % 1000).toString().padLeft(3, '0');
  final inteiro = miles > 0 ? '$miles.$resto' : reais.toString();
  return '${neg ? '-' : ''}R\$ $inteiro,${centavos.toString().padLeft(2, '0')}';
}
