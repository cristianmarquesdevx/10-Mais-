import 'package:flutter/material.dart';

/// Crédito do OpenStreetMap no canto do mapa.
///
/// A política de tiles do OSM exige o crédito visível. O MapLibre vem com
/// `attributionEnabled: false` (o botão nativo cobriria o mapa) e o
/// `flutter_map` mostra o crédito num widget próprio — por isso o mapa
/// compartilhado desenha o seu, igual nos dois backends.
class MapAttribution extends StatelessWidget {
  const MapAttribution(
      {super.key, this.label = '© OpenStreetMap · OpenFreeMap'});

  /// Texto do crédito (o fallback raster cita só o OSM).
  final String label;

  @override
  Widget build(BuildContext context) => Positioned(
        right: 6,
        bottom: 4,
        child: IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: const Color(0x990B1220),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              child: Text(
                label,
                style: const TextStyle(fontSize: 9, color: Colors.white70),
              ),
            ),
          ),
        ),
      );
}
