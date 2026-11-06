import 'package:flutter/material.dart';

import '../theme/theme.dart';

/// Cartão flutuante com o saldo da carteira do motorista.
///
/// Fica sobre o mapa, no topo à direita. O valor é sempre do servidor e é
/// lido continuamente enquanto a tela está aberta (ver
/// `PartnerController.startWalletLive`).
///
/// Estados:
/// - **carregando**: shimmer no lugar do valor — nunca o traço "—";
/// - **sem conexão / erro**: mostra o último valor conhecido com um aviso
///   discreto (ícone + horário da última leitura);
/// - **ok**: valor em negrito com números tabulares e uma contagem curta
///   quando ele muda.
///
/// Toque no cartão abre a Carteira. O ícone de olho oculta o valor
/// (privacidade do motorista na rua).
class WalletBalanceCard extends StatefulWidget {
  const WalletBalanceCard({
    super.key,
    required this.balance,
    required this.updatedAt,
    required this.loading,
    required this.stale,
    required this.onTap,
  });

  /// Último saldo conhecido (reais). Null = ainda não lido.
  final double? balance;

  /// Momento da última leitura bem-sucedida.
  final DateTime? updatedAt;

  /// Primeira carga em andamento.
  final bool loading;

  /// A última leitura falhou: o valor exibido é o último conhecido.
  final bool stale;

  /// Abre a Carteira.
  final VoidCallback onTap;

  @override
  State<WalletBalanceCard> createState() => _WalletBalanceCardState();
}

class _WalletBalanceCardState extends State<WalletBalanceCard> {
  bool _hidden = false;

  /// Rótulo para o leitor de tela: "Saldo da carteira: X reais".
  ///
  /// Inclui o estado de leitura quando o valor pode estar desatualizado — o
  /// motorista precisa saber se aquele número é de agora.
  String _semanticsLabel() {
    final v = widget.balance;
    if (v == null) {
      return widget.loading
          ? 'Saldo da carteira: carregando'
          : 'Saldo da carteira: indisponível';
    }
    if (_hidden) return 'Saldo da carteira: oculto';
    final txt = v.toStringAsFixed(2).replaceAll('.', ',');
    final base = 'Saldo da carteira: $txt reais';
    if (!widget.stale) return base;
    final at = widget.updatedAt;
    if (at == null) return '$base, possibly outdated';
    final hh = at.hour.toString().padLeft(2, '0');
    final mm = at.minute.toString().padLeft(2, '0');
    return '$base, last updated at $hh:$mm';
  }

  String _hint() {
    if (!widget.stale) return 'Carteira';
    final at = widget.updatedAt;
    if (at == null) return 'Sem conexão — o saldo pode estar desatualizado';
    final hh = at.hour.toString().padLeft(2, '0');
    final mm = at.minute.toString().padLeft(2, '0');
    return 'Sem conexão — último valor de $hh:$mm';
  }

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final value = widget.balance;

