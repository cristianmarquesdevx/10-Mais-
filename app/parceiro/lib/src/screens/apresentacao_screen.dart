import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../assets/app_assets.dart';

/// Tela de apresentação do app do motorista: a arte da marca "10 é +" com o
/// carro e a moto, o slogan e os indicadores. É a primeira tela ao abrir o
/// app; tocar em qualquer ponto (ou esperar) segue para o login.
///
/// A arte fornecida já traz os quatro indicadores e não tem botão próprio —
/// por isso a tela não acrescenta chrome: ela se apresenta e sai da frente.
class ApresentacaoScreen extends StatefulWidget {
  const ApresentacaoScreen({super.key, required this.onDone});

  /// Chamado quando a apresentação termina (toque ou tempo).
  final VoidCallback onDone;

  @override
  State<ApresentacaoScreen> createState() => _ApresentacaoScreenState();
}

class _ApresentacaoScreenState extends State<ApresentacaoScreen> {
  Timer? _timer;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    // Tempo de leitura do slogan; o toque pula na hora.
    _timer = Timer(const Duration(milliseconds: 2600), _finish);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _finish() {
    if (_done) return;
    _done = true;
    _timer?.cancel();
    widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.dark,
        statusBarBrightness: Brightness.light,
        systemNavigationBarColor: Colors.white,
        systemNavigationBarIconBrightness: Brightness.dark,
      ),
      child: Scaffold(
        backgroundColor: Colors.white,
        body: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _finish,
          child: Semantics(
            button: true,
            label: 'Continuar para o login',
            child: SizedBox.expand(
              child: SafeArea(
                child: Image.asset(
                  AppAssets.apresentacao,
                  fit: BoxFit.contain,
                  filterQuality: FilterQuality.high,
                  semanticLabel: '10 é + — Rodar com vantagem',
                  errorBuilder: (_, __, ___) => const Center(
                    child: Icon(Icons.add, color: Colors.white, size: 32),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
