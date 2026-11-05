import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'src/api/client.dart';
import 'src/screens/screens.dart';
import 'src/state/partner_controller.dart';
import 'src/theme/theme.dart';

/// Ponto de entrada do 10 é + Parceiro.
///
/// Backend: Supabase Edge Functions sob /functions/v1/v1 (openapi.yaml).
/// A URL e o token vêm do ambiente de build — nunca hardcoded em release.
void main() {
  runApp(const ParceiroApp());
}

class ParceiroApp extends StatefulWidget {
  const ParceiroApp({super.key});

  @override
  State<ParceiroApp> createState() => _ParceiroAppState();
}

class _ParceiroAppState extends State<ParceiroApp> {
  late final ApiClient _api;
  late final PartnerController _partner;
  bool _signedIn = false; // P1: apresentação/login antes do shell
  bool _apresentou = false; // apresentação de abertura já exibida

  @override
  void initState() {
    super.initState();
    const fromEnv = String.fromEnvironment('API_BASE',
        defaultValue: 'http://10.0.2.2:8787/functions/v1/v1');
    // Token real vem do fluxo de auth (OTP F1); placeholder para dev local.
    String token = const String.fromEnvironment('API_TOKEN', defaultValue: '');
    _api = ApiClient(baseUrl: fromEnv, accessToken: () => token);
    _partner = PartnerController(_api);
    _partner.loadMe(); // perfil/KYC ao abrir (P1 gate: em análise ≠ online)
    // Mostra o login imediatamente para evitar tela branca durante o carregamento do tema.
    // O tema continua carregando em segundo plano.
    _loadTheme();
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
                  onLogout: () => setState(() {
                    _signedIn = false;
                    _partner.loadMe();
                  }),
                )
              : _apresentou
                  ? LoginScreen(
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