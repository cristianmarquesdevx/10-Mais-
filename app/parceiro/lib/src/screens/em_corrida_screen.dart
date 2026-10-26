import 'package:flutter/material.dart';

import '../../main.dart';
import '../api/client.dart';
import '../state/partner_controller.dart';
import '../theme/theme.dart';
import '../widgets/video_record_sheet.dart';
import 'navegacao_screen.dart';

/// P4 Em corrida — 3 fases (A_CAMINHO → CHEGOU → EM_VIAGEM → FINALIZADA),
/// transições só via POST /partner/transitions (0002: única via de domínio).
/// Navegação: deep link (MVP-A) — o ponto de troca do MapProvider fica no
/// botão "Navegar"; navegação embutida entra no MVP-B (R1).
/// P5 (confirmação de dinheiro) abre como sheet ao finalizar em COMISSÃO.
class EmCorridaScreen extends StatefulWidget {
  const EmCorridaScreen({super.key});

  @override
  State<EmCorridaScreen> createState() => _EmCorridaScreenState();
}

class _EmCorridaScreenState extends State<EmCorridaScreen> {
  bool _loaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loaded) {
      _loaded = true;
      // Corrida vem do aceite (P3); se a tela reabriu de um deep link sem
      // estado, volta ao painel (P2 decide por status).
      final p = AppScope.of(context);
      if (p.ride == null && p.status != PartnerStatus.emCorrida) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) Navigator.pop(context);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = AppScope.of(context);
    final ride = p.ride;
    if (ride == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final phase = switch (ride.status) {
      RideStatus.aceita => 0,
      RideStatus.aCaminho => 1,
      RideStatus.chegou => 2,
      RideStatus.emViagem => 3,
      _ => 3,
    };

    return PopScope(
      canPop: false, // em corrida não sai por acidente
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Em corrida'),
          automaticallyImplyLeading: false,
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpace.l),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(AppSpace.l),
                  child: _RideTimeline(phase: phase, ride: ride),
                ),
              ),
              const SizedBox(height: AppSpace.m),
              Card(
                child: Column(children: [
                  ListTile(
                    leading:
                        const Icon(Icons.my_location, color: AppColors.primary),
                    title: Text(ride.originAddress ?? 'Origem'),
                  ),
                  Divider(
                      height: 1,
                      indent: 16,
                      endIndent: 16,
                      color: Colors.grey.shade200),
                  ListTile(
                    leading:
                        const Icon(Icons.location_on, color: AppColors.earn),
                    title: Text(ride.destinationAddress ?? 'Destino'),
                  ),
                ]),
              ),
              const SizedBox(height: AppSpace.l),
              // presence_unconfigured é só um aviso de módulo opcional: a
              // presença do radar já vai pelo /partner/online desta corrida,
              // então não polui a tela com um código cru.
              if (p.lastErrorCode != null &&
                  p.lastErrorCode != 'presence_unconfigured')
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpace.m),
                  child: Text(
                    p.lastErrorCode == 'illegal_transition'
                        ? 'Estado mudou no servidor — atualizando.'
                        : 'Erro: ${p.lastErrorCode}',
                    style: const TextStyle(color: AppColors.danger),
                  ),
                ),
              OutlinedButton.icon(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const NavegacaoScreen()),
                ),
                icon: const Icon(Icons.navigation_outlined),
                label: const Text('Navegar'),
              ),
              const SizedBox(height: AppSpace.m),
              // Vídeo opcional da corrida (segurança) — câmera à escolha.
              OutlinedButton.icon(
                onPressed: () => showVideoRecordSheet(context, ride.rideId),
                icon: const Icon(Icons.videocam_outlined),
                label: const Text('Gravar vídeo (opcional)'),
              ),
              const SizedBox(height: AppSpace.m),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: AppColors.earn),
                onPressed: p.busy ? null : () => _advance(context, p, ride),
                child: Text(switch (phase) {
                  0 => 'A CAMINHO',
                  1 => 'CHEGUEI (raio 50 m)',
                  2 => 'INICIAR CORRIDA',
                  _ => 'FINALIZAR',
                }),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _advance(
      BuildContext context, PartnerController p, Ride ride) async {
    switch (ride.status) {
      case RideStatus.aceita:
        await p.transition(to: 'A_CAMINHO');
      case RideStatus.aCaminho:
        await p.transition(to: 'CHEGOU');
      case RideStatus.chegou:
        await p.transition(to: 'EM_VIAGEM');
      case RideStatus.emViagem:
        if (!context.mounted) return;
        final confirmed = await showDinheiroSheet(context, ride);
        if (confirmed == null) return; // sheet fechado sem confirmar
        await p.transition(
          to: 'FINALIZADA',
          fareTotal: confirmed.fare,
          cashDeclared: confirmed.cash,
        );
      default:
        break;
    }
    // Corrida finalizada (ou erro) → controller voltou a ONLINE; painel
    // reabre por navegação do próprio painel. Aqui só volta.
    if (!context.mounted) return;
    if (p.ride == null) Navigator.pop(context);
  }
}

