import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../assets/app_assets.dart';
import '../theme/theme.dart';
import 'widgets/carousel_destaques.dart';

/// Tela de login com dois passos (celular → email → código OTP).
/// Apresentação (carousel) é mostrada antes via navegação separada.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.onDone});

  /// Chamado após o OTP ser aceito (dev: qualquer 4 dígitos).
  final VoidCallback onDone;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _phone = TextEditingController();
  final _email = TextEditingController();
  final _otp = TextEditingController();

  // M6: um FocusNode por campo, criado no initState. Sem isso o foco fica
  // preso no campo anterior e o teclado numérico não troca para letras.
  late final FocusNode _phoneFocus;
  late final FocusNode _emailFocus;
  late final FocusNode _otpFocus;

  int _step = 0; // 0 = numero, 1 = email, 2 = OTP
  bool _busy = false;
  String? _error;

  /// Formato mínimo de e-mail: algo@dominio.tld (sem espaços).
  static final _emailPattern = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]{2,}$');

  @override
  void initState() {
    super.initState();
    _phoneFocus = FocusNode(debugLabel: 'login-phone');
    _emailFocus = FocusNode(debugLabel: 'login-email');
    _otpFocus = FocusNode(debugLabel: 'login-otp');
  }

  @override
  void dispose() {
    _phone.dispose();
    _email.dispose();
    _otp.dispose();
    _phoneFocus.dispose();
    _emailFocus.dispose();
    _otpFocus.dispose();
    super.dispose();
  }

  /// Pede o foco só depois do frame: o campo da próxima etapa ainda não
  /// existe quando o botão é tocado.
  void _focusAfterFrame(FocusNode node) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      node.requestFocus();
    });
  }

  String get _phoneDigits => _phone.text.replaceAll(RegExp(r'\D'), '');

  void _submitPhone() {
    if (_phoneDigits.length < 10) {
      setState(() => _error = 'Informe um celular com DDD.');
      return;
    }
    // Desfoca o celular antes de trocar de campo: é o que encerra a conexão
    // do teclado numérico com o sistema.
    _phoneFocus.unfocus();
    setState(() {
      _error = null;
      _step = 1;
    });
    _focusAfterFrame(_emailFocus);
  }

  void _submitEmail() {
    final value = _email.text.trim();
    if (!_emailPattern.hasMatch(value)) {
      setState(() =>
          _error = 'Informe um e-mail válido, como nome@exemplo.com.');
      return;
    }
    _emailFocus.unfocus();
    setState(() {
      _error = null;
      _step = 2;
    });
    _focusAfterFrame(_otpFocus);
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

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
        statusBarBrightness: dark ? Brightness.dark : Brightness.light,
        systemNavigationBarColor: t.background,
        systemNavigationBarIconBrightness:
            dark ? Brightness.light : Brightness.dark,
      ),
      child: Scaffold(
        backgroundColor: t.background,
        resizeToAvoidBottomInset: true,
        body: Stack(
          children: [
            // Halo suave da marca no topo: dá profundidade sem competir com
            // o carrossel nem com o formulário.
            Positioned(
              top: -160,
              left: -60,
              right: -60,
              child: IgnorePointer(
                child: Container(
                  height: 320,
                  decoration: BoxDecoration(
                    gradient: RadialGradient(colors: [
                      t.primary.withValues(alpha: dark ? 0.22 : 0.14),
                      t.primary.withValues(alpha: 0.0),
                    ]),
                  ),
                ),
              ),
            ),
            SafeArea(
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: EdgeInsets.only(
                    bottom: MediaQuery.of(context).viewInsets.bottom),
                child: Column(
                  children: [
                    const SizedBox(height: AppSpace.l),
                    Image.asset(
                      dark ? AppAssets.logoBranco : AppAssets.logoTransparente,
                      height: 44,
                      errorBuilder: (_, __, ___) =>
                          Icon(Icons.verified, size: 40, color: t.primary),
                    ),
                    const SizedBox(height: AppSpace.l),
                    const CarouselDestaques(),
                    const SizedBox(height: AppSpace.m),
                    _AuthCard(
                      step: _step,
                      phone: _phone,
                      email: _email,
                      otp: _otp,
                      phoneFocus: _phoneFocus,
                      emailFocus: _emailFocus,
                      otpFocus: _otpFocus,
                      busy: _busy,
                      error: _error,
                      onSubmitPhone: _submitPhone,
                      onSubmitEmail: _submitEmail,
                      onSubmitOtp: _submitOtp,
                      onChangeStep: (s) => setState(() {
                        _step = s;
                        _error = null;
                      }),
                    ),
                    const SizedBox(height: AppSpace.xl),
                  ],
                ),
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
    required this.email,
    required this.otp,
    required this.phoneFocus,
    required this.emailFocus,
    required this.otpFocus,
    required this.busy,
    required this.error,
    required this.onSubmitPhone,
    required this.onSubmitEmail,
    required this.onSubmitOtp,
    required this.onChangeStep,
  });

  final int step;
  final TextEditingController phone, email, otp;
  final FocusNode phoneFocus, emailFocus, otpFocus;
  final bool busy;
  final String? error;
  final VoidCallback onSubmitPhone, onSubmitEmail, onSubmitOtp;
  final ValueChanged<int> onChangeStep;

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(horizontal: AppSpace.l),
      padding: const EdgeInsets.fromLTRB(
          AppSpace.xl, AppSpace.xl, AppSpace.xl, AppSpace.l),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(AppSpace.radiusSheet),
        ),
        boxShadow: dark ? appShadowDark() : appShadow,
      ),
      child: step == 0
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Entrar ou criar conta',
                    style: titleStyle(context)),
                const SizedBox(height: AppSpace.xs),
                Text('Seu celular é a sua conta — sem senha.',
                    style: labelStyle(context)),
                const SizedBox(height: AppSpace.l),
                TextField(
                  key: const ValueKey('login-phone'),
                  controller: phone,
                  focusNode: phoneFocus,
                  keyboardType: TextInputType.phone,
                  textInputAction: TextInputAction.next,
                  autofillHints: const [AutofillHints.telephoneNumber],
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Número de celular',
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
                  child: Text(
                    'Ao continuar você aceita os Termos de Uso.',
                    style: labelStyle(context),
                  ),
                ),
              ],
            )
          : step == 1
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Email', style: titleStyle(context)),
                    const SizedBox(height: AppSpace.xs),
                    Text('Digite seu email para recuperação de conta.',
                        style: labelStyle(context)),
                    const SizedBox(height: AppSpace.l),
                    TextField(
                      key: const ValueKey('login-email'),
                      controller: email,
                      focusNode: emailFocus,
                      keyboardType: TextInputType.emailAddress,
                      textInputAction: TextInputAction.done,
                      autocorrect: false,
                      enableSuggestions: false,
                      autofillHints: const [AutofillHints.email],
                      decoration: const InputDecoration(
                        labelText: 'E-mail',
                        hintText: 'exemplo@email.com',
                      ),
                      onSubmitted: (_) => onSubmitEmail(),
                    ),
                    if (error != null) ...[
                      const SizedBox(height: AppSpace.s),
                      Text(error!, style: TextStyle(color: t.danger)),
                    ],
                    const SizedBox(height: AppSpace.l),
                    GradientButton(
                        onPressed: onSubmitEmail,
                        child: const Text('CONTINUAR')),
                    const SizedBox(height: AppSpace.m),
                    Center(
                      child: TextButton(
                        onPressed: () => onChangeStep(0),
                        child: const Text('Voltar ao número'),
                      ),
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
                            style: titleStyle(context)),
                      ),
                    ]),
                    const SizedBox(height: AppSpace.xs),
                    Text(
                        'Enviamos um SMS para ${phone.text.replaceAll(RegExp(r'\D'), '')}',
                        style: labelStyle(context)),
                    const SizedBox(height: AppSpace.l),
                    TextField(
                      key: const ValueKey('login-otp'),
                      controller: otp,
                      focusNode: otpFocus,
                      keyboardType: TextInputType.number,
                      textInputAction: TextInputAction.done,
                      autofillHints: const [AutofillHints.oneTimeCode],
                      maxLength: 4,
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
                          ? SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: t.ink),
                            )
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
