import 'dart:async';

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../../main.dart';
import '../theme/theme.dart';
import '../widgets/record_audio_button.dart';
import '../widgets/route_map.dart';
import 'sos_sheet.dart';

/// C6 Em viagem (EM_VIAGEM) — timeline do trajeto, valor corrente, SOS.
/// Ao finalizar (poll/Realtime) navega para C7 pagamento — mesmo padrão da C4.
class ViagemScreen extends StatefulWidget {
  const ViagemScreen({super.key});

  @override
  State<ViagemScreen> createState() => _ViagemScreenState();
}

class _ViagemScreenState extends State<ViagemScreen> {
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return;
      final r = AppScope.of(context).ride;
      if (r == null || r.status.isCancelled) {
        Navigator.of(context).popUntil((route) => route.isFirst);
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
        appBar: AppBar(title: const Text('Em viagem')),
        body: const Center(child: Text('Nenhuma corrida ativa')),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Em viagem'),
        actions: [
          IconButton(
            tooltip: 'SOS',
            icon: const Icon(Icons.emergency, color: AppColors.danger),
            onPressed: () => showSosSheet(context),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(AppSpace.l),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(AppSpace.l),
                child: Column(children: [
                  if (r.fareTotal != null)
                    Text(brl(r.fareTotal!), style: AppType.display)
                  else
                    const Text('Valor aparece ao final', style: AppType.label),
                  const SizedBox(height: AppSpace.xs),
                  Text(
                    r.pricingMode == 'PASSE'
                        ? 'Passe ativo — 100% é do parceiro'
                        : 'Comissão 12%',
                    style: AppType.label.copyWith(
                        color: r.pricingMode == 'PASSE'
                            ? AppColors.earn
                            : AppColors.muted),
                  ),
                ]),
              ),
            ),
            const SizedBox(height: AppSpace.l),
            // Mapa do percurso: a moto anda na rota real conforme o servidor
            // reporta a posição (sem posição, o mapa ainda mostra o trajeto).
            if (r.origin != null && r.destination != null)
              RouteMap(
                origin: LatLng(r.origin!.lat, r.origin!.lon),
                destination: LatLng(r.destination!.lat, r.destination!.lon),
                driver: r.partnerPosition == null
                    ? null
                    : LatLng(r.partnerPosition!.lat, r.partnerPosition!.lon),
                height: 240,
                showHint: false,
              ),
            if (r.partnerRemainingKm != null)
              ListTile(
                leading: const Icon(Icons.route_outlined,
                    color: AppColors.primary),
                title: Text(
                    'Faltam ${r.partnerRemainingKm!.toStringAsFixed(1).replaceAll('.', ',')} km',
                    style: AppType.title),
                subtitle:
                    const Text('Percurso e ETA vêm do servidor, não do app'),
              ),
            const Spacer(),
            RecordAudioButton(
              rideId: r.rideId,
              upload: (
                  {required kind,
                  required durationMs,
                  required bytes,
                  required mime}) async {
                await AppScope.apiOf(context).uploadRecording(
                  rideId: r.rideId,
                  kind: kind,
                  durationMs: durationMs,
                  bytes: Uint8List.fromList(bytes),
                  mime: mime,
                );
              },
            ),
            const SizedBox(height: AppSpace.m),
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
          ],
        ),
      ),
    );
  }
}
