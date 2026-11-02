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

/// Formata BRL com 2 casas (nunca "R$ 10"). Usa vírgula decimal pt-BR.
String brl(num v) => 'R\$ ${v.toStringAsFixed(2).replaceAll('.', ',')}';