class _RideTimeline extends StatelessWidget {
  const _RideTimeline({required this.phase, required this.ride});
  final int phase;
  final Ride ride;

  @override
  Widget build(BuildContext context) {
    const steps = [
      (Icons.person_search_outlined, 'A caminho do passageiro'),
      (Icons.flag_outlined, 'Cheguei ao ponto'),
      (Icons.directions_walk_outlined, 'Passageiro a bordo'),
      (Icons.payments_outlined, 'Finalizar e receber'),
    ];
    return Column(
      children: [
        for (var i = 0; i < steps.length; i++)
          ListTile(
            dense: true,
            leading: Icon(
              i <= phase ? Icons.check_circle : steps[i].$1,
              color: i == phase
                  ? AppColors.primary
                  : i < phase
                      ? AppColors.earn
                      : AppColors.hairline,
            ),
            title: Text(
              steps[i].$2,
              style: TextStyle(
                fontWeight: i == phase ? FontWeight.w700 : FontWeight.w400,
                color: i <= phase ? AppColors.ink : AppColors.muted,
              ),
            ),
            trailing: ride.pricingModeSnapshot == 'PASSE' && i == 3
                ? const Text('PASSE · 100% seu',
                    style: TextStyle(
                        color: AppColors.earn, fontWeight: FontWeight.w700))
                : null,
          ),
      ],
    );
  }
}

/// P5 Confirmação de dinheiro (ADR-003): o parceiro declara o valor recebido
/// em espécie; a comissão vira débito imediato da carteira (dita a dívida).
/// PIX/cartão não passam por aqui (split no PSP).
/// Devolve (fare, cash) para a tela em corrida aplicar a transição — o sheet
/// só coleta, nunca dispara mutação (evita corrida contra o pop).
Future<({double fare, bool cash})?> showDinheiroSheet(
    BuildContext context, Ride ride) {
  final controller = TextEditingController(
      text: (ride.fareTotal ?? ride.proposedAmount)?.toStringAsFixed(2) ?? '');
  return showModalBottomSheet<({double fare, bool cash})>(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(AppSpace.radiusSheet))),
    builder: (ctx) => Padding(
      padding: EdgeInsets.fromLTRB(
        AppSpace.l,
        AppSpace.l,
        AppSpace.l,
        MediaQuery.of(ctx).padding.bottom + AppSpace.l,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Confirmação de dinheiro', style: AppType.title),
          const SizedBox(height: AppSpace.s),
          const Text(
            'O passageiro pagou em dinheiro? Declare o valor recebido. '
            'Em COMISSÃO, a comissão é debitada da carteira agora (ADR-003).',
            style: AppType.label,
          ),
          const SizedBox(height: AppSpace.m),
          TextField(
            controller: controller,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
                labelText: 'Valor recebido (R\$)', prefixText: 'R\$ '),
          ),
          const SizedBox(height: AppSpace.m),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.earn),
            onPressed: () {
              final v = double.tryParse(controller.text.replaceAll(',', '.'));
              if (v == null) return; // contrato: fare_total obrigatório
              Navigator.of(ctx).pop((fare: v, cash: true));
            },
            child: const Text('CONFIRMEI O DINHEIRO'),
          ),
          const SizedBox(height: AppSpace.s),
          OutlinedButton(
            onPressed: () {
              final v = double.tryParse(controller.text.replaceAll(',', '.'));
              if (v == null) return; // contrato: fare_total obrigatório
              // Pagamento digital: split no PSP; só finaliza.
              Navigator.of(ctx).pop((fare: v, cash: false));
            },
            child: const Text('Pagamento digital (sem declarar)'),
          ),
        ],
      ),
    ),
  );
}
