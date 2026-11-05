import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'src/api/client.dart';
import 'src/screens/screens.dart';
import 'src/state/ride_controller.dart';
import 'src/theme/theme.dart';

/// Ponto de entrada do 10 é + Passageiro.
///
/// Backend: Supabase Edge Functions sob /functions/v1/v1 (openapi.yaml).
/// A URL e o token vêm do ambiente de build — nunca hardcoded em release.
void main() {
  runApp(const PassageiroApp());
}

class PassageiroApp extends StatefulWidget {
  const PassageiroApp({super.key});

  @override
  State<PassageiroApp> createState() => _PassageiroAppState();
}

class _PassageiroAppState extends State<PassageiroApp> {
  late final ApiClient _api;
  late final RideController _ride;
  bool _signedIn = false; // P1: tela de apresentação/login antes da home

  @override
  void initState() {
    super.initState();
    const fromEnv = String.fromEnvironment('API_BASE',
        defaultValue: 'http://10.0.2.2:8787/functions/v1/v1');
    // Token real vem do fluxo de auth (OTP F1); placeholder para dev local.
    String token = const String.fromEnvironment('API_TOKEN', defaultValue: '');
    _api = ApiClient(baseUrl: fromEnv, accessToken: () => token);
    _ride = RideController(_api);
    _ride.refresh(); // corrida ativa ao abrir o app (deep link F4)
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