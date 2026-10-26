import 'dart:async';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../../main.dart';
import '../theme/theme.dart';
import '../widgets/route_map.dart';
import 'sos_sheet.dart';

/// C5 Acompanhar (ACEITA → A_CAMINHO → CHEGOU) — RideTimeline + card do
/// parceiro + compartilhar. ETA sempre do servidor.
/// Navega por mudança de fase (mesmo padrão da C4): em viagem → C6;
/// finalizada → C7 pagamento; cancelada → home.
class AcompanharScreen extends StatefulWidget {
  const AcompanharScreen({super.key});

  @override
  State<AcompanharScreen> createState() => _AcompanharScreenState();
}

class _AcompanharScreenState extends State<AcompanharScreen> {
  Timer? _t;

  static const _fases = ['aceita', 'aCaminho', 'chegou'];
  static const _rotulos = {
    'aceita': 'Parceiro a caminho',
    'aCaminho': 'A caminho do embarque',
    'chegou': 'Parceiro chegou',
  };

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return;
      final r = AppScope.of(context).ride;
      if (r == null || r.status.isCancelled) {
        Navigator.of(context).popUntil((route) => route.isFirst);
      } else if (r.status.name == 'emViagem') {
        Navigator.pushReplacementNamed(context, '/viagem');
      } else if (r.status.name == 'finalizada' ||
          r.status.name == 'falhaPagamento') {
        Navigator.pushReplacementNamed(context, '/pagamento');
      }
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ride = AppScope.of(context);
    final r = ride.ride;
    if (r == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Acompanhar')),
        body: const Center(child: Text('Nenhuma corrida ativa')),
      );
    }
    final idx = _fases.indexOf(r.status.name).clamp(0, 2);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Acompanhar'),
        actions: [
          // SOS é ação de segurança: rótulo escrito, não só um ícone.
          Padding(
            padding: const EdgeInsets.only(right: AppSpace.m),
            child: TextButton.icon(
              onPressed: () => showSosSheet(context),
              style: TextButton.styleFrom(
                foregroundColor: AppColors.danger,
                backgroundColor: AppColors.danger.withValues(alpha: 0.10),
                padding: const EdgeInsets.symmetric(
                    horizontal: AppSpace.m, vertical: AppSpace.xs),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppSpace.radiusChip)),
              ),
              icon: const Icon(Icons.emergency_share, size: 18),
              label: const Text('SOS',
                  style: TextStyle(fontWeight: FontWeight.w700)),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(AppSpace.l),
        children: [
          // Mapa real do trajeto: origem, destino e o traçado por ruas que o
          // parceiro vai seguir (os pins vêm do pedido, não de mock).
          if (r.origin != null && r.destination != null) ...[
            RouteMap(
              origin: LatLng(r.origin!.lat, r.origin!.lon),
              destination: LatLng(r.destination!.lat, r.destination!.lon),
              // Parceiro no percurso real: o ponto anda conforme o servidor
              // devolve o progresso (poll), e o mapa mostra a aproximação.
              driver: r.partnerPosition == null
                  ? null
                  : LatLng(r.partnerPosition!.lat, r.partnerPosition!.lon),
              height: 210,
              showHint: false,
            ),
            const SizedBox(height: AppSpace.l),
          ],
          if (r.fareTotal != null)
            Card(
              child: ListTile(
                leading:
                    const Icon(Icons.savings_outlined, color: AppColors.earn),
                title: Text('Valor da corrida: ${brl(r.fareTotal!)}',
                    style: AppType.title),
                subtitle: const Text('Congelado do valor do momento do pedido'),
              ),
            ),
          if (r.etaSeconds != null)
            Card(
              child: ListTile(
                leading:
                    const Icon(Icons.timer_outlined, color: AppColors.primary),
                title: Text('Chega em ${r.etaSeconds! ~/ 60} min',
                    style: AppType.title),
                subtitle: const Text('ETA calculado pelo servidor'),
              ),
            ),
          if (r.partnerRemainingKm != null)
            Card(
              child: ListTile(
                leading: const Icon(Icons.two_wheeler_outlined,
                    color: AppColors.primary),
                title: Text(
                    'Parceiro a ${r.partnerRemainingKm!.toStringAsFixed(1).replaceAll('.', ',')} km',
                    style: AppType.title),
                subtitle: const Text('Posição no percurso, atualizada a cada poll'),
              ),
            ),
          const SizedBox(height: AppSpace.l),
          // Linha do tempo só de leitura: sem `controlsBuilder` o Stepper
          // desenha os botões padrão do Material ("CONTINUE"/"CANCEL", em
          // inglês) e eles apareciam desabilitados no meio da tela.
          Stepper(
            currentStep: idx,
            controlsBuilder: (context, details) => const SizedBox.shrink(),
            steps: _fases
                .map((f) => Step(
                      title: Text(_rotulos[f]!),
                      isActive: _fases.indexOf(f) <= idx,
                      content: const SizedBox.shrink(),
                    ))
                .toList(),
          ),
          if (r.partnerName != null)
            Card(
              child: ListTile(
                leading: const CircleAvatar(child: Icon(Icons.person)),
                title: Text(r.partnerName!),
                subtitle: Text([
                  if (r.partnerRating != null)
                    '★ ${r.partnerRating!.toStringAsFixed(1)}',
                  if (r.partnerVehicle != null) r.partnerVehicle!,
                ].join(' · ')),
              ),
            ),
          const SizedBox(height: AppSpace.l),
          OutlinedButton.icon(
            onPressed: () async {
              final uri = await ride.share();
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text(uri?.toString() ??
                    'Link indisponível (${ride.lastErrorCode})'),
              ));
            },
            icon: const Icon(Icons.share_outlined),
            label: const Text('Compartilhar viagem'),
          ),
          const SizedBox(height: AppSpace.m),
          OutlinedButton(
            style: OutlinedButton.styleFrom(foregroundColor: AppColors.danger),
            onPressed: ride.busy
                ? null
                : () async {
                    await ride.cancel('ETA_TOO_HIGH');
                    if (context.mounted) {
                      Navigator.of(context).popUntil((r) => r.isFirst);
                    }
                  },
            child: const Text('Cancelar'),
          ),
        ],
      ),
    );
  }
}