    return Tooltip(
      message: _hint(),
      // O texto do tooltip é redundância: o leitor de tela já recebe a
      // informação no rótulo do cartão.
      excludeFromSemantics: true,
      child: Semantics(
        // `explicitChildNodes`: o botão do olho precisa ser um nó próprio,
        // com o próprio rótulo. Sem isto, o rótulo dele é fundido no texto
        // do saldo e o leitor de tela anuncia um bloco só ("SALDO R$ 1.234,56
        // Ocultar saldo") — o botão fica sem nome.
        container: true,
        explicitChildNodes: true,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            // A semântica do toque vem do nó do saldo (abaixo); o InkWell
            // cuida só do gesto — senão o leitor de tela vê dois botões.
            excludeFromSemantics: true,
            onTap: widget.onTap,
            borderRadius: BorderRadius.circular(AppSpace.radiusSheet),
            child: Ink(
              padding: const EdgeInsets.fromLTRB(
                AppSpace.m,
                AppSpace.s,
                AppSpace.xs,
                AppSpace.s,
              ),
              decoration: BoxDecoration(
                color: t.surface.withValues(alpha: dark ? 0.88 : 0.95),
                borderRadius: BorderRadius.circular(AppSpace.radiusSheet),
                border: Border.all(
                  color: t.hairline.withValues(alpha: dark ? 0.45 : 0.30),
                ),
                boxShadow: dark ? appShadowDark() : appShadow,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // Nó do saldo: um botão só, com o valor por extenso.
                  Semantics(
                    button: true,
                    label: _semanticsLabel(),
                    onTap: widget.onTap,
                    child: ExcludeSemantics(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'SALDO',
                            style: AppType.caption.copyWith(
                              color: t.muted,
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1.4,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // Aviso discreto de leitura antiga: o valor
                              // continua visível, mas ninguém confunde com
                              // dado fresco.
                              if (widget.stale) ...[
                                Icon(
                                  Icons.cloud_off_rounded,
                                  size: 14,
                                  color: t.warning,
                                ),
                                const SizedBox(width: AppSpace.xs),
                              ],
                              if (widget.loading && value == null)
                                const _Shimmer(width: 96, height: 20)
                              else if (value == null)
                                // Erro sem nenhum valor conhecido: mostra o
                                // traço (nunca "R$ 0,00" — que seria mentira).
                                Text(
                                  '—',
                                  style: AppType.title.copyWith(
                                    color: t.muted,
                                    fontSize: 19,
                                    fontWeight: FontWeight.w800,
                                  ),
                                )
                              else
                                _MoneyText(value: value, hidden: _hidden),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpace.xs),
                  _EyeButton(
                    hidden: _hidden,
                    onToggle: () => setState(() => _hidden = !_hidden),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Valor do saldo: contagem curta quando muda, números tabulares para o
/// texto não "pular" de largura, e "••••" quando o motorista oculta.
class _MoneyText extends StatelessWidget {
  const _MoneyText({required this.value, required this.hidden});

  final double value;
  final bool hidden;

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final style = AppType.title.copyWith(
      color: t.ink,
      fontSize: 19,
      fontWeight: FontWeight.w800,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    if (hidden) return Text('••••', style: style);
    // `begin` e `end` iguais: o primeiro quadro já mostra o valor certo e a
    // animação só dispara quando o saldo muda.
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: value, end: value),
      duration:
          reduceMotion ? Duration.zero : const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
      builder: (context, v, _) => Text(brl(v), style: style),
    );
  }
}

/// Botão de olho: oculta/mostra o saldo (48 dp de alvo).
///
/// Nó de semântica próprio, com rótulo próprio: "Ocultar saldo" /
/// "Mostrar saldo".
class _EyeButton extends StatelessWidget {
  const _EyeButton({required this.hidden, required this.onToggle});

  final bool hidden;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    final label = hidden ? 'Mostrar saldo' : 'Ocultar saldo';
    return Semantics(
      button: true,
      label: label,
      child: Tooltip(
        message: label,
        // O rótulo já está no nó de semântica: não duplicar.
        excludeFromSemantics: true,
        child: InkWell(
          excludeFromSemantics: true,
          onTap: onToggle,
          customBorder: const CircleBorder(),
          child: SizedBox(
            width: AppSpace.target,
            height: AppSpace.target,
            child: Icon(
              hidden ? Icons.visibility_off_outlined : Icons.visibility_outlined,
              color: t.muted,
              size: 18,
            ),
          ),
        ),
      ),
    );
  }
}

/// Placeholder animado da primeira carga. Com "reduzir movimento" ligado ele
/// fica estático — o shimmer também é movimento.
class _Shimmer extends StatefulWidget {
  const _Shimmer({required this.width, required this.height});

  final double width;
  final double height;

  @override
  State<_Shimmer> createState() => _ShimmerState();
}

class _ShimmerState extends State<_Shimmer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _c.stop();
      _c.value = 0.35;
    } else if (!_c.isAnimating) {
      _c.repeat();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) => Container(
        width: widget.width,
        height: widget.height,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          gradient: LinearGradient(
            begin: Alignment(-1.6 + 3.2 * _c.value, 0),
            end: Alignment(-0.6 + 3.2 * _c.value, 0),
            colors: [
              t.hairline.withValues(alpha: 0.12),
              t.hairline.withValues(alpha: 0.35),
              t.hairline.withValues(alpha: 0.12),
            ],
          ),
        ),
      ),
    );
  }
}
