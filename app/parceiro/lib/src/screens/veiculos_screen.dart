import 'package:flutter/material.dart';

import '../assets/app_assets.dart';
import '../theme/theme.dart';

/// Aba Veículos do shell: garagem do parceiro com os assets do kit
/// (`3_veiculos/carro.png`, `moto.png`). O backend real entra com
/// GET /partner/vehicles; aqui a lista é de demonstração.
class VeiculosScreen extends StatelessWidget {
  const VeiculosScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppSpace.l),
          children: [
            const Text('Meus veículos', style: AppType.title),
            const SizedBox(height: AppSpace.xs),
            const Text('A corrida sai sempre com o veículo selecionado.',
                style: AppType.label),
            const SizedBox(height: AppSpace.l),
            const _VehicleCard(
              name: 'Honda CG 160',
              plate: 'ABC-1234',
              kind: 'Moto · padrão',
              image: AppAssets.veiculoMoto,
              selected: true,
            ),
            const SizedBox(height: AppSpace.m),
            const _VehicleCard(
              name: 'Fiat Cronos',
              plate: 'DEF-5678',
              kind: 'Carro',
              image: AppAssets.veiculoCarro,
              selected: false,
            ),
            const SizedBox(height: AppSpace.xl),
            OutlinedButton.icon(
              onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                    content: Text('Cadastro de veículo chega na fase 3.')),
              ),
              icon: const Icon(Icons.add),
              label: const Text('ADICIONAR VEÍCULO'),
            ),
          ],
        ),
      ),
    );
  }
}

class _VehicleCard extends StatelessWidget {
  const _VehicleCard({
    required this.name,
    required this.plate,
    required this.kind,
    required this.image,
    required this.selected,
  });

  final String name, plate, kind, image;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: tokensOf(context).surface,
      borderRadius: BorderRadius.circular(AppSpace.radiusCard),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppSpace.radiusCard),
          border: Border.all(color: selected ? tokensOf(context).primary : tokensOf(context).ink.withValues(alpha: 0.08),
            width: selected ? 2 : 1,
          ),
        ),
        padding: const EdgeInsets.all(AppSpace.l),
        child: Row(children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(AppSpace.radiusCard),
            child: Image.asset(image,
                width: 84,
                height: 64,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) =>
                    const Icon(Icons.directions_car, size: 40)),
          ),
          const SizedBox(width: AppSpace.m),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Flexible(
                    child: Text(name,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontWeight: FontWeight.w700, fontSize: 16)),
                  ),
                  if (selected) ...[
                    const SizedBox(width: AppSpace.s),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: AppSpace.s, vertical: 2),
                      decoration: BoxDecoration(
                        color: tokensOf(context).primary.withValues(alpha: 0.15),
                        borderRadius:
                            BorderRadius.circular(AppSpace.radiusChip),
                      ),
                      child: const Text('PADRÃO',
                          style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: AppColors.earn)),
                    ),
                  ],
                ]),
                const SizedBox(height: 2),
                Text('$plate · $kind', style: AppType.label),
              ],
            ),
          ),
          Icon(
            selected
                ? Icons.radio_button_checked
                : Icons.radio_button_unchecked,
            color: selected ? tokensOf(context).primary : tokensOf(context).hairline,
          ),
        ]),
      ),
    );
  }
}
