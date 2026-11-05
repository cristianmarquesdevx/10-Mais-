import 'package:flutter/material.dart';

import '../../assets/app_assets.dart';
import 'package:ten_design/ten_design.dart';

/// Carrossel de destaques exibido no login, abaixo da logo.
///
/// As artes promocionais são pôsteres verticais (4:5). Elas aparecem
/// inteiras — `BoxFit.contain` — em cartões com a mesma proporção, para
/// que nenhuma informação da campanha seja cortada nas bordas.
class CarouselDestaques extends StatefulWidget {
  const CarouselDestaques({super.key, this.items});

  /// Itens customizados (vindos do backend). Vazio usa a campanha padrão.
  final List<Map<String, dynamic>>? items;

  @override
  State<CarouselDestaques> createState() => _CarouselDestaquesState();
}

class _CarouselDestaquesState extends State<CarouselDestaques> {
  static final _items = AppAssets.carrosselLoginSlides
      .map((imagem) => <String, dynamic>{'imagem': imagem})
      .toList(growable: false);

  final _controller = PageController(viewportFraction: 0.56);
  int _page = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    final items = (widget.items?.isNotEmpty == true) ? widget.items! : _items;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: 232,
          child: PageView.builder(
            controller: _controller,
            itemCount: items.length,
            onPageChanged: (i) => setState(() => _page = i),
            itemBuilder: (context, index) {
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 5),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    // Fundo igual ao das artes: o letterbox do `contain`
                    // desaparece em vez de virar barras escuras no tema escuro.
                    color: const Color(0xFFF2FBF8),
                    borderRadius: BorderRadius.circular(AppSpace.radiusCard),
                    boxShadow: appShadow,
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(AppSpace.radiusCard),
                    child: Image.asset(
                      items[index]['imagem'] as String,
                      fit: BoxFit.contain,
                      width: double.infinity,
                      height: double.infinity,
                      errorBuilder: (_, __, ___) => Icon(
                        Icons.image_outlined,
                        color: t.muted,
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: AppSpace.s),
        // Indicador de página: mostra onde o usuário está na campanha.
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(items.length, (i) {
            final active = i == _page;
            return AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOut,
              margin: const EdgeInsets.symmetric(horizontal: 3),
              width: active ? 18 : 6,
              height: 6,
              decoration: BoxDecoration(
                color: active
                    ? t.primary
                    : t.hairline.withValues(alpha: 0.9),
                borderRadius: BorderRadius.circular(3),
              ),
            );
          }),
        ),
      ],
    );
  }
}
