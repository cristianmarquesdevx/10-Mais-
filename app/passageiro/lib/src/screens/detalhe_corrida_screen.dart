import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../api/client.dart';
import '../api/route_service.dart';
import '../theme/theme.dart';
import '../widgets/route_map.dart';
import 'destino_screen.dart';

/// Detalhes de uma corrida do histórico: rota, valores e status.
///
/// Recebe o [Ride] já carregado pela lista — o histórico do contrato não tem
/// um `GET /rides/{id}/receipt`, então a tela não inventa uma chamada nova;
/// ela mostra o snapshot que o servidor mandou, incluindo o `distance_km`
/// congelado no pedido (o mesmo do card, da oferta e do recibo).
class DetalheCorridaScreen extends StatelessWidget {
  const DetalheCorridaScreen({super.key, required this.ride});

  final Ride ride;

  static String _pagamento(String s) => switch (s) {
        'NOT_DUE' => 'Não cobrado',
        'PENDING' => 'Pendente',
        'CONFIRMED' => 'Confirmado',
        'FAILED' => 'Falhou',
        'REFUNDED' => 'Estornado',
        _ => s,
      };

  /// Volta para a tela de destino com o mesmo destino já escolhido: o mapa, a
  /// rota e a cotação do momento se refazem para a corrida nova — a antiga é
  /// só o atalho, não o preço.
  void _repetir(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => DestinoScreen(
          initialDestination: ride.destination,
          initialLabel: ride.destinationAddress,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final o = ride.origin;
    final d = ride.destination;
    final km = ride.distanceKm;
    final cor = ride.status.isCancelled
        ? AppColors.danger
        : ride.status == RideStatus.finalizada
            ? AppColors.earn
            : AppColors.primary;

    return Scaffold(
      appBar: AppBar(title: const Text('Detalhes da corrida')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpace.l),
        children: [
          if (o != null && d != null) ...[
            RouteMap(
              origin: LatLng(o.lat, o.lon),
              destination: LatLng(d.lat, d.lon),
              height: 200,
            ),
            const SizedBox(height: AppSpace.l),
          ],
          Card(
            child: Column(children: [
              ListTile(
                leading: Icon(
                  ride.status.isCancelled
                      ? Icons.cancel_outlined
                      : Icons.local_taxi_outlined,
                  color: cor,
                ),
                title: Text(ride.status.label,
                    style: AppType.title.copyWith(color: cor)),
                subtitle: Text(ride.createdAtLabel),
              ),
              if (ride.originAddress != null)
                ListTile(
                  leading: const Icon(Icons.trip_origin,
                      size: 18, color: AppColors.muted),
                  title: const Text('Origem'),
                  subtitle: Text(ride.originAddress!),
                ),
              if (ride.destinationAddress != null)
                ListTile(
                  leading: const Icon(Icons.flag_outlined,
                      size: 18, color: AppColors.primary),
                  title: const Text('Destino'),
                  subtitle: Text(ride.destinationAddress!),
                ),
            ]),
          ),
          const SizedBox(height: AppSpace.l),
          Card(
            child: Column(children: [
              if (km != null)
                ListTile(
                  leading:
                      const Icon(Icons.route_outlined, color: AppColors.primary),
                  title: const Text('Distância'),
                  trailing: Text(RouteResult.kmLabel(km), style: AppType.label),
                ),
              ListTile(
                leading: const Icon(Icons.payments_outlined,
                    color: AppColors.primary),
                title: const Text('Total'),
                trailing: Text(
                  ride.fareTotal != null ? brl(ride.fareTotal!) : '—',
                  style: AppType.money,
                ),
              ),
              ListTile(
                leading: const Icon(Icons.verified_outlined,
                    color: AppColors.primary),
                title: const Text('Pagamento'),
                trailing: Text(_pagamento(ride.paymentStatus),
                    style: AppType.label),
              ),
              if (ride.partnerName != null)
                ListTile(
                  leading: const Icon(Icons.person_outline,
                      color: AppColors.primary),
                  title: const Text('Parceiro'),
                  subtitle: Text([
                    ride.partnerName!,
                    if (ride.partnerVehicle != null) ride.partnerVehicle!,
                    if (ride.partnerRating != null)
                      '★ ${ride.partnerRating!.toStringAsFixed(1)}',
                  ].join(' · ')),
                ),
            ]),
          ),
        ],
      ),
      // Sem coordenada não há como repetir: o pedido precisa do ponto no mapa.
      bottomNavigationBar: ride.destination == null
          ? null
          : SafeArea(
              top: false,
              child: Container(
                padding: const EdgeInsets.fromLTRB(
                    AppSpace.l, AppSpace.m, AppSpace.l, AppSpace.m),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  border: Border(
                      top: BorderSide(
                          color: AppColors.ink.withValues(alpha: 0.06))),
                ),
                child: FilledButton.icon(
                  onPressed: () => _repetir(context),
                  icon: const Icon(Icons.repeat_rounded),
                  label: const Text('Repetir viagem'),
                ),
              ),
            ),
    );
  }
}
