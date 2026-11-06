import 'package:flutter/material.dart';

import '../assets/app_assets.dart';
import '../theme/theme.dart';
import 'package:ten_design/ten_design.dart';
import 'widgets/carousel_destaques.dart';

/// P1 Apresentação + login (OTP F1): tela de abertura elegante do kit —
/// fundo da marca, logo e proposta de valor; em seguida telefone → código
/// de 4 dígitos. No tema claro o fundo é claro (halo verde sobre o
/// background do tema); no escuro continua o mapa noturno do kit.
/// O token real entra no fluxo de auth; aqui a navegação é o contrato
/// (onDone).
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.onDone});

  /// Chamado após o OTP ser aceito (dev: qualquer 4 dígitos).
  final VoidCallback onDone;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _phone = TextEditingController();
  final _otp = TextEditingController();
  int _step = 0; // 0 = telefone, 2 = OTP
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _phone.dispose();
    _otp.dispose();
    super.dispose();
  }

  String get _phoneDigits => _phone.text.replaceAll(RegExp(r'\D'), '');

  /// Some com o erro assim que o usuário corrige o campo.
  void _clearError() {
    if (_error == null) return;
    setState(() => _error = null);
  }

  void _submitPhone() {
    if (_phoneDigits.length < 10) {
      setState(() => _error = 'Informe um celular com DDD.');
      return;
    }
    setState(() {
      _error = null;
      _step = 1;
    });
  }

  Future<void> _submitOtp() async {
    if (_otp.text.length < 4) {
      setState(() => _error = 'Digite o código de 4 dígitos.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    // OTP F1: validação real vem do backend; dev segue adiante.
    await Future<void>.delayed(const Duration(milliseconds: 600));
    if (!mounted) return;
    setState(() => _busy = false);
    widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    // IMPORTANTE: ler o inset AQUI, fora do Scaffold. Com
    // `resizeToAvoidBottomInset: true` o Scaffold consome o inset do body e
    // `viewInsets.bottom` vira 0 lá dentro.
    final keyboard = MediaQuery.viewInsetsOf(context).bottom > 0;

    return Scaffold(
      backgroundColor: t.background,
      resizeToAvoidBottomInset: true,
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: dark
                ? [t.background, t.surface]
                // Fundo do carrossel: mesmo degradê da arte (#E6F5F2 → branco).
                : const [Color(0xFFE6F5F2), Colors.white],
          ),
        ),
        child: Stack(
          children: [
            if (dark)
              Positioned.fill(
                child: Image.asset(
                  AppAssets.mapa,
                  fit: BoxFit.cover,
                  opacity: const AlwaysStoppedAnimation(0.10),
                  errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                ),
              ),
            SafeArea(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final logoWidth = (constraints.maxWidth * 0.55)
                      .clamp(180.0, 320.0)
                      .toDouble();
                  final card = _AuthCard(
                    step: _step,
                    phone: _phone,
                    otp: _otp,
                    busy: _busy,
                    error: _error,
                    onSubmitPhone: _submitPhone,
                    onSubmitOtp: _submitOtp,
                    onChangeStep: (s) => setState(() {
                      _step = s;
                      _error = null;
                    }),
                    onClearError: _clearError,
                  );

                  return Column(
                    children: [
                      // O herói ocupa todo o espaço que sobra acima do cartão.
                      // O cartão mede a si mesmo: nada de altura reservada
                      // chutada (era o que cortava o rodapé).
                      if (!keyboard)
                        Expanded(
                          child: Column(
                            children: [
                              Padding(
                                padding: const EdgeInsets.only(
                                  top: AppSpace.l,
                                  bottom: AppSpace.m,
                                ),
                                child: Image.asset(
                                  dark
                                      ? AppAssets.logoBranco
                                      : AppAssets.logoTransparente,
                                  width: logoWidth,
                                  errorBuilder: (_, __, ___) => Icon(
                                    Icons.verified,
                                    size: logoWidth * 0.18,
                                    color: t.primary,
                                  ),
                                ),
                              ),
                              const Expanded(child: CarouselDestaques()),
                            ],
                          ),
                        ),
                      // Com o teclado aberto o herói sai de cena e o cartão
                      // encosta nele, rolável se o passo for mais alto.
                      if (keyboard)
                        Expanded(
                          child: LayoutBuilder(
                            builder: (context, cardConstraints) {
                              return SingleChildScrollView(
                                physics: const ClampingScrollPhysics(),
                                child: ConstrainedBox(
                                  constraints: BoxConstraints(
                                    minHeight: cardConstraints.maxHeight,
                                  ),
                                  child: Align(
                                    alignment: Alignment.bottomCenter,
                                    child: ConstrainedBox(
                                      constraints:
                                          const BoxConstraints(maxWidth: 420),
                                      child: card,
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        )
                      else
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 420),
                          child: card,
                        ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Card com o formulário da etapa atual.
class _AuthCard extends StatelessWidget {
  const _AuthCard({
    required this.step,
    required this.phone,
    required this.otp,
    required this.busy,
    required this.error,
    required this.onSubmitPhone,
    required this.onSubmitOtp,
    required this.onChangeStep,
    required this.onClearError,
  });

  final int step;
  final TextEditingController phone, otp;
  final bool busy;
  final String? error;
  final VoidCallback onSubmitPhone, onSubmitOtp;
  final ValueChanged<int> onChangeStep;
  final VoidCallback onClearError;

  @override
  Widget build(BuildContext context) {
    // Card do tema: no escuro ele é escuro e o texto claro — com a cor fixa
    // clara, o texto herdava a cor do tema escuro e sumia no branco.
    final t = tokensOf(context);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(horizontal: AppSpace.l),
      padding: const EdgeInsets.fromLTRB(
          AppSpace.xl, AppSpace.xl, AppSpace.xl, AppSpace.l),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: const BorderRadius.vertical(
            top: Radius.circular(AppSpace.radiusSheet)),
        border: Border.all(color: t.hairline.withValues(alpha: 0.35)),
        boxShadow: appShadow,
      ),
      child: step == 0
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Entrar ou criar conta',
                    style: AppType.title.copyWith(color: t.ink)),
                const SizedBox(height: AppSpace.xs),
                Text('Seu celular é a sua conta — sem senha.',
                    style: AppType.label.copyWith(color: t.muted)),
                const SizedBox(height: AppSpace.l),
                TextField(
                  controller: phone,
                  keyboardType: TextInputType.phone,
                  onChanged: (_) => onClearError(),
                  decoration: InputDecoration(
                    labelText: 'Celular',
                    hintText: '(69) 9 9999-9999',
                    prefixIcon: const Icon(Icons.phone_iphone),
                    errorText: error,
                    errorMaxLines: 2,
                  ),
                  onSubmitted: (_) => onSubmitPhone(),
                ),
                const SizedBox(height: AppSpace.l),
                GradientButton(
                    onPressed: onSubmitPhone, child: const Text('CONTINUAR')),
                const SizedBox(height: AppSpace.m),
                Center(
                  child: Text('Ao continuar você aceita os Termos de Uso.',
                      style: AppType.label.copyWith(color: t.muted)),
                ),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(children: [
                  IconButton(
                    onPressed: busy ? null : () => onChangeStep(0),
                    icon: const Icon(Icons.arrow_back),
                  ),
                  const SizedBox(width: AppSpace.xs),
                  Expanded(
                    child: Text('Código de verificação',
                        style: AppType.title.copyWith(color: t.ink)),
                  ),
                ]),
                const SizedBox(height: AppSpace.xs),
                Text(
                    'Enviamos um SMS para ${phone.text.replaceAll(RegExp(r'\D'), '')}',
                    style: AppType.label.copyWith(color: t.muted)),
                const SizedBox(height: AppSpace.l),
                TextField(
                  controller: otp,
                  keyboardType: TextInputType.number,
                  maxLength: 4,
                  autofocus: true,
                  textAlign: TextAlign.center,
                  style: AppType.display.copyWith(letterSpacing: 12),
                  onChanged: (_) => onClearError(),
                  decoration: InputDecoration(
                    counterText: '',
                    hintText: '••••',
                    prefixIcon: const Icon(Icons.sms_outlined),
                    errorText: error,
                    errorMaxLines: 2,
                  ),
                  onSubmitted: (_) => onSubmitOtp(),
                ),
                const SizedBox(height: AppSpace.l),
                GradientButton(
                  onPressed: busy ? null : onSubmitOtp,
                  child: busy
                      ? SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: t.ink))
                      : const Text('ENTRAR'),
                ),
                const SizedBox(height: AppSpace.s),
                Center(
                  child: TextButton(
                    onPressed: busy ? null : () => onChangeStep(0),
                    child: const Text('Trocar de número'),
                  ),
                ),
              ],
            ),
    );
  }
}