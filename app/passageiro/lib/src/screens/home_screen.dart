import 'package:flutter/material.dart';

import '../../main.dart';
import '../theme/theme.dart';
import '../widgets/city_map.dart';
import 'sos_sheet.dart';

/// C1 Home — mapa full-screen + bottom nav (ADX-UX-1), CTA no terço inferior.
///
/// Sem "calor de chamadas": essa camada é exclusiva do app do parceiro
/// (furo de mercado — o passageiro nunca vê a demanda agregada). Aqui o
/// mapa mostra só a localização do usuário (ponto de troca do MapProvider — R1).
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final ride = AppScope.of(context);
    final cached = ride.ride;
    // Só corrida ABERTA vira card; cache terminal (FINALIZADA etc.) não.
    final active = cached != null && cached.status.isOpen ? cached : null;
    return Scaffold(
      body: Stack(
        children: [
          const CityMap(), // R1: MapProvider entra no módulo de mapas
          SafeArea(
            child: Column(
              children: [
                const _TopBar(),
                const Spacer(),
                if (active != null) _ActiveRideCard(rideId: active.rideId),
                _BottomActions(
                    onHistory: () =>
                        Navigator.pushNamed(context, '/historico')),
              ],
            ),
          ),
        ],
      ),
      floatingActionButton: null,
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar();

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.all(AppSpace.l),
      child: Row(
        children: [
          // Mapa do passageiro é claro (OSM padrão): a marca usa a versão
          // com texto escuro, dentro de uma pill — a arte tem fundo branco
          // e, solta, virava um retângulo de cantos retos sobre o mapa.
          Container(
            padding: const EdgeInsets.fromLTRB(AppSpace.s, 6, AppSpace.m, 6),
            decoration: BoxDecoration(
              color: t.surface,
              borderRadius: BorderRadius.circular(AppSpace.radiusChip),
              boxShadow: dark ? appShadowDark() : appShadow,
            ),
            child: Image.asset(
              dark
                  ? 'assets/10-e-mais-logos/png/logo_branco.png'
                  : 'assets/10-e-mais-logos/png/logo_transparente.png',
              height: 28,
              errorBuilder: (_, __, ___) =>
                  Icon(Icons.verified, color: t.primary, size: 22),
            ),
          ),
          const Spacer(),
          IconButton.filledTonal(
            icon: const Icon(Icons.person_outline),
            tooltip: 'Perfil',
            onPressed: () => Navigator.pushNamed(context, '/perfil'),
            style: IconButton.styleFrom(
              backgroundColor: t.primary,
              foregroundColor: t.ink,
            ),
          ),
        ],
      ),
    );
  }
}

class _ActiveRideCard extends StatelessWidget {
  const _ActiveRideCard({required this.rideId});
  final String rideId;
  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      margin:
          const EdgeInsets.fromLTRB(AppSpace.l, 0, AppSpace.l, AppSpace.s),
      padding: const EdgeInsets.all(AppSpace.l),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(AppSpace.radiusSheet),
        boxShadow: dark ? appShadowDark() : appShadow,
      ),
      child: Row(children: [
        Icon(Icons.local_taxi, color: t.primary),
        const SizedBox(width: AppSpace.m),
        const Expanded(child: Text('Corrida em andamento')),
        FilledButton(
          // O tema deixa o FilledButton com largura infinita; dentro de uma
          // Row isso esmaga o texto do card — aqui a largura é explícita.
          style: FilledButton.styleFrom(
            minimumSize: const Size(84, 44),
            padding: const EdgeInsets.symmetric(horizontal: AppSpace.l),
            backgroundColor: t.primary,
            foregroundColor: t.ink,
          ),
          onPressed: () => Navigator.pushNamed(context, '/acompanhar'),
          child: const Text('Ver'),
        ),
      ]),
    );
  }
}

class _BottomActions extends StatelessWidget {
  const _BottomActions({required this.onHistory});
  final VoidCallback onHistory;
  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: EdgeInsets.fromLTRB(AppSpace.l, AppSpace.l, AppSpace.l,
          AppSpace.xl + MediaQuery.of(context).padding.bottom),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: const BorderRadius.vertical(
            top: Radius.circular(AppSpace.radiusSheet)),
        boxShadow: dark ? appShadowDark() : appShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GradientButton(
            onPressed: () => Navigator.pushNamed(context, '/destino'),
            child: const Text('Para onde?'),
          ),
          const SizedBox(height: AppSpace.m),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: onHistory,
                  icon: const Icon(Icons.history),
                  label: const Text('Histórico'),
                ),
              ),
              const SizedBox(width: AppSpace.m),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => showSosSheet(context),
                  // `Icons.emergency` desenha um asterisco e o botão
                  // parecia um erro de digitação; escudo lê como segurança.
                  icon: Icon(Icons.gpp_maybe_outlined, color: t.danger),
                  label: Text('SOS',
                      style: TextStyle(
                          color: t.danger,
                          fontWeight: FontWeight.w700)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
