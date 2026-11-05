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
                  // Com o teclado aberto a área útil encolhe; escondemos logo e
                  // carrossel para o cartão e o campo ativo ficarem visíveis.
                  final logoWidth = (constraints.maxWidth * 0.55)
                      .clamp(180.0, 320.0)
                      .toDouble();
                  final carouselHeight = (constraints.maxHeight * 0.42)
                      .clamp(140.0, 360.0)
                      .toDouble();
                  // Reserva mínima para o cartão. O bloco (logo + carrossel)
                  // nunca pode passar disso: é o que impede o RenderFlex de
                  // estourar no frame em que o teclado abre.
                  const cardMinHeight = 240.0;
                  final blockMaxHeight = (constraints.maxHeight - cardMinHeight)
                      .clamp(0.0, double.infinity)
                      .toDouble();

                  return Column(
                    children: [
                      ConstrainedBox(
                        constraints: BoxConstraints(maxHeight: blockMaxHeight),
                        child: AnimatedSize(
                          duration: const Duration(milliseconds: 220),
                          curve: Curves.easeOutCubic,
                          alignment: Alignment.topCenter,
                          clipBehavior: Clip.hardEdge,
                          child: keyboard
                              ? const SizedBox(width: double.infinity)
                              : OverflowBox(
                                  // O bloco tem altura natural (logo + carrossel).
                                  // O Clip do AnimatedSize corta o excedente sem
                                  // fazer o Column interno estourar no frame em
                                  // que o teclado abre.
                                  alignment: Alignment.topCenter,
                                  maxHeight: double.infinity,
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
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
                                      SizedBox(
                                        height: carouselHeight,
                                        child: const CarouselDestaques(),
                                      ),
                                    ],
                                  ),
                                ),
                        ),
                      ),
                      Expanded(
                        child: SingleChildScrollView(
                          physics: const ClampingScrollPhysics(),
                          child: _AuthCard(
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
                          ),
                        ),
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
  });

  final int step;
  final TextEditingController phone, otp;
  final bool busy;
  final String? error;
  final VoidCallback onSubmitPhone, onSubmitOtp;
  final ValueChanged<int> onChangeStep;

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
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Celular',
                    hintText: '(69) 9 9999-9999',
                    prefixIcon: Icon(Icons.phone_iphone),
                  ),
                  onSubmitted: (_) => onSubmitPhone(),
                ),
                if (error != null) ...[
                  const SizedBox(height: AppSpace.s),
                  Text(error!, style: TextStyle(color: t.danger)),
                ],
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
                  Text('Código de verificação',
                      style: AppType.title.copyWith(color: t.ink)),
                ]),
                const SizedBox(height: AppSpace.xs),
                Text('Enviamos um SMS para ${phone.text}',
                    style: AppType.label.copyWith(color: t.muted)),
                const SizedBox(height: AppSpace.l),
                TextField(
                  controller: otp,
                  keyboardType: TextInputType.number,
                  maxLength: 4,
                  autofocus: true,
                  textAlign: TextAlign.center,
                  style: AppType.display.copyWith(letterSpacing: 12),
                  decoration: const InputDecoration(
                    counterText: '',
                    hintText: '••••',
                    prefixIcon: Icon(Icons.sms_outlined),
                  ),
                  onSubmitted: (_) => onSubmitOtp(),
                ),
                if (error != null) ...[
                  const SizedBox(height: AppSpace.s),
                  Text(error!, style: TextStyle(color: t.danger)),
                ],
                const SizedBox(height: AppSpace.l),
                GradientButton(
                  onPressed: busy ? null : onSubmitOtp,
                  child: busy
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
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