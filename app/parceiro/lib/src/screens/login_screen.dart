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
    return Scaffold(
      backgroundColor: t.background,
      resizeToAvoidBottomInset: true,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (dark) ...[
            // Mapa noturno do kit ao fundo + véu grafite + glow verde.
            Image.asset(
              AppAssets.mapa,
              fit: BoxFit.cover,
              opacity: const AlwaysStoppedAnimation(0.18),
              errorBuilder: (_, __, ___) => const SizedBox.shrink(),
            ),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [AppColors.graphiteDeep, Color(0xCC232C30)],
                ),
              ),
            ),
          ] else ...[
            // Claro: fundo do tema + halo verde suave atrás da marca.
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0xFFEDF9F7), Color(0xFFFBFEFD)],
                ),
              ),
            ),
            Positioned(
              top: -120,
              right: -90,
              child: Container(
                width: 300,
                height: 300,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(colors: [
                    AppColors.primary.withValues(alpha: 0.20),
                    AppColors.primary.withValues(alpha: 0.0),
                  ]),
                ),
              ),
            ),
          ],
          SafeArea(
            child: Column(
              children: [
                const SizedBox(height: AppSpace.xxl),
                // Logo - versão clara para tema claro, branca para tema escuro
                Image.asset(
                  dark ? AppAssets.logoBranco : AppAssets.logoTransparente,
                  height: 64,
                  errorBuilder: (_, __, ___) =>
                      Icon(Icons.verified, size: 56, color: t.primary),
                ),
                const SizedBox(height: AppSpace.s),
                // Carrossel de login - posicionado logo abaixo da logo e acima do campo
                // 5 imagens promocionais com auto-slide de 3s
                const CarouselDestaques(),
                const SizedBox(height: AppSpace.m),
                Text(
                  'Seu volante. Seu dinheiro.',
                  style: AppType.titleOnDark
                      .copyWith(fontSize: 25, color: t.ink),
                ),
                const SizedBox(height: AppSpace.s),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: AppSpace.xl),
                  child: Text(
                    'Com o Passe 10 é + você fica com 100% de cada corrida — '
                    'sem taxa, sem pegadinha.',
                    textAlign: TextAlign.center,
                    style: AppType.onDark.copyWith(color: t.muted),
                  ),
                ),
                const Spacer(),
                _AuthCard(
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
                const SizedBox(height: AppSpace.xl),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Card branco/inferior com o formulário da etapa atual.
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