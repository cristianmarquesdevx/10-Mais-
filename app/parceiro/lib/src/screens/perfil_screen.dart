import 'package:flutter/material.dart';

import '../../main.dart';
import '../assets/app_assets.dart';
import '../theme/theme.dart';

/// Aba Perfil do shell: identidade do parceiro, estado do KYC e atalhos
/// (passe, carteira, documentos). "Sair da conta" devolve ao login via
/// onLogout — sem Sair aqui dentro para não depender do shell.
class PerfilScreen extends StatefulWidget {
  const PerfilScreen({super.key, required this.onLogout});

  final VoidCallback onLogout;

  @override
  State<PerfilScreen> createState() => _PerfilScreenState();
}

class _PerfilScreenState extends State<PerfilScreen> {
  // Tema
  ThemeModePref _themeMode = ThemeModePref.light;

  @override
  void initState() {
    super.initState();
    _loadTheme();
  }

  Future<void> _loadTheme() async {
    final mode = await ThemePrefs.getMode();
    if (mounted) setState(() => _themeMode = mode);
  }

  Future<void> _setTheme(ThemeModePref mode) async {
    await ThemePrefs.setMode(mode);
    // Avisa o app inteiro na hora (antes só valia ao reabrir).
    themeModeNotifier.value = mode;
    if (mounted) setState(() => _themeMode = mode);
  }

