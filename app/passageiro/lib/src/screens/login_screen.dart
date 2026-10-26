import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/theme.dart';

/// P1 Apresentação + login (OTP F1): tela de abertura elegante do kit —
/// fundo grafite com a moto do kit, logo e proposta de valor; em seguida
/// telefone → código de 4 dígitos. O token real entra no fluxo de auth;
/// aqui a navegação é o contrato (onDone).
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
  int _step = 0; // 0 = telefone, 1 = OTP
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
    // Tela sempre escura: os ícones da barra de status precisam ser claros
    // mesmo com o app no tema claro.
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
        systemNavigationBarColor: AppColors.graphiteDeep,
        systemNavigationBarIconBrightness: Brightness.light,
      ),
      child: Scaffold(
        backgroundColor: AppColors.graphiteDeep,
        body: Stack(
          fit: StackFit.expand,
          children: [
            // Moto do kit ao fundo + véu grafite + glow verde.
            Image.asset(
              'assets/kit/moto.png',
              fit: BoxFit.cover,
              opacity: const AlwaysStoppedAnimation(0.22),
              errorBuilder: (_, __, ___) => const SizedBox.shrink(),
            ),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0xE6232C30), Color(0xCC232C30)],
                ),
              ),
            ),
            SafeArea(
              child: Column(
                children: [
                  const SizedBox(height: AppSpace.xxl),
                  Image.asset(
                    'assets/kit/logo_branco.png',
                    height: 72,
                    errorBuilder: (_, __, ___) =>
                        const Text('10 é +', style: AppType.titleOnDark),
                  ),
                  const SizedBox(height: AppSpace.m),
                  Text('Pra onde?',
                      style: AppType.titleOnDark
                          .copyWith(fontSize: 39, color: AppColors.onGraphite)),
                  const SizedBox(height: AppSpace.s),
                  Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: AppSpace.xl),
                    child: Text(
                      'Preço na hora, parceiro perto e segurança do início '
                      'ao fim — sem surpresa no valor.',
                      textAlign: TextAlign.center,
                      style: AppType.onDark
                          .copyWith(color: AppColors.onGraphiteMuted),
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
      ),
    );
  }
}

/// Card branco inferior com o formulário da etapa atual.
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
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(horizontal: AppSpace.l),
      padding: const EdgeInsets.fromLTRB(
          AppSpace.xl, AppSpace.xl, AppSpace.xl, AppSpace.l),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: const BorderRadius.vertical(
            top: Radius.circular(AppSpace.radiusSheet)),
        boxShadow: appShadow,
      ),
      child: step == 0
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Entrar ou criar conta', style: AppType.title),
                const SizedBox(height: AppSpace.xs),
                const Text('Seu celular é a sua conta — sem senha.',
                    style: AppType.label),
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
                  Text(error!, style: const TextStyle(color: AppColors.danger)),
                ],
                const SizedBox(height: AppSpace.l),
                GradientButton(
                    onPressed: onSubmitPhone, child: const Text('CONTINUAR')),
                const SizedBox(height: AppSpace.m),
                const Center(
                  child: Text('Ao continuar você aceita os Termos de Uso.',
                      style: AppType.label),
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
                  const Text('Código de verificação', style: AppType.title),
                ]),
                const SizedBox(height: AppSpace.xs),
                Text('Enviamos um SMS para ${phone.text}',
                    style: AppType.label),
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
                  Text(error!, style: const TextStyle(color: AppColors.danger)),
                ],
                const SizedBox(height: AppSpace.l),
                GradientButton(
                  onPressed: busy ? null : onSubmitOtp,
                  child: busy
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: AppColors.ink))
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
