import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../api/radar_api.dart';
import '../theme/theme.dart';

/// Camada de marcadores de motoristas próximos para o mapa do passageiro.
/// Exibe apenas motoristas ONLINE_DISPONIVEL dentro do raio de busca.
/// Posições são aproximadas (privacidade do parceiro — nunca endereço exato).
class DriverRadarLayer extends StatelessWidget {
  const DriverRadarLayer({
    super.key,
    required this.drivers,
    required this.userPosition,
  });

  final List<RadarDriver> drivers;
  final LatLng userPosition;

  @override
  Widget build(BuildContext context) {
    final markers = <Marker>[];

    // Marcador do passageiro (ponto de referência)
    markers.add(
      Marker(
        point: userPosition,
        width: 40,
        height: 40,
        child: const _UserRadarDot(),
      ),
    );

    // Marcadores dos motoristas disponíveis
    for (final d in drivers) {
      if (!d.available) continue;
      markers.add(
        Marker(
          point: LatLng(d.lat, d.lon),
          // A caixa precisa caber o pino + a etiqueta de distância: com
          // 34x34 o badge estourava o círculo (RenderFlex overflow).
          width: 56,
          height: 56,
          child: _DriverRadarPin(
            distanceKm: d.distanceKm,
            vehicle: d.vehicle,
          ),
        ),
      );
    }

    return MarkerLayer(markers: markers);
  }
}

/// Ponto do passageiro no radar (branco com anel verde pulsante).
class _UserRadarDot extends StatelessWidget {
  const _UserRadarDot();

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
          border: Border.all(color: AppColors.primary, width: 4),
          // Sombra curta: o desfoque é recalculado a cada movimento do mapa e
          // é caro em renderização por software (emulador). O anel colorido
          // já separa o ponto do mapa, então a sombra só dá profundidade.
          boxShadow: [
            BoxShadow(
                color: AppColors.primary.withValues(alpha: 0.5),
                blurRadius: 4,
                offset: const Offset(0, 1)),
          ],
        ),
      );
}

/// Pino do motorista no radar (branco com aro verde, ícone de carro).
class _DriverRadarPin extends StatelessWidget {
  const _DriverRadarPin({
    required this.distanceKm,
    required this.vehicle,
  });

  final double distanceKm;
  final String? vehicle;

  @override
  Widget build(BuildContext context) => FittedBox(
        // Fonte do sistema maior (acessibilidade) não pode estourar o pino:
        // o conjunto pino + etiqueta encolhe para caber na caixa do marcador.
        fit: BoxFit.scaleDown,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.primary, width: 2),
                boxShadow: [
                  BoxShadow(
                      color: Colors.black.withValues(alpha: 0.35),
                      blurRadius: 4,
                      offset: const Offset(0, 1)),
                ],
              ),
              child: const Icon(Icons.directions_car_rounded,
                  size: 16, color: AppColors.graphiteDeep),
            ),
            // Distância FORA do círculo: dentro dele o texto estourava o pino.
            if (distanceKm > 0)
              Container(
                margin: const EdgeInsets.only(top: 2),
                padding:
                    const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  color: AppColors.primary,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  '${distanceKm.toStringAsFixed(1)} km',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
          ],
        ),
      );
}
