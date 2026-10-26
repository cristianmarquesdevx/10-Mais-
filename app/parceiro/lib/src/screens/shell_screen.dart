import 'package:flutter/material.dart';

import '../../main.dart';
import '../state/partner_controller.dart';
import '../theme/theme.dart';
import 'screens.dart';

/// Shell do parceiro: menu hambúrguer (drawer) + navegação inferior
/// horizontal (Início / Veículos / Histórico / Perfil), conforme o kit
/// `2_navegacao/barra_navegacao.png`. Cada aba mantém o próprio estado
/// (IndexedStack); rotas de ação (passe, carteira, KYC, oferta, corrida)
/// continuam empilhando por cima do shell.
class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.onLogout});

  final VoidCallback onLogout;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final p = AppScope.of(context);
    final t = tokensOf(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      // Conteúdo escuro do kit nas abas que usam mapa; o IndexedStack
      // preserva rolagem/estado ao trocar de aba.
      body: Builder(
        builder: (ctx) => IndexedStack(
          index: _index,
          children: [
            PainelScreen(onMenu: () => Scaffold.of(ctx).openDrawer()),
            const VeiculosScreen(),
            const HistoricoScreen(),
            PerfilScreen(onLogout: widget.onLogout),
          ],
        ),
      ),
      drawer: _PartnerDrawer(partner: p, onLogout: widget.onLogout),
      // Com edge-to-edge o app desenha atrás da barra de gestos: sem o
      // SafeArea os rótulos das abas (Início/Veículos/Histórico/Perfil)
      // ficavam cortados pela borda inferior da tela.
      bottomNavigationBar: Container(
        // Barra do tema: clara no claro, grafite no escuro — e não mais uma
        // faixa escura fixa que destoava do painel claro.
        decoration: BoxDecoration(
          color: t.surface,
          border: Border(
              top: BorderSide(color: t.hairline.withValues(alpha: 0.25))),
        ),
        child: SafeArea(
          top: false,
          child: NavigationBar(
            selectedIndex: _index,
            onDestinationSelected: (i) => setState(() => _index = i),
            backgroundColor: Colors.transparent,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            indicatorColor: t.primary.withValues(alpha: 0.18),
            labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
            // Cores vindas dos tokens: sem isso os rótulos/ícones ficam
            // escuros sobre a barra escura (ou claros sobre a clara).
            labelTextStyle:
                WidgetStateProperty.resolveWith((states) => TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: states.contains(WidgetState.selected)
                          ? (dark ? t.primary : t.earn)
                          : t.muted,
                    )),
            destinations: [
              _navDestination(
                  Icons.home_outlined, Icons.home, 'Início', t, dark),
              _navDestination(Icons.directions_car_outlined,
                  Icons.directions_car, 'Veículos', t, dark),
              _navDestination(
                  Icons.history_outlined, Icons.history, 'Histórico', t, dark),
              _navDestination(
                  Icons.person_outline, Icons.person, 'Perfil', t, dark),
            ],
          ),
        ),
      ),
    );
  }
}

/// Destino da barra inferior com as cores do tema ativo (o NavigationBar
/// desta versão não expõe um iconTheme próprio).
NavigationDestination _navDestination(
  IconData icon,
  IconData selectedIcon,
  String label,
  ColorSchemeColorTokens t,
  bool dark,
) {
  final selected = dark ? t.primary : t.earn;
  return NavigationDestination(
    icon: Icon(icon, color: t.muted),
    selectedIcon: Icon(selectedIcon, color: selected),
    label: label,
  );
}

/// Menu hambúrguer: identidade + atalhos de conta (carteira, passe, KYC).
class _PartnerDrawer extends StatelessWidget {
  const _PartnerDrawer({required this.partner, required this.onLogout});

  final PartnerController partner;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    final kyc = partner.kycApproved;
    final t = tokensOf(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Drawer(
      backgroundColor: t.surface,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(AppSpace.xl),
              child: Row(children: [
                Image.asset(
                  dark
                      ? 'assets/logo/logo_branco.png'
                      : 'assets/logo/logo_claro_alpha.png',
                  height: 36,
                  errorBuilder: (_, __, ___) => Text('10 é +',
                      style: AppType.titleOnDark.copyWith(color: t.ink)),
                ),
                const SizedBox(width: AppSpace.m),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Parceiro 10 é +',
                          style: AppType.onDark.copyWith(color: t.ink)),
                      Text(
                        kyc ? 'Conta verificada' : 'KYC em análise',
                        style: AppType.label.copyWith(
                            color: kyc ? (dark ? t.primary : t.earn) : t.muted),
                      ),
                    ],
                  ),
                ),
              ]),
            ),
            Divider(color: t.hairline.withValues(alpha: 0.25), height: 1),
            _DrawerItem(
              icon: Icons.account_balance_wallet_outlined,
              label: 'Carteira e saques',
              onTap: () => Navigator.pushNamed(context, '/carteira'),
            ),
            _DrawerItem(
              icon: Icons.insights_outlined,
              label: 'Meu desempenho',
              onTap: () => Navigator.pushNamed(context, '/desempenho'),
            ),
            _DrawerItem(
              icon: Icons.workspace_premium_outlined,
              label: 'Passe 10 é +',
              onTap: () => Navigator.pushNamed(context, '/passe'),
            ),
            _DrawerItem(
              icon: Icons.badge_outlined,
              label: 'Cadastro e documentos',
              onTap: () => Navigator.pushNamed(context, '/onboarding'),
            ),
            const Spacer(),
            Divider(color: t.hairline.withValues(alpha: 0.25), height: 1),
            _DrawerItem(
              icon: Icons.logout,
              label: 'Sair da conta',
              onTap: onLogout,
            ),
            const SizedBox(height: AppSpace.m),
          ],
        ),
      ),
    );
  }
}

class _DrawerItem extends StatelessWidget {
  const _DrawerItem(
      {required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    return ListTile(
      leading: Icon(icon, color: t.muted),
      title: Text(label, style: AppType.onDark.copyWith(color: t.ink)),
      onTap: onTap,
    );
  }
}
