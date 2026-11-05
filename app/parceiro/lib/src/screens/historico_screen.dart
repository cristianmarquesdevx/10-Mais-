import 'package:flutter/material.dart';

import '../../main.dart';
import '../api/client.dart';
import '../theme/theme.dart';

/// Aba Histórico do shell: corridas concluídas/canceladas do parceiro
/// (GET /rides filtrado pelo client). O backend real terá escopo por
/// parceiro (GET /partner/rides); o contrato de exibição é o mesmo.
class HistoricoScreen extends StatefulWidget {
  const HistoricoScreen({super.key});

  @override
  State<HistoricoScreen> createState() => _HistoricoScreenState();
}

class _HistoricoScreenState extends State<HistoricoScreen> {
  Future<List<Ride>>? _rides;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // AppScope usa dependência herdada — só pode ser lido aqui.
    _rides ??= AppScope.apiOf(context).myRides();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: tokensOf(context).background,
      body: SafeArea(
        child: FutureBuilder<List<Ride>>(
          future: _rides,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return Center(child: CircularProgressIndicator());
            }
            if (snap.hasError) {
              return Center(
                child: Padding(
                  padding: EdgeInsets.all(AppSpace.xl),
                  child: Text(
                      'Não consegui carregar o histórico — '
                      'tente de novo.',
                      textAlign: TextAlign.center,
                      style: AppType.label),
                ),
              );
            }
            final rides = snap.data ?? const <Ride>[];
            if (rides.isEmpty) {
              return Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.history, size: 48, color: tokensOf(context).hairline),
                    SizedBox(height: AppSpace.m),
                    Text('Suas corridas aparecem aqui', style: AppType.title),
                    SizedBox(height: AppSpace.xs),
                    Text('Fique online para receber chamadas.',
                        style: AppType.label),
                  ],
                ),
              );
            }
            return ListView.separated(
              padding: const EdgeInsets.all(AppSpace.l),
              itemCount: rides.length + 1,
              separatorBuilder: (_, __) => const SizedBox(height: AppSpace.m),
              itemBuilder: (context, i) {
                if (i == 0) {
                  return Text('Histórico de corridas',
                      style: AppType.title);
                }
                return _RideTile(ride: rides[i - 1]);
              },
            );
          },
        ),
      ),
    );
  }
}

class _RideTile extends StatelessWidget {
  const _RideTile({required this.ride});
  final Ride ride;

  @override
  Widget build(BuildContext context) {
    final done = ride.status == RideStatus.finalizada;
    final fare = ride.fareTotal ?? ride.proposedAmount;
    return Material(
      color: tokensOf(context).surface,
      borderRadius: BorderRadius.circular(AppSpace.radiusCard),
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.l),
        child: Row(children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: (done ? tokensOf(context).primary : tokensOf(context).hairline)
                  .withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: Icon(
              done ? Icons.check : Icons.close,
              color: done ? tokensOf(context).earn : tokensOf(context).muted,
            ),
          ),
          const SizedBox(width: AppSpace.m),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  ride.destinationAddress ?? ride.originAddress ?? 'Corrida',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 15),
                ),
                const SizedBox(height: 2),
                Text(
                  '${_statusLabel(ride.status)} · ${_dt(ride.createdAt)}',
                  style: AppType.label.copyWith(fontSize: 13),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpace.s),
          Text(
            fare != null ? brl(fare) : '—',
            style: AppType.money.copyWith(
                fontSize: 16, color: done ? tokensOf(context).ink : tokensOf(context).muted),
          ),
        ],
      ),
    ),
    );
  }

  static String _statusLabel(RideStatus s) => switch (s) {
        RideStatus.finalizada => 'Concluída',
        RideStatus.expirada => 'Expirada',
        RideStatus.canceladaCliente => 'Cancelada pelo passageiro',
        RideStatus.canceladaParceiro => 'Cancelada por você',
        RideStatus.canceladaSistema => 'Cancelada',
        RideStatus.canceladaSuporte => 'Cancelada pelo suporte',
        _ => 'Em curso',
      };

  static String _dt(DateTime? utc) {
    if (utc == null) return '';
    final d = utc.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(d.day)}/${two(d.month)} ${two(d.hour)}:${two(d.minute)}';
  }
}