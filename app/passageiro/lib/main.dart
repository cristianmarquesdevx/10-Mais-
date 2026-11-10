import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'src/api/client.dart';
import 'src/auth/auth_service.dart';
import 'src/screens/screens.dart';
import 'src/state/ride_controller.dart';
import 'src/theme/theme.dart';

/// Ponto de entrada do 10 é + Passageiro.
///
/// Backends (tudo vem do ambiente de build — nunca hardcoded em release):
///
///   `API_BASE`      o que ainda não migrou (perfil, suporte, convites) —
///                   em produção a mesma Edge Function; no piloto, a API de
///                   demonstração.
///   `RIDES_BASE`    o ciclo de corrida no Postgres (Edge Function `rides`).
///   `AUTH_BASE`     o GoTrue (Supabase Auth). Vazio = modo dev: sem
///                   servidor de acesso, o login aceita o OTP de 4 dígitos.
///   `AUTH_ANON_KEY` chave pública do projeto (não é segredo).
void main() {
  runApp(const PassageiroApp());
}

class PassageiroApp extends StatefulWidget {
  const PassageiroApp({super.key});

  @override
  State<PassageiroApp> createState() => _PassageiroAppState();
}

class _PassageiroAppState extends State<PassageiroApp> {
  late final AuthService? _auth;
  late final ApiClient _api;
  late final RideController _ride;
  bool _signedIn = false; // P1: tela de apresentação/login antes da home

  @override
  void initState() {
    super.initState();
    const apiBase = String.fromEnvironment('API_BASE',
        defaultValue: 'http://10.0.2.2:8787/functions/v1/v1');
    // Vazio = modo demonstração: o ciclo de corrida fica na API de demo.
    // O build de piloto/piloto passa a URL real do Postgres.
    const ridesBase = String.fromEnvironment('RIDES_BASE', defaultValue: '');
    // Vazio = modo dev: sem servidor de acesso o login aceita o OTP de
    // 4 dígitos. O build de piloto passa a URL do GoTrue.
    const authBase = String.fromEnvironment('AUTH_BASE', defaultValue: '');
    const authAnonKey = String.fromEnvironment('AUTH_ANON_KEY',
        defaultValue: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH');
    // Token de build: é o plano B para quando não há sessão (dev/testes).
    const buildToken = String.fromEnvironment('API_TOKEN', defaultValue: '');

    // AUTH_BASE vazio = modo dev: sem servidor de acesso o app não pede
    // código e não renova token (é o modo dos testes de layout).
    _auth = authBase.isEmpty
        ? null
        : AuthService(baseUrl: authBase, anonKey: authAnonKey, role: 'PASSENGER');

    _api = ApiClient(
      baseUrl: apiBase,
      ridesBase: ridesBase,
      // O token da sessão manda; o do build é o plano B. A chamada é
      // assíncrona porque o serviço renova a sessão quando o token vence.
      accessToken: () async {
        final session = await _auth?.accessToken();
        return session ?? buildToken;
      },
    );
    _ride = RideController(_api);
    _ride.refresh(); // corrida ativa ao abrir o app (deep link F4)
    // Mostra o login imediatamente para evitar tela branca durante o carregamento do tema.
    // O tema continua carregando em segundo plano.
    _loadTheme();
    _restoreSession();
  }

  /// Recupera a sessão salva: quem já entrou no app não vê o login de novo.
  Future<void> _restoreSession() async {
    final auth = _auth;
    if (auth == null) return;
    await auth.restore();
    if (!mounted || !auth.isSignedIn) return;
    setState(() => _signedIn = true);
    _ride.refresh();
  }

  Future<void> _loadTheme() async {
    final mode = await ThemePrefs.getMode();
    // O Perfil escreve neste notifier ao trocar de tema; aqui só semeia o
    // valor salvo, para o app abrir já no modo escolhido.
    themeModeNotifier.value = mode;
  }

  @override
  void dispose() {
    _ride.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Mostra o login imediatamente para evitar tela branca durante o carregamento do tema.
    // O tema continua carregando em segundo plano.
    return AppScope(
      ride: _ride,
      api: _api,
      // Escuta o modo ativo: trocar para "Escuro" no Perfil repinta o app na
      // hora, sem precisar reabrir.
      child: ValueListenableBuilder<ThemeModePref>(
        valueListenable: themeModeNotifier,
        builder: (context, mode, _) => MaterialApp(
          title: '10 é + Passageiro',
          debugShowCheckedModeBanner: false,
          theme: buildLightTheme(),
          darkTheme: buildDarkTheme(),
          // O modo vem do seletor do Perfil (e do valor salvo). Fixar
          // ThemeMode.light aqui desligava o tema escuro no app inteiro.
          themeMode: mode.materialMode,
          // Ícones da barra de status/navegação acompanham o tema; o login
          // escuro sobrescreve com o próprio AnnotatedRegion.
          builder: (context, child) {
            final dark = Theme.of(context).brightness == Brightness.dark;
            return AnnotatedRegion<SystemUiOverlayStyle>(
              value: (dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark)
                  .copyWith(
                statusBarColor: Colors.transparent,
                systemNavigationBarColor:
                    dark ? AppColorsDark.background : AppColors.surface,
                systemNavigationBarIconBrightness:
                    dark ? Brightness.light : Brightness.dark,
              ),
              child: child ?? const SizedBox.shrink(),
            );
          },
          home: _signedIn
              ? const HomeScreen()
              : LoginScreen(
                  auth: _auth,
                  onDone: () => setState(() => _signedIn = true),
                ),
          routes: {
            '/destino': (_) => const DestinoScreen(),
            '/negociar': (_) => const NegociarScreen(),
            '/fila': (_) => const FilaScreen(),
            '/acompanhar': (_) => const AcompanharScreen(),
            '/viagem': (_) => const ViagemScreen(),
            '/pagamento': (_) => const PagamentoScreen(),
            '/avaliar': (_) => const AvaliarScreen(),
            '/historico': (_) => const HistoricoScreen(),
            '/perfil': (_) => const PerfilScreen(),
            '/perfil-setup': (_) => const ProfileSetupScreen(),
            '/scratch-campaigns': (_) => const ScratchCampaignsScreen(),
            '/scratch-play': (_) => const ScratchPlayScreen(),
            '/scratch-history': (_) => const ScratchHistoryScreen(),
            '/invite': (_) => const InviteScreen(),
          },
        ),
      ),
    );
  }
}

/// InheritedNotifier: telas escutam o RideController sem package extra.
class AppScope extends InheritedNotifier<RideController> {
  const AppScope({
    super.key,
    required this.ride,
    required this.api,
    required super.child,
  }) : super(notifier: ride);

  final RideController ride;
  final ApiClient api;

  static RideController of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;

  static ApiClient apiOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!.api;
}