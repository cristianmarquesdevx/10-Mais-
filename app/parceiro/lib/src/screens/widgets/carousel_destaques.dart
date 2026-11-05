import 'package:flutter/material.dart';

import '../../assets/app_assets.dart';
import 'package:ten_design/ten_design.dart';

/// Carrossel de destaques exibido no login, abaixo da logo.
///
/// As artes promocionais são pôsteres verticais (1080x1350). Elas aparecem
/// inteiras — `BoxFit.contain` — sem cartão, sombra ou moldura: o fundo da
/// tela (degradê) é o fundo do carrossel.
///
/// A altura vem do pai (o login usa o espaço livre). Os indicadores ficam
/// fora do `PageView`, então não rolam junto com a arte.
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

  final _controller = PageController(viewportFraction: 0.78);
  int _page = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final items =
        (widget.items != null && widget.items!.isNotEmpty) ? widget.items! : _items;

    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(
          bottom: 14,
          child: PageView.builder(
            controller: _controller,
            itemCount: items.length,
            onPageChanged: (i) => setState(() => _page = i),
            itemBuilder: (context, index) {
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Center(
                  child: AspectRatio(
                    aspectRatio: 1080 / 1350,
                    child: ColoredBox(
                      // No tema escuro a arte clara precisa de um fundo claro
                      // retangular; no claro o degradê da tela já é o fundo.
                      color: dark ? const Color(0xFFF2FBF8) : Colors.transparent,
                      child: Image.asset(
                        items[index]['imagem'] as String,
                        fit: BoxFit.contain,
                        filterQuality: FilterQuality.medium,
                        errorBuilder: (_, __, ___) => Icon(
                          Icons.image_outlined,
                          color: t.muted,
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        // Indicador de página: ativo teal alongado, inativo cinza.
        Align(
          alignment: Alignment.bottomCenter,
          child: Row(
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
        ),
      ],
    );
  }
}
