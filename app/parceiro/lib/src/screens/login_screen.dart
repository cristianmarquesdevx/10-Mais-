import 'package:flutter/material.dart';
import 'package:ten_auth/ten_auth.dart';
import 'package:ten_design/ten_design.dart';

import '../assets/app_assets.dart';
import '../theme/theme.dart';
import 'widgets/carousel_destaques.dart';

/// P1 Apresentação + login (OTP F1): tela de abertura elegante do kit —
/// fundo da marca, logo e proposta de valor; em seguida telefone → e-mail →
/// código de 6 dígitos.
///
/// O token real entra no fluxo de auth (GoTrue); sem ele o app fica no modo
/// dev, em que o código de 4 dígitos passa sem servidor — é o que os testes
/// de layout exercitam.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.onDone, this.auth});

  /// Chamado após o OTP ser aceito.
  final VoidCallback onDone;

  /// Autenticação real (GoTrue). Nulo = modo dev (sem servidor).
  final AuthService? auth;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _phone = TextEditingController();
  final _email = TextEditingController();
  final _otp = TextEditingController();

  // Um FocusNode por campo: sem isso o foco fica preso no campo anterior e
  // o teclado não troca entre o numérico do celular e o de letras do e-mail.
  late final FocusNode _phoneFocus;
  late final FocusNode _emailFocus;
  late final FocusNode _otpFocus;

  /// Mantém o cartão (e a conexão do teclado) vivo quando o layout troca
  /// entre "herói + cartão" e "cartão rolável" ao abrir o teclado.
  final _cardKey = GlobalKey(debugLabel: 'auth-card');

  int _step = 0; // 0 = telefone, 1 = e-mail, 2 = OTP
  bool _busy = false;
  String? _error;

  /// Modo dev (sem serviço de auth): o OTP de 4 dígitos passa sem servidor.
  bool get _dev => widget.auth == null;

  /// Quantos dígitos o código tem: 6 no GoTrue, 4 no modo dev.
  int get _otpLength => _dev ? 4 : 6;

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

  String get _phoneDigits => _phone.text.replaceAll(RegExp(r'\D'), '');

  /// Some com o erro assim que o usuário corrige o campo.
  void _clearError() {
    if (_error == null) return;
    setState(() => _error = null);
  }

  /// Pede o foco só depois do frame: o campo da próxima etapa ainda não
  /// existe quando o botão é tocado.
  void _focusAfterFrame(FocusNode node) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      node.requestFocus();
    });
  }

  /// Mensagem de erro do serviço de auth — a tela decide pelo enum, o texto
  /// é para o usuário.
  String _authMessage(AuthException e) => switch (e.failure) {
        AuthFailure.offline => 'Sem conexão com o servidor de acesso.',
        AuthFailure.codeInvalid => 'Código incorreto. Confira o código recebido.',
        AuthFailure.codeExpired => 'Este código expirou. Peça um novo.',
        AuthFailure.rateLimited =>
          'Muitos pedidos de código. Espere alguns minutos.',
        AuthFailure.rejected => e.message,
        AuthFailure.unknown => 'Falha ao falar com o servidor de acesso.',
      };

  void _submitPhone() {
    if (_phoneDigits.length < 10) {
      setState(() => _error = 'Informe um celular com DDD.');
      return;
    }
    _phoneFocus.unfocus();
    setState(() {
      _error = null;
      _step = 1;
    });
    _focusAfterFrame(_emailFocus);
  }

  Future<void> _submitEmail() async {
    final value = _email.text.trim();
    if (!_emailPattern.hasMatch(value)) {
      setState(() =>
          _error = 'Informe um e-mail válido, como nome@exemplo.com.');
      return;
    }
    _emailFocus.unfocus();
    if (_dev) {
      setState(() {
        _error = null;
        _step = 2;
      });
      _focusAfterFrame(_otpFocus);
      return;
    }
    // Autenticação real: o código é pedido ao GoTrue ANTES de mostrar a etapa
    // do OTP — se o envio falhar, o usuário continua na etapa do e-mail em vez
    // de receber um campo que nunca vai receber nada.
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.auth!.sendCode(value);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _step = 2;
      });
      _focusAfterFrame(_otpFocus);
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = _authMessage(e);
      });
    }
  }

  Future<void> _submitOtp() async {
    final code = _otp.text.trim();
    if (code.length < _otpLength) {
      setState(() => _error = 'Digite o código de $_otpLength dígitos.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    if (_dev) {
      // Modo dev: o código não vai a nenhum servidor (é o que os testes de
      // layout usam para chegar ao painel).
      await Future<void>.delayed(const Duration(milliseconds: 600));
      if (!mounted) return;
      setState(() => _busy = false);
      widget.onDone();
      return;
    }
    try {
      await widget.auth!.verifyCode(_email.text.trim(), code);
      // O telefone é registrado depois do login: o piloto não tem provedor de
      // SMS, mas o contato continua indo para o backend.
      await widget.auth!.attachPhone(_phone.text);
      if (!mounted) return;
      setState(() => _busy = false);
      widget.onDone();
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = _authMessage(e);
      });
    }
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
                    key: _cardKey,
                    step: _step,
                    phone: _phone,
                    email: _email,
                    otp: _otp,
                    phoneFocus: _phoneFocus,
                    emailFocus: _emailFocus,
                    otpFocus: _otpFocus,
                    busy: _busy,
                    error: _error,
                    otpLength: _otpLength,
                    // No piloto o código chega por e-mail (não há provedor de
                    // SMS contratado); no modo dev a tela não promete nada.
                    otpPrompt: _dev
                        ? 'Enviamos um SMS para '
                            '${_phone.text.replaceAll(RegExp(r'\D'), '')}'
                        : 'Enviamos um código para ${_email.text.trim()}',
                    onSubmitPhone: _submitPhone,
                    onSubmitEmail: _submitEmail,
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
    super.key,
    required this.step,
    required this.phone,
    required this.email,
    required this.otp,
    required this.phoneFocus,
    required this.emailFocus,
    required this.otpFocus,
    required this.busy,
    required this.error,
    required this.otpLength,
    required this.otpPrompt,
    required this.onSubmitPhone,
    required this.onSubmitEmail,
    required this.onSubmitOtp,
    required this.onChangeStep,
    required this.onClearError,
  });

  final int step;
  final TextEditingController phone, email, otp;
  final FocusNode phoneFocus, emailFocus, otpFocus;
  final bool busy;
  final String? error;
  final int otpLength;
  final String otpPrompt;
  final VoidCallback onSubmitPhone, onSubmitEmail, onSubmitOtp;
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
                  key: const ValueKey('login-phone'),
                  controller: phone,
                  focusNode: phoneFocus,
                  keyboardType: TextInputType.phone,
                  textInputAction: TextInputAction.next,
                  autofillHints: const [AutofillHints.telephoneNumber],
                  onChanged: (_) => onClearError(),
                  decoration: InputDecoration(
                    labelText: 'Celular',
                    hintText: '(69) 9 9999-9999',
                    prefixIcon: const Icon(Icons.phone_iphone),
                    floatingLabelBehavior: FloatingLabelBehavior.always,
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
          : step == 1
              ? Column(
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
                        child: Text('E-mail',
                            style: AppType.title.copyWith(color: t.ink)),
                      ),
                    ]),
                    const SizedBox(height: AppSpace.xs),
                    Text('Digite seu e-mail para receber o código de acesso.',
                        style: AppType.label.copyWith(color: t.muted)),
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
                      onChanged: (_) => onClearError(),
                      decoration: InputDecoration(
                        labelText: 'E-mail',
                        hintText: 'exemplo@email.com',
                        floatingLabelBehavior: FloatingLabelBehavior.always,
                        errorText: error,
                        errorMaxLines: 2,
                      ),
                      onSubmitted: (_) => onSubmitEmail(),
                    ),
                    const SizedBox(height: AppSpace.l),
                    GradientButton(
                        onPressed: busy ? null : onSubmitEmail,
                        child: const Text('CONTINUAR')),
                    const SizedBox(height: AppSpace.m),
                    Center(
                      child: TextButton(
                        onPressed: busy ? null : () => onChangeStep(0),
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
                            style: AppType.title.copyWith(color: t.ink)),
                      ),
                    ]),
                    const SizedBox(height: AppSpace.xs),
                    Text(otpPrompt, style: AppType.label.copyWith(color: t.muted)),
                    const SizedBox(height: AppSpace.l),
                    TextField(
                      key: const ValueKey('login-otp'),
                      controller: otp,
                      focusNode: otpFocus,
                      keyboardType: TextInputType.number,
                      textInputAction: TextInputAction.done,
                      autofillHints: const [AutofillHints.oneTimeCode],
                      maxLength: otpLength,
                      textAlign: TextAlign.center,
                      style: AppType.display.copyWith(letterSpacing: 12),
                      onChanged: (_) => onClearError(),
                      decoration: InputDecoration(
                        counterText: '',
                        hintText: '•' * otpLength,
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
