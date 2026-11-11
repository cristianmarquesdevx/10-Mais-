import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'src/api/client.dart';
import 'src/api/presence_api.dart';
import 'src/auth/auth_service.dart';
import 'src/screens/screens.dart';
import 'src/state/partner_controller.dart';
import 'src/theme/theme.dart';

/// Ponto de entrada do 10 é + Parceiro.
///
/// Backends (tudo vem do ambiente de build — nunca hardcoded em release):
///
///   `API_BASE`      o que ainda não migrou (KYC, passe, carteira,
///                   desempenho, preferências) — em produção a mesma Edge
///                   Function (a URL dela, com o prefixo `/functions/v1/v1`,
///                   vem no build); no piloto e no dev, a API de
///                   demonstração (default `10.0.2.2:8787`, que serve as
///                   rotas sem prefixo).
///   `RIDES_BASE`    o ciclo de corrida no Postgres (Edge Function `rides`).
///   `RADAR_BASE`    a presença real do parceiro (Edge Function `radar`).
///                   **Vazio = sem backend de presença**: o online/offline
///                   fica no backend de demonstração (modo dev/demo).
///   `AUTH_BASE`     o GoTrue (Supabase Auth). Vazio = modo dev: sem
///                   servidor de acesso, o login aceita o OTP de 4 dígitos.
///   `AUTH_ANON_KEY` chave pública do projeto (não é segredo).
void main() {
  runApp(const ParceiroApp());
}

class ParceiroApp extends StatefulWidget {
  const ParceiroApp({super.key});

  @override
  State<ParceiroApp> createState() => _ParceiroAppState();
}

class _ParceiroAppState extends State<ParceiroApp> {
  late final AuthService? _auth;
  late final ApiClient _api;
  late final PartnerController _partner;
  bool _signedIn = false; // P1: apresentação/login antes do shell
  bool _apresentou = false; // apresentação de abertura já exibida

  @override
  void initState() {
    super.initState();
    const apiBase = String.fromEnvironment('API_BASE',
        defaultValue: 'http://10.0.2.2:8787');
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
    // Base da Edge Function `radar` (presença real no Postgres). Vazio =
    // modo dev/demo: a presença fica no backend de demonstração.
    const radarBase = String.fromEnvironment('RADAR_BASE', defaultValue: '');

    // AUTH_BASE vazio = modo dev: sem servidor de acesso o app não pede
    // código e não renova token (é o modo dos testes de layout).
    _auth = authBase.isEmpty
        ? null
        : AuthService(baseUrl: authBase, anonKey: authAnonKey, role: 'PARTNER');

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
    final auth = _auth;
    _partner = PartnerController(
      _api,
      // A presença no radar (Postgres) leva o token da SESÃO: é o que impede
      // um parceiro de publicar posição no nome de outro. Sem sessão (modo
      // dev) a presença fica desligada e a tela avisa em vez de fingir.
      presence: PresenceApi(
        baseUrl: radarBase,
        token: auth == null ? defaultRadarToken : null,
        tokenProvider: auth == null
            ? null
            : () async {
                final session = await auth.accessToken();
                return session ?? '';
              },
      ),
    );
    _partner.loadMe(); // perfil/KYC ao abrir (P1 gate: em análise ≠ online)
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
    _partner.loadMe();
  }

  Future<void> _loadTheme() async {
    final mode = await ThemePrefs.getMode();
    // O Perfil escreve neste notifier ao trocar de tema; aqui só semeia o
    // valor salvo, para o app abrir já no modo escolhido.
    themeModeNotifier.value = mode;
  }

  @override
  void dispose() {
    _partner.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Mostra o login imediatamente para evitar tela branca durante o carregamento do tema.
    // O tema continua carregando em segundo plano.
    return AppScope(
      partner: _partner,
      api: _api,
      // Escuta o modo ativo: trocar para "Escuro" no Perfil repinta o app na
      // hora, sem precisar reabrir.
      child: ValueListenableBuilder<ThemeModePref>(
        valueListenable: themeModeNotifier,
        builder: (context, mode, _) => MaterialApp(
          title: '10 é + Parceiro',
          debugShowCheckedModeBanner: false,
          theme: buildLightTheme(),
          darkTheme: buildDarkTheme(),
          // O modo vem do seletor do Perfil (e do valor salvo). Fixar
          // ThemeMode.light aqui desligava o tema escuro no app inteiro.
          themeMode: mode.materialMode,
          // Ícones da barra de status e de navegação acompanham o tema,
          // para não ficarem claros sobre o fundo claro.
          builder: (context, child) {
            final dark = Theme.of(context).brightness == Brightness.dark;
            return AnnotatedRegion<SystemUiOverlayStyle>(
              value: (dark
                      ? SystemUiOverlayStyle.light
                      : SystemUiOverlayStyle.dark)
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
              ? AppShell(
                  onLogout: () {
                    // Sair é real: a sessão do GoTrue acaba e o token deixa
                    // de valer. O painel volta ao login.
                    _auth?.signOut();
                    setState(() {
                      _signedIn = false;
                      _partner.loadMe();
                    });
                  },
                )
              : _apresentou
                  ? LoginScreen(
                      auth: _auth,
                      onDone: () => setState(() => _signedIn = true),
                    )
                  : ApresentacaoScreen(
                      onDone: () => setState(() => _apresentou = true),
                    ),
          routes: {
            '/onboarding': (_) => const OnboardingScreen(),
            '/oferta': (_) => const OfertaScreen(),
            '/em-corrida': (_) => const EmCorridaScreen(),
            '/passe': (_) => const PasseScreen(),
            '/carteira': (_) => const CarteiraScreen(),
            '/desempenho': (_) => const DesempenhoScreen(),
            '/configurar-solicitacoes': (_) =>
                const ConfigurarSolicitacoesScreen(),
            '/status-solicitacao': (_) => const StatusSolicitacaoScreen(),
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

/// InheritedNotifier: telas escutam o PartnerController sem package extra.
class AppScope extends InheritedNotifier<PartnerController> {
  const AppScope({
    super.key,
    required PartnerController partner,
    required this.api,
    required super.child,
  }) : super(notifier: partner);

  final ApiClient api;

  static PartnerController of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;

  static ApiClient apiOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!.api;
}