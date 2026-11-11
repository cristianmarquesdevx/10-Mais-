import 'package:flutter/material.dart';

import '../theme/theme.dart';

/// Nota flutuante sobre o mapa — o mesmo formato nas telas do passageiro
/// (busca e destino): uma etiqueta curta que explica o que o mapa mostra.
///
/// Fica sobre o mapa de propósito: o formulário (destino, preço, CTA) não
/// perde altura, e a informação continua visível enquanto o mapa está lá.
class MapNote extends StatelessWidget {
  const MapNote({
    super.key,
    required this.icon,
    required this.text,
    this.alert = false,
  });

  final IconData icon;
  final String text;

  /// Destaca a nota (aviso: radar fora do ar, nenhum motorista perto).
  final bool alert;

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    return Container(
      constraints: const BoxConstraints(maxWidth: 240),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: t.surface.withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(AppSpace.radiusChip),
        border: Border.all(color: t.hairline.withValues(alpha: 0.35)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.10),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 14, color: alert ? t.warning : t.primary),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: t.ink,
            ),
          ),
        ),
      ]),
    );
  }
}
