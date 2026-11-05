import 'package:flutter/material.dart';

import 'package:ten_design/ten_design.dart';

/// Carrossel de campanhas rapaspadinha exibido acima da lista de campanhas.
///
/// As artes são pôsteres verticais (4:5): cada cartão mantém essa proporção e
/// usa `BoxFit.contain`, então a campanha aparece inteira — sem corte.
class CarouselRapaspadinha extends StatelessWidget {
  final List<Map<String, dynamic>> campaigns;
  const CarouselRapaspadinha({super.key, required this.campaigns});

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);

    if (campaigns.isEmpty) {
      return _buildLoadingState(context, t);
    }

    final items = campaigns.take(3).toList();

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: 188,
          child: PageView.builder(
            controller: PageController(viewportFraction: 0.56),
            padEnds: true,
            itemCount: items.length,
            itemBuilder: (context, index) {
              final item = items[index];
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 5),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    // Fundo igual ao das artes: o letterbox do `contain`
                    // desaparece em vez de virar barras escuras.
                    color: const Color(0xFFF2FBF8),
                    borderRadius: BorderRadius.circular(AppSpace.radiusCard),
                    boxShadow: appShadow,
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(AppSpace.radiusCard),
                    child: Image.asset(
                      (item['imagem'] ??
                          item['imageUrl'] ??
                          'assets/apresentacao/apresentacao.png') as String,
                      fit: BoxFit.contain,
                      width: double.infinity,
                      height: double.infinity,
                      errorBuilder: (_, __, ___) => Icon(
                        Icons.card_giftcard,
                        color: t.muted,
                        size: 32,
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: AppSpace.xs),
        Text(
          (items.first['name'] ?? items.first['titulo'] ?? 'Campanha') as String,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: AppType.label.copyWith(color: t.muted),
        ),
      ],
    );
  }

  Widget _buildLoadingState(BuildContext context, ColorSchemeColorTokens t) {
    return Container(
      height: 188,
      margin: const EdgeInsets.symmetric(horizontal: AppSpace.l),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(strokeWidth: 2),
            const SizedBox(height: AppSpace.s),
            Text('Carregando campanhas',
                style: AppType.label.copyWith(color: t.muted)),
          ],
        ),
      ),
    );
  }
}
