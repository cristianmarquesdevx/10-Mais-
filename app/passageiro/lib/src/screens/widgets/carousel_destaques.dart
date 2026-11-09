import 'dart:async';

import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:flutter/material.dart';

import '../../assets/app_assets.dart';
import '../../theme/theme.dart';
import 'package:ten_design/ten_design.dart';

/// Carrossel de destaques do login (M4).
///
/// As artes são pôsteres 1080x1230, **sem logo** — a marca já aparece no topo
/// da tela. Elas aparecem inteiras (`BoxFit.contain`), sem cartão, sombra ou
/// moldura: o fundo da tela (degradê) é o fundo do carrossel.
///
/// Comportamento (M4):
/// - autoplay de 4 s com loop (volta ao primeiro no último);
/// - pausa enquanto o usuário está tocando e enquanto há campo focado;
/// - com `MediaQuery.disableAnimations` o avanço **continua** (o carrossel é
///   sempre automático); só a transição vira um salto instantâneo;
/// - `precacheImage` em todas as artes para não piscar na troca;
/// - `Semantics` com rótulo por arte.
///
/// A altura vem do pai (o login usa o espaço livre). Os indicadores ficam
/// fora do `PageView`, então não rolam junto com a arte.
class CarouselDestaques extends StatefulWidget {
  const CarouselDestaques({super.key, this.items = const []});

  /// Itens customizados (vindos do backend). Vazio usa a campanha padrão.
  final List<Map<String, dynamic>> items;

  @override
  State<CarouselDestaques> createState() => _CarouselDestaquesState();
}

