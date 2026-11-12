import 'package:flutter/material.dart';
import 'package:ten_auth/ten_auth.dart';
import 'package:ten_design/ten_design.dart';

import '../api/console_api.dart';

/// Login do console da operação: e-mail → código de 6 dígitos → conferida do
/// PAPEL da conta.
///
/// Duas regras que a tela impõe antes do servidor:
///   1. o console NÃO cadastra conta (`create_user: false`) — a operação
///      entra com conta que já existe;
///   2. a conta precisa ser AGENT/ADMIN. Quem não é recebe a recusa na
///      tela, e a sessão é encerrada: entrar "funcionando" e só falhar na
///      fila seria pior do que não entrar.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.onDone, required this.api, this.auth});

  /// Chamado depois que a conta é conferida e é da operação.
  final VoidCallback onDone;

  final ConsoleApi api;

  /// Autenticação real (GoTrue).
  final AuthService? auth;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _email = TextEditingController();
  final _otp = TextEditingController();
  late final FocusNode _emailFocus;
  late final FocusNode _otpFocus;

  bool _busy = false;
  bool _codeSent = false;
  String? _error;

  /// A que campo o erro pertence: um erro de campo aparece NO campo (o
  /// `errorText`), e um erro de servidor aparece num aviso à parte.
  _ErrorField _errorField = _ErrorField.none;

  static final _emailPattern = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]{2,}$');

  @override
  void initState() {
    super.initState();
    _emailFocus = FocusNode(debugLabel: 'console-email');
    _otpFocus = FocusNode(debugLabel: 'console-otp');
  }

  @override
  void dispose() {
    _email.dispose();
    _otp.dispose();
    _emailFocus.dispose();
    _otpFocus.dispose();
    super.dispose();
  }

  void _clearError() {
    if (_error == null) return;
    setState(() {
      _error = null;
      _errorField = _ErrorField.none;
    });
  }

  void _focusAfterFrame(FocusNode node) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      node.requestFocus();
    });
  }

  String _authMessage(AuthException e) => switch (e.failure) {
        AuthFailure.offline => 'Sem conexão com o servidor de acesso.',
        AuthFailure.codeInvalid => 'Código incorreto. Confira o código recebido.',
        AuthFailure.codeExpired => 'Este código expirou. Peça um novo.',
        AuthFailure.rateLimited =>
          'Muitos pedidos de código. Espere alguns minutos.',
        AuthFailure.rejected => e.message,
        AuthFailure.unknown => 'Falha ao falar com o servidor de acesso.',
      };

  Future<void> _sendCode() async {
    final value = _email.text.trim();
    if (!_emailPattern.hasMatch(value)) {
      setState(() {
        _error = 'Informe um e-mail válido, como nome@exemplo.com.';
        _errorField = _ErrorField.email;
      });
      return;
    }
    final auth = widget.auth;
    if (auth == null) {
      setState(() {
        _error = 'Console sem servidor de acesso.';
        _errorField = _ErrorField.none;
      });
      return;
    }
    _emailFocus.unfocus();
    setState(() {
      _busy = true;
      _error = null;
      _errorField = _ErrorField.none;
    });
    try {
      // `create_user: false`: o console não cria conta. Quem opera o
      // cadastro do parceiro entra com a conta que a operação já tem.
      // `withRole: false`: entrar não mexe no papel da conta.
      await auth.sendCode(value, createUser: false, withRole: false);
      if (!mounted) return;
      setState(() => _codeSent = true);
      _focusAfterFrame(_otpFocus);
    } on AuthException catch (e) {
      if (mounted) {
        setState(() {
          _error = _authMessage(e);
          _errorField = _ErrorField.none;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = 'Falha ao falar com o servidor de acesso.';
          _errorField = _ErrorField.none;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _verify() async {
    final auth = widget.auth;
    if (auth == null) return;
    final digits = _otp.text.replaceAll(RegExp(r'\D'), '');
    if (digits.length != 6) {
      setState(() {
        _error = 'O código tem 6 dígitos.';
        _errorField = _ErrorField.otp;
      });
      return;
    }
    _otpFocus.unfocus();
    setState(() {
      _busy = true;
      _error = null;
      _errorField = _ErrorField.none;
    });
    try {
      await auth.verifyCode(_email.text.trim(), digits);

      // A sessão existe: agora o CONSOLE pergunta quem é. Quem não é da
      // operação não entra — e a sessão é encerrada na hora.
      final me = await widget.api.me();
      if (!me.isAgent) {
        await auth.signOut();
        if (!mounted) return;
        setState(() => _error =
            'Esta conta não é da operação. O console exige papel AGENT ou ADMIN.');
        return;
      }
      if (!mounted) return;
      widget.onDone();
    } on AuthException catch (e) {
      if (mounted) {
        setState(() {
          _error = _authMessage(e);
          _errorField = _ErrorField.none;
        });
      }
    } on ApiProblem catch (p) {
      if (mounted) {
        setState(() {
          _error = _problemMessage(p);
          _errorField = _ErrorField.none;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = 'Falha ao falar com o servidor.';
          _errorField = _ErrorField.none;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// A tela decide pelo CÓDIGO do problema, não pelo texto do servidor.
  String _problemMessage(ApiProblem p) => switch (p.code) {
        'forbidden' => 'Esta conta não é da operação.',
        'unauthenticated' => 'Faça login para continuar.',
        'offline' => 'Sem conexão com o servidor.',
        'not_configured' => p.title,
        _ => p.title,
      };

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppSpace.xl),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      color: t.primary.withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(Icons.admin_panel_settings_outlined,
                        color: t.primaryInk, size: 30),
                  ),
                  const SizedBox(height: AppSpace.l),
                  Text('Console da operação',
                      textAlign: TextAlign.center,
                      style: AppType.title.copyWith(color: t.ink)),
                  const SizedBox(height: AppSpace.xs),
                  Text(
                    'Fila do cadastro dos parceiros, prazo e decisão.',
                    textAlign: TextAlign.center,
                    style: AppType.body.copyWith(color: t.muted),
                  ),
                  const SizedBox(height: AppSpace.xl),
                  if (!_codeSent)
                    _emailStep(t)
                  else
                    _otpStep(t),
                  if (_error != null && _errorField == _ErrorField.none) ...[
                    const SizedBox(height: AppSpace.m),
                    _ErrorBanner(message: _error!),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _emailStep(ColorSchemeColorTokens t) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const ValueKey('console-email'),
            controller: _email,
            focusNode: _emailFocus,
            keyboardType: TextInputType.emailAddress,
            autocorrect: false,
            autofillHints: const [AutofillHints.email],
            onChanged: (_) => _clearError(),
            decoration: InputDecoration(
              labelText: 'E-mail',
              hintText: 'nome@exemplo.com',
              errorText: _errorField == _ErrorField.email ? _error : null,
            ),
          ),
          const SizedBox(height: AppSpace.l),
          GradientButton(
            key: const ValueKey('console-send-code'),
            onPressed: _busy ? null : _sendCode,
            child: _busy
                // O spinner é `onPrimary` (ink) sobre o teal: teal sobre teal
                // seria 1:1 de contraste.
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2.4, color: AppColors.onPrimary))
                : const Text('ENVIAR CÓDIGO'),
          ),
        ],
      );

  Widget _otpStep(ColorSchemeColorTokens t) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Código enviado para ${_email.text.trim()}',
              style: AppType.label.copyWith(color: t.muted)),
          const SizedBox(height: AppSpace.m),
          TextField(
            key: const ValueKey('console-otp'),
            controller: _otp,
            focusNode: _otpFocus,
            keyboardType: TextInputType.number,
            autofocus: false,
            maxLength: 6,
            onChanged: (_) => _clearError(),
            decoration: InputDecoration(
              labelText: 'Código de 6 dígitos',
              counterText: '',
              errorText: _errorField == _ErrorField.otp ? _error : null,
            ),
          ),
          const SizedBox(height: AppSpace.l),
          GradientButton(
            key: const ValueKey('console-enter'),
            onPressed: _busy ? null : _verify,
            child: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2.4, color: AppColors.onPrimary))
                : const Text('ENTRAR'),
          ),
          const SizedBox(height: AppSpace.s),
          TextButton(
            onPressed: _busy ? null : () => setState(() => _codeSent = false),
            child: const Text('Trocar o e-mail'),
          ),
        ],
      );
}

/// O erro que não pertence a um campo: um aviso com ícone, na cor de erro
/// (o teal é marca de ação — nunca sinaliza erro).
class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    return Container(
      key: const ValueKey('console-error'),
      padding: const EdgeInsets.all(AppSpace.m),
      decoration: BoxDecoration(
        color: t.danger.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppSpace.radiusCard),
        border: Border.all(color: t.danger.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, size: 18, color: t.danger),
          const SizedBox(width: AppSpace.s),
          Expanded(
            child: Text(message, style: AppType.label.copyWith(color: t.danger)),
          ),
        ],
      ),
    );
  }
}

/// A que campo o erro pertence.
enum _ErrorField { none, email, otp }

