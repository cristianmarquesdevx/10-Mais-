import 'package:flutter/material.dart';

import '../../main.dart';
import '../theme/theme.dart';

/// C11 SOS (bottom sheet) — 1 toque, contexto da corrida embutido, SLA 2 min.
/// Offline → avisa que precisa de rede (F8: sem rede, 192/190+SMS).
Future<void> showSosSheet(BuildContext context) => showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(AppSpace.radiusSheet)),
      ),
      builder: (context) => const _SosSheet(),
    );

class _SosSheet extends StatelessWidget {
  const _SosSheet();

  @override
  Widget build(BuildContext context) {
    final ride = AppScope.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.l),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Row(children: [
              Icon(Icons.emergency, color: AppColors.danger),
              SizedBox(width: AppSpace.s),
              Text('Emergência', style: AppType.title),
            ]),
            const SizedBox(height: AppSpace.m),
            const Text(
              'Aciona o suporte com sua localização e a corrida atual. '
              'Resposta em até 2 minutos.',
              style: AppType.label,
            ),
            const SizedBox(height: AppSpace.xl),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
              onPressed: ride.busy
                  ? null
                  : () async {
                      await ride.sos();
                      if (context.mounted) {
                        Navigator.pop(context);
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text(ride.lastErrorCode == null
                              ? 'Suporte acionado. Estamos chegando.'
                              : 'Sem rede — ligue 192 (Polícia) ou 190 (Bombeiro)'),
                        ));
                      }
                    },
              child: const Text('PEDIR AJUDA AGORA'),
            ),
            const SizedBox(height: AppSpace.m),
            OutlinedButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Voltar'),
            ),
          ],
        ),
      ),
    );
  }
}
