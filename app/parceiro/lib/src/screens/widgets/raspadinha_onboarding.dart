import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../assets/app_assets.dart';
import '../../theme/theme.dart';
import 'carousel_destaques.dart';

/// Onboarding da raspadinha (M5).
///
/// "Abre só na primeira vez por versão de conteúdo": o flag guarda a versão
/// do conteúdo que o usuário já viu. Quando as artes/textos mudarem,
/// incremente [RaspadinhaOnboardingPrefs.versaoAtual] — todo mundo com versão
/// diferente vê o onboarding de novo (uma única vez).
abstract final class RaspadinhaOnboardingPrefs {
  static const chave = 'raspadinha_onboarding_versao';
  static const versaoAtual = 1;

  static Future<bool> precisaMostrar() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(chave) != versaoAtual;
  }

  static Future<void> marcarVisto() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(chave, versaoAtual);
  }
}

/// Tela de apresentação da raspadinha: reutiliza o carrossel do login (M4)
/// com as artes da raspadinha.
///
/// Só apresenta — não toca em mecânica, sorteio, prêmio, backend ou
/// autenticação. Os dois botões fecham a tela; quem abriu decide se grava
/// o flag de "visto".
class RaspadinhaOnboardingScreen extends StatelessWidget {
  const RaspadinhaOnboardingScreen({super.key});

  /// Cor pedida no briefing M5 para "Pular" e "Começar".
  static const acao = Color(0xFF0F8279);

  static Future<void> abrir(BuildContext context) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (_) => const RaspadinhaOnboardingScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    final items = AppAssets.carrosselRaspadinhaSlides
        .map((imagem) => <String, dynamic>{'imagem': imagem})
        .toList(growable: false);

    return Scaffold(
      backgroundColor: t.background,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.l),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Como funciona a raspadinha',
                style: titleStyle(context),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppSpace.m),
              Expanded(
                child: CarouselDestaques(items: items),
              ),
              const SizedBox(height: AppSpace.m),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: acao,
                        side: const BorderSide(color: acao),
                        minimumSize: const Size(0, 48),
                      ),
                      child: const Text('Pular'),
                    ),
                  ),
                  const SizedBox(width: AppSpace.m),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: acao,
                        foregroundColor: Colors.white,
                        minimumSize: const Size(0, 48),
                      ),
                      child: const Text('Começar'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
