import 'package:flutter/material.dart';
import 'package:ten_auth/ten_auth.dart';
import 'package:ten_design/ten_design.dart';

import 'src/api/console_api.dart';
import 'src/screens/login_screen.dart';
import 'src/screens/queue_screen.dart';
import 'src/state/console_controller.dart';

/// Ponto de entrada do 10 é + Console.
///
/// Superfície IRMÃ do passageiro e do parceiro (ver docs/PRODUTO-MESTRE.md,
/// Fase 3): o console da operação é onde a pessoa "Cris" lê a fila do
/// cadastro dos parceiros, vê o prazo e decide.
///
/// Backends (tudo vem do ambiente de build — nunca hardcoded em release):
///
///   `KYC_BASE`      a Edge Function `kyc` (fila, SLA e decisão). Aponta
///                   para a FUNÇÃO (`.../functions/v1/kyc`). Vazio = o
///                   console não tem backend: a tela diz isso, em vez de
///                   mostrar uma fila inventada.
///   `AUTH_BASE`     o GoTrue (Supabase Auth). Vazio = modo dev: sem
///                   servidor de acesso, o login não abre.
///   `AUTH_ANON_KEY` chave pública do projeto (não é segredo).
///   `API_TOKEN`     token de build (plano B para testes e desenvolvimento).
void main() {
  runApp(const ConsoleApp());
}

class ConsoleApp extends StatefulWidget {
  const ConsoleApp({super.key});

  @override
  State<ConsoleApp> createState() => _ConsoleAppState();
}

class _ConsoleAppState extends State<ConsoleApp> {
  late final AuthService? _auth;
  late final ConsoleApi _api;
  late final ConsoleController _controller;
  bool _signedIn = false;

  @override
  void initState() {
    super.initState();
    const kycBase = String.fromEnvironment('KYC_BASE', defaultValue: '');
    const authBase = String.fromEnvironment('AUTH_BASE', defaultValue: '');
    const authAnonKey = String.fromEnvironment('AUTH_ANON_KEY',
        defaultValue: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH');
    const buildToken = String.fromEnvironment('API_TOKEN', defaultValue: '');

    // O console não cadastra conta: ele entra em conta que já existe, com
    // papel AGENT/ADMIN. O `role` aqui é o que o GoTrue usaria se a conta
    // fosse criada daqui — e ela nunca é.
    _auth = authBase.isEmpty
        ? null
        : AuthService(baseUrl: authBase, anonKey: authAnonKey, role: 'AGENT');

    _api = ConsoleApi(
      baseUrl: kycBase,
      accessToken: () async {
        final session = await _auth?.accessToken();
        return session ?? buildToken;
      },
    );
    _controller = ConsoleController(_api);
    _restoreSession();
  }

  /// Recupera a sessão salva: quem já entrou no console não vê o login de
  /// novo. A sessão pode ser de quem NÃO é da operação (a conta foi
  /// rebaixada depois do login) — nesse caso, o console volta ao login.
  Future<void> _restoreSession() async {
    final auth = _auth;
    if (auth == null) return;
    await auth.restore();
    if (!mounted || !auth.isSignedIn) return;
    try {
      final me = await _api.me();
      if (!me.isAgent) {
        await auth.signOut();
        return;
      }
    } on ApiProblem {
      // Sem rede a sessão fica: o console abre e a fila mostra o erro de
      // conexão quando a rede voltar. Falha de credencial, não.
      if (!mounted) return;
    } catch (_) {
      // idem.
    }
    if (!mounted) return;
    setState(() => _signedIn = true);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '10 é + Console',
      debugShowCheckedModeBanner: false,
      theme: buildLightTheme(),
      darkTheme: buildDarkTheme(),
      home: _signedIn
          ? QueueScreen(
              controller: _controller,
              onLogout: () {
                _auth?.signOut();
                setState(() => _signedIn = false);
              },
            )
          : LoginScreen(
              api: _api,
              auth: _auth,
              onDone: () => setState(() => _signedIn = true),
            ),
    );
  }
}