  @override
  Widget build(BuildContext context) {
    final p = AppScope.of(context);
    final info = p.me?.partner;
    final kyc = p.kycApproved;
    // Tokens adaptativos: o mesmo widget serve ao tema claro e ao escuro. Usar
    // AppColors.* (paleta clara) aqui pintava textos escuros sobre cards
    // escuros — foi o que deixou o Perfil ilegível.
    final t = tokensOf(context);

    return Scaffold(
      backgroundColor: t.background,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppSpace.l),
          children: [
            const Text('Perfil',
                style: TextStyle(fontSize: 25, fontWeight: FontWeight.w700)),
            const SizedBox(height: AppSpace.l),
            // identidade
            Container(
              padding: const EdgeInsets.all(AppSpace.l),
              decoration: BoxDecoration(
                color: t.graphite,
                borderRadius: BorderRadius.circular(AppSpace.radiusCard),
              ),
              child: Row(children: [
                CircleAvatar(
                  radius: 28,
                  backgroundColor: t.primary.withValues(alpha: 0.2),
                  child: Text('P',
                      style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w700,
                          color: t.primary)),
                ),
                const SizedBox(width: AppSpace.m),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Image.asset(
                          AppAssets.logoIcone,
                          height: 16,
                          errorBuilder: (_, __, ___) =>
                              const Icon(Icons.verified, size: 16),
                        ),
                        const SizedBox(width: 4),
                        Text('Parceiro',
                            style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                                color: t.onGraphite)),
                      ]),
                      const SizedBox(height: 2),
                      Text(
                        kyc ? 'Conta verificada' : 'KYC em análise',
                        style: TextStyle(
                            fontSize: 13,
                            color: kyc ? t.primary : const Color(0xFFFFB74D)),
                      ),
                    ],
                  ),
                ),
                Icon(
                  kyc ? Icons.verified : Icons.hourglass_top,
                  color: kyc ? t.primary : const Color(0xFFFFB74D),
                ),
              ]),
            ),
            const SizedBox(height: AppSpace.xl),
            // Tema
            _Section(
              title: 'Aparência',
              children: [
                RadioGroup<ThemeModePref>(
                  groupValue: _themeMode,
                  onChanged: (v) {
                    if (v != null) _setTheme(v);
                  },
                  child: Column(children: [
                    _themeTile(
                      icon: Icons.brightness_high,
                      title: 'Claro',
                      subtitle: 'Sempre em cores claras',
                      value: ThemeModePref.light,
                      onChanged: _setTheme,
                    ),
                    const Divider(height: 1),
                    _themeTile(
                      icon: Icons.brightness_low,
                      title: 'Escuro',
                      subtitle: 'Sempre em cores escuras',
                      value: ThemeModePref.dark,
                      onChanged: _setTheme,
                    ),
                    const Divider(height: 1),
                    _themeTile(
                      icon: Icons.device_unknown,
                      title: 'Seguir o sistema',
                      subtitle: 'Usa a configuração do celular',
                      value: ThemeModePref.system,
                      onChanged: _setTheme,
                    ),
                  ]),
                ),
              ],
            ),
            const SizedBox(height: AppSpace.xl),
            _Section(
              title: 'Conta',
              children: [
                _entry(context, Icons.workspace_premium_outlined,
                    'Passe 10 é +', () => Navigator.pushNamed(context, '/passe')),
                _entry(context, Icons.account_balance_wallet_outlined,
                    'Carteira e saques',
                    () => Navigator.pushNamed(context, '/carteira')),
                _entry(context, Icons.badge_outlined, 'Cadastro e documentos',
                    () => Navigator.pushNamed(context, '/onboarding')),
                if (info != null)
                  _entry(context, Icons.star_outline, 'Avaliação: 5,0', () {}),
              ],
            ),
            const SizedBox(height: AppSpace.xl),
            // Preferências operacionais: o que o parceiro quer receber.
            _Section(
              title: 'Solicitações',
              children: [
                _entry(
                    context,
                    Icons.tune,
                    'Configurar solicitações',
                    () => Navigator.pushNamed(
                        context, '/configurar-solicitacoes')),
                _entry(
                    context,
                    Icons.monitor_heart_outlined,
                    'Teste de status',
                    () => Navigator.pushNamed(context, '/status-solicitacao')),
              ],
            ),
            const SizedBox(height: AppSpace.xl),
            // Raspadinha de Prêmios e convites (3.8)
            _Section(
              title: 'Ganhe mais',
              children: [
                _entry(context, Icons.card_giftcard, 'Raspadinha de prêmios',
                    () {
                  Navigator.pushNamed(context, '/scratch-campaigns');
                }),
                _entry(
                    context, Icons.person_add_alt_1_outlined,
                    'Convide motoristas', () {
                  Navigator.pushNamed(context, '/invite');
                }),
              ],
            ),
            const SizedBox(height: AppSpace.xl),
            _Section(
              title: 'Suporte',
              children: [
                _entry(context, Icons.support_agent, 'Falar com o suporte', () {
                  // Sem cor fixa: o SnackBar já usa onInverseSurface do tema.
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                      content: Text('Suporte: 0800 10 10 10')));
                }),
                _entry(context, Icons.description_outlined, 'Termos de uso',
                    () {}),
              ],
            ),
            const SizedBox(height: AppSpace.xl),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: t.danger,
                side: BorderSide(color: t.danger),
              ),
              onPressed: widget.onLogout,
              icon: const Icon(Icons.logout),
              label: const Text('SAIR DA CONTA'),
            ),
            const SizedBox(height: AppSpace.l),
          ],
        ),
      ),
    );
  }

  static Widget _entry(
    BuildContext context,
    IconData icon,
    String label,
    VoidCallback onTap,
  ) {
    final t = tokensOf(context);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: t.primary),
      title: Text(label, style: TextStyle(fontSize: 15, color: t.ink)),
      trailing: Icon(Icons.chevron_right, color: t.muted),
      onTap: onTap,
    );
  }

  static Widget _themeTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required ThemeModePref value,
    required ValueChanged<ThemeModePref> onChanged,
  }) {
    return ListTile(
      leading: Icon(icon, color: AppColors.primary),
      title: Text(title,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
      subtitle: Text(subtitle, style: const TextStyle(fontSize: 13)),
      // O RadioGroup acima é quem agrupa/seleciona.
      trailing: Radio<ThemeModePref>(
        value: value,
        activeColor: AppColors.primary,
      ),
      onTap: () => onChanged(value),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title.toUpperCase(),
            style: TextStyle(
                fontSize: 12,
                letterSpacing: 1,
                color: t.muted,
                fontWeight: FontWeight.w600)),
        const SizedBox(height: AppSpace.s),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.l),
          decoration: BoxDecoration(
            // Card do tema (não graphite fixo): no claro fica claro, no escuro
            // fica escuro — e o texto sempre herda a cor do tema.
            color: t.surface,
            borderRadius: BorderRadius.circular(AppSpace.radiusCard),
            border: Border.all(color: t.hairline.withValues(alpha: 0.35)),
          ),
          child: Column(children: children),
        ),
      ],
    );
  }
}