class _CarouselDestaquesState extends State<CarouselDestaques>
    with WidgetsBindingObserver {
  static const _autoplayInterval = Duration(seconds: 4);
  static const _pageAnimation = Duration(milliseconds: 320);

  /// Rótulos das artes para o leitor de tela. As artes são imagens: sem
  /// `semanticLabel` o TalkBack só diz "imagem".
  static const _labels = <String, String>{
    '01_corrida_em_segundos': 'Sua corrida em segundos',
    '02_entrega_com_foto': 'Entrega com foto do pedido',
    '03_aviso_de_chegada': 'Aviso de chegada antes da coleta',
    '04_pague_do_seu_jeito': 'Pague do seu jeito',
    '05_ganhos_do_motorista': 'Mais ganhos para o motorista',
    '01_raspe_e_ganhe': 'Raspe e ganhe',
    '02_libere_raspadinhas': 'Libere novas raspadinhas',
    '03_raspe_com_o_dedo': 'Raspe com o dedo na tela',
    '04_muitos_premios': 'Muitos prêmios',
    '05_premio_na_conta': 'Prêmio direto na conta',
  };

  final _controller = PageController(viewportFraction: _viewportFraction);
  static const _viewportFraction = 0.78;
  static const _dotsHeight = 14.0;
  static const _dotSize = 6.0;
  Timer? _autoplay;
  int _page = 0;
  bool _reduceMotion = false;
  bool _touched = false;
  bool _fieldFocused = false;

  /// Escopo de foco da tela. Serve para saber qual nó está focado sem
  /// depender da árvore global de widgets (ver [_hasFocusedField]).
  FocusScopeNode? _scope;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    FocusManager.instance.addListener(_onFocusChange);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
    // O escopo de foco da tela: é daqui que sai o nó focado.
    _scope = FocusScope.of(context);
    // Estado inicial do foco: o carrossel pode nascer com o teclado aberto
    // (autofocus no login).
    _fieldFocused = _hasFocusedField();
    _precache();
    _syncAutoplay();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Em segundo plano o autoplay não tem efeito — e volta ao vivo ao retomar.
    if (state == AppLifecycleState.paused) {
      _autoplay?.cancel();
      _autoplay = null;
    } else {
      _syncAutoplay();
    }
  }

  @override
  void dispose() {
    _autoplay?.cancel();
    FocusManager.instance.removeListener(_onFocusChange);
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    super.dispose();
  }

  List<String> get _imagePaths {
    final items =
        widget.items.isNotEmpty ? widget.items : _defaultItems;
    return items
        .map((item) =>
            (item['imagem'] ?? item['imageUrl'] ?? '') as String)
        .toList(growable: false);
  }

  static final _defaultItems = AppAssets.carrosselLoginSlides
      .map((imagem) => <String, dynamic>{'imagem': imagem})
      .toList(growable: false);

  void _precache() {
    for (final path in _imagePaths) {
      precacheImage(AssetImage(path), context);
    }
  }

  /// Verdadeiro enquanto o foco está em um campo de texto da tela.
  ///
  /// O nó focado vem do [FocusScope] da tela — não do `FocusManager` global —
  /// e a árvore de widgets só é inspecionada quando o contexto do nó está
  /// ativo. Na troca de layout do login (teclado abre/fecha) o `TextField` é
  /// desativado por alguns instantes, e buscar um ancestral nesse contexto
  /// estoura "Looking up a deactivated widget's ancestor is unsafe"
  /// (regressão coberta por `login_ancestor_test.dart`).
  bool _hasFocusedField() {
    final focused = _scope?.focusedChild;
    if (focused == null) return false;
    final ctx = focused.context;
    if (ctx == null) return false;
    if (!kReleaseMode && ctx is Element && !ctx.debugIsActive) {
      // Contexto desativado: não dá para inspecionar a árvore com segurança.
      // O comportamento conservador é pausar o autoplay.
      return true;
    }
    // `TextField` constrói um `EditableText` — um dos dois basta.
    return ctx.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  void _onFocusChange() {
    final isTextField = _hasFocusedField();
    if (isTextField == _fieldFocused) return;
    if (!mounted) return;
    setState(() => _fieldFocused = isTextField);
    _syncAutoplay();
  }

  /// O carrossel é sempre automático (pedido do produto). Acessibilidade
  /// (`disableAnimations`) não desliga o avanço — só a transição, em [_next].
  bool get _canAutoplay =>
      !_touched && !_fieldFocused && _imagePaths.length > 1;

  void _syncAutoplay() {
    if (_canAutoplay) {
      _autoplay ??= Timer.periodic(_autoplayInterval, (_) => _next());
    } else {
      _autoplay?.cancel();
      _autoplay = null;
    }
  }

  void _next() {
    if (!mounted) return;
    if (_page >= _imagePaths.length - 1) {
      // Loop: volta ao primeiro sem animar para trás por todas as páginas.
      _controller.jumpToPage(0);
      return;
    }
    // Acessibilidade: o avanço continua, mas sem transição animada.
    if (_reduceMotion) {
      _controller.jumpToPage(_page + 1);
      return;
    }
    _controller.nextPage(
      duration: _pageAnimation,
      curve: Curves.easeOutCubic,
    );
  }

  String _labelFor(String path) {
    final stem = path.split('/').last.replaceAll(RegExp(r'\.\w+$'), '');
    return _labels[stem] ?? stem.replaceAll('_', ' ');
  }

  void _onPointerDown(PointerDownEvent _) {
    if (_touched) return;
    setState(() => _touched = true);
    _syncAutoplay();
  }

  void _onPointerEnd(PointerEvent _) {
    if (!_touched) return;
    setState(() => _touched = false);
    _syncAutoplay();
  }

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final paths = _imagePaths;

    if (paths.isEmpty) return const SizedBox.shrink();

    return Semantics(
      container: true,
      label: 'Destaques do 10 é Mais',
      child: Listener(
        // Toque/drag pausa o autoplay; soltar volta a rodar.
        onPointerDown: _onPointerDown,
        onPointerUp: _onPointerEnd,
        onPointerCancel: _onPointerEnd,
        child: LayoutBuilder(
          builder: (context, constraints) {
            // A arte é um pôster 1080x1230 dentro de uma página que mostra
            // 78% da largura, com 6 px de folga lateral.
            final pageWidth = constraints.maxWidth * _viewportFraction;
            final artWidth = (pageWidth - 12).clamp(0.0, double.infinity);
            final artHeight = artWidth * (1230 / 1080);
            // Faixa reservada embaixo para os indicadores de página.
            final pageAreaHeight =
                (constraints.maxHeight - _dotsHeight)
                    .clamp(0.0, double.infinity);
            // A arte é centralizada na página: a sobra fica metade em cima e
            // metade embaixo. Os indicadores acompanham a borda inferior da
            // arte, em vez de flutuar soltos colados no cartão de login.
            final shownArtHeight =
                artHeight < pageAreaHeight ? artHeight : pageAreaHeight;
            final slack = (pageAreaHeight - shownArtHeight) / 2;

            return Stack(
              fit: StackFit.expand,
              children: [
                Positioned.fill(
                  bottom: _dotsHeight,
                  child: PageView.builder(
                    controller: _controller,
                    itemCount: paths.length,
                    onPageChanged: (i) => setState(() => _page = i),
                    itemBuilder: (context, index) {
                      final path = paths[index];
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        child: Center(
                          child: AspectRatio(
                            aspectRatio: 1080 / 1230,
                            child: ColoredBox(
                              // No tema escuro a arte clara precisa de um fundo
                              // claro; no claro o degradê da tela já é o fundo.
                              color: dark
                                  ? const Color(0xFFF2FBF8)
                                  : Colors.transparent,
                              child: Image.asset(
                                path,
                                fit: BoxFit.contain,
                                filterQuality: FilterQuality.medium,
                                semanticLabel: _labelFor(path),
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
                // Com um único pôster não há paginação: o ponto solitário só
                // sugere que falta carregar algo.
                if (paths.length > 1)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: slack + (_dotsHeight - _dotSize),
                    child: Semantics(
                      // `container` impede o rótulo de fundir com o do carrossel.
                      container: true,
                      label: 'Página ${_page + 1} de ${paths.length}',
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: List.generate(paths.length, (i) {
                          final active = i == _page;
                          return AnimatedContainer(
                            duration: _reduceMotion
                                ? Duration.zero
                                : const Duration(milliseconds: 220),
                            curve: Curves.easeOut,
                            margin: const EdgeInsets.symmetric(horizontal: 3),
                            width: active ? 18 : _dotSize,
                            height: _dotSize,
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
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}
