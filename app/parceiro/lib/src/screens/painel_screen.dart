import 'package:flutter/material.dart';

import '../../main.dart';
import '../api/client.dart';
import '../state/partner_controller.dart';
import '../theme/theme.dart';
import '../widgets/heatmap_map.dart';

/// P2 Painel — o mapa ocupa a tela inteira e os controles flutuam sobre ele
/// (ADX-UX-2). No topo ficam menu, marca, modo, status e zonas quentes; no
/// rodapé, um painel flutuante com passe, carteira e o CTA ONLINE/OFFLINE.
///
/// Oferta que chega durante ONLINE navega para P3; corrida ativa reabre P4.
/// KYC não aprovado (F9) dirige ao onboarding.
///
/// Pausa operacional (3.2): o motorista pode iniciar uma pausa de até 3h
/// (configurável) enquanto online. Durante a pausa, não recebe ofertas.
/// O servidor é a fonte oficial do horário de início/expiração (A7).
class PainelScreen extends StatefulWidget {
  const PainelScreen({super.key, this.onMenu});

  /// Abre o menu hambúrguer do shell; null quando a tela é isolada (testes).
  final VoidCallback? onMenu;

  @override
  State<PainelScreen> createState() => _PainelScreenState();
}

class _PainelScreenState extends State<PainelScreen> {
  bool _loaded = false;
  List<HeatZone> _zones = const [];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loaded) {
      _loaded = true;
      final p = AppScope.of(context);

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) p.loadMe();
      });
      _loadHeat();
    }
  }

  Future<void> _loadHeat() async {
    try {
      final zones = await AppScope.apiOf(context).heatmap();
      if (mounted) setState(() => _zones = zones);
    } catch (_) {
      // mapa continua sem calor — nunca bloqueia o painel
    }
  }

  String _formatSeconds(int total) {
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = total % 60;
    if (h > 0) {
      return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final p = AppScope.of(context);
    final info = p.me?.partner;
    final online = p.status == PartnerStatus.online;
    final emCorrida = p.status == PartnerStatus.emCorrida;

    // Oferta chegou (poll/Realtime) → P3. Corrida ativa → P4. Só navega
    // quando o painel é a rota atual (senão empilharia telas a cada rebuild).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (ModalRoute.of(context)?.isCurrent != true) return;
      if (emCorrida && p.ride != null) {
        Navigator.pushNamed(context, '/em-corrida');
      } else if (online && p.offers.isNotEmpty) {
        Navigator.pushNamed(context, '/oferta');
      }
    });

    return Scaffold(
      // Fundo do tema atrás do mapa (aparece se os tiles ainda não chegaram).
      backgroundColor: tokensOf(context).background,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Mapa de tela inteira, atrás de tudo. A atribuição do OSM é
          // repetida no painel flutuante, onde não fica coberta.
          HeatmapMap(zones: _zones, showAttribution: false),
          SafeArea(
            bottom: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // --- topo flutuante: menu + marca + modo ---
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                      AppSpace.l, AppSpace.s, AppSpace.l, 0),
                  child: Row(children: [
                    if (widget.onMenu != null)
                      _RoundGlassButton(
                        icon: Icons.menu_rounded,
                        tooltip: 'Menu',
                        onTap: widget.onMenu!,
                      )
                    else
                      const SizedBox(width: AppSpace.target),
                    const SizedBox(width: AppSpace.s),
                    const _BrandChip(),
                    const Spacer(),
                    _ModeChip(mode: p.mode),
                  ]),
                ),
                const SizedBox(height: AppSpace.s),
                // --- pills de status e calor sobre o mapa ---
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: AppSpace.l),
                  child: Row(children: [
                    _StatusPill(
                      status: p.status,
                      breakRemaining: p.breakRemainingSeconds,
                    ),
                    const Spacer(),
                    if (_zones.isNotEmpty) _HeatPill(count: _zones.length),
                  ]),
                ),
                const Spacer(),
                // --- avisos críticos (bloqueio/erro): flutuam acima do dock ---
                if (p.lastErrorCode != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                        AppSpace.l, 0, AppSpace.l, AppSpace.s),
                    child: _PainelError(code: p.lastErrorCode!),
                  ),
                if (p.me != null && !p.kycApproved)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                        AppSpace.l, 0, AppSpace.l, AppSpace.s),
                    child: _KycGate(
                        onTap: () =>
                            Navigator.pushNamed(context, '/onboarding')),
                  ),
                // --- painel de controle flutuante ---
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                      AppSpace.l, 0, AppSpace.l, AppSpace.m),
                  child: _ControlDock(
                    controller: p,
                    info: info,
                    formatSeconds: _formatSeconds,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Superfícies flutuantes: nítidas (fundo sólido do tema + sombra), discretas
// (borda fina, raio de chip e sombra curta) para não competir com o mapa.
// ---------------------------------------------------------------------------

BoxDecoration _floatingDecoration(BuildContext context,
    {double radius = AppSpace.radiusCard}) {
  final t = tokensOf(context);
  final dark = Theme.of(context).brightness == Brightness.dark;
  return BoxDecoration(
    color: t.surface,
    borderRadius: BorderRadius.circular(radius),
    border: Border.all(color: t.hairline.withValues(alpha: dark ? 0.45 : 0.30)),
    boxShadow: [
      BoxShadow(
        color: Colors.black.withValues(alpha: dark ? 0.38 : 0.14),
        blurRadius: 18,
        offset: const Offset(0, 6),
      ),
    ],
  );
}

/// Botão circular flutuante (menu).
class _RoundGlassButton extends StatelessWidget {
  const _RoundGlassButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        label: tooltip,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(AppSpace.radiusChip),
            child: Ink(
              width: AppSpace.target,
              height: AppSpace.target,
              decoration:
                  _floatingDecoration(context, radius: AppSpace.radiusChip),
              child: Icon(icon, size: 22, color: t.ink),
            ),
          ),
        ),
      ),
    );
  }
}

class _BrandChip extends StatelessWidget {
  const _BrandChip();

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    return Container(
      height: AppSpace.target,
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.m),
      decoration: _floatingDecoration(context, radius: AppSpace.radiusChip),
      child: Row(children: [
        Icon(Icons.add, size: 16, color: t.primary),
        const SizedBox(width: 4),
        Image.asset(
          'assets/10-e-mais-logos/png/logo_icone.png',
          height: 15,
          errorBuilder: (_, __, ___) => Icon(Icons.verified, size: 15, color: t.primary),
        ),
      ]),
    );
  }
}

class _ModeChip extends StatelessWidget {
  const _ModeChip({required this.mode});
  final String? mode;

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    final passe = mode == 'PASSE_ATIVO';
    return Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.m),
      alignment: Alignment.center,
      decoration: passe
          ? BoxDecoration(
              color: t.primary,
              borderRadius: BorderRadius.circular(AppSpace.radiusChip),
              boxShadow: [
                BoxShadow(
                    color: t.primary.withValues(alpha: 0.35),
                    blurRadius: 12,
                    offset: const Offset(0, 4)),
              ],
            )
          : _floatingDecoration(context, radius: AppSpace.radiusChip),
      child: Text(
        passe ? 'PASSE · 100% seu' : 'COMISSÃO 12%',
        style: TextStyle(
          fontWeight: FontWeight.w700,
          fontSize: 12,
          letterSpacing: 0.2,
          color: passe ? t.ink : t.muted,
        ),
      ),
    );
  }
}

/// Pill de status com 4 estados: OFFLINE / ONLINE / PAUSED / EM CORRIDA.
class _StatusPill extends StatelessWidget {
  const _StatusPill({
    required this.status,
    this.breakRemaining,
  });
  final PartnerStatus status;
  final int? breakRemaining;

  Color _dotColor(ColorSchemeColorTokens t) {
    switch (status) {
      case PartnerStatus.online:
        return t.primary;
      case PartnerStatus.paused:
        return t.warning;
      case PartnerStatus.emCorrida:
        return t.earn;
      case PartnerStatus.offline:
        return t.hairline;
    }
  }

  String _label(int? br) {
    switch (status) {
      case PartnerStatus.online:
        return 'ONLINE';
      case PartnerStatus.paused:
        return br != null ? 'PAUSA ${_mmss(br)}' : 'PAUSA';
      case PartnerStatus.emCorrida:
        return 'EM CORRIDA';
      case PartnerStatus.offline:
        return 'OFFLINE';
    }
  }

  String _mmss(int total) {
    final m = total ~/ 60;
    final s = total % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    final dot = _dotColor(t);
    final live = status != PartnerStatus.offline;
    return Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.m),
      decoration: _floatingDecoration(context, radius: AppSpace.radiusChip),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 9,
          height: 9,
          decoration: BoxDecoration(
            color: dot,
            shape: BoxShape.circle,
            boxShadow: live
                ? [
                    BoxShadow(
                        color: dot.withValues(alpha: 0.7),
                        blurRadius: 7,
                        spreadRadius: 1)
                  ]
                : null,
          ),
        ),
        const SizedBox(width: 7),
        Text(_label(breakRemaining),
            style: TextStyle(
                color: t.ink,
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6)),
      ]),
    );
  }
}

class _HeatPill extends StatelessWidget {
  const _HeatPill({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    return Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.m),
      decoration: _floatingDecoration(context, radius: AppSpace.radiusChip),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.local_fire_department, color: t.warning, size: 16),
        const SizedBox(width: 4),
        Text('$count zonas quentes',
            style: TextStyle(
                color: t.ink, fontSize: 12, fontWeight: FontWeight.w600)),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Rodapé flutuante: passe + carteira (toque abre), pausa e CTA.
// ---------------------------------------------------------------------------

class _ControlDock extends StatelessWidget {
  const _ControlDock({
    required this.controller,
    required this.info,
    required this.formatSeconds,
  });

  final PartnerController controller;
  final PartnerInfo? info;
  final String Function(int) formatSeconds;

  String _shortDate(DateTime d) {
    final local = d.toLocal();
    return '${local.day.toString().padLeft(2, '0')}/${local.month.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    final status = controller.status;
    final online = status == PartnerStatus.online;
    final paused = status == PartnerStatus.paused;
    final passExpires = info?.passExpiresAt;
    final passActive =
        passExpires != null && passExpires.isAfter(DateTime.now());
    final wallet = info?.walletBalance;
    final debtCents = info?.debtCents ?? 0;

    return Container(
      padding: const EdgeInsets.fromLTRB(
          AppSpace.m, AppSpace.s, AppSpace.m, AppSpace.m),
      decoration:
          _floatingDecoration(context, radius: AppSpace.radiusSheet + 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // --- duas informações tocáveis, em uma linha enxuta ---
          Row(children: [
            Expanded(
              child: _DockInfo(
                icon: passActive
                    ? Icons.workspace_premium
                    : Icons.workspace_premium_outlined,
                iconColor: passActive ? t.primary : t.muted,
                title: passActive ? 'Passe ativo' : 'Sem passe',
                subtitle: passActive
                    ? 'vence ${_shortDate(passExpires)}'
                    : 'COMISSÃO 12%',
                onTap: () => Navigator.pushNamed(context, '/passe'),
              ),
            ),
            Container(
              width: 1,
              height: 36,
              color: t.hairline.withValues(alpha: 0.35),
            ),
            Expanded(
              child: _DockInfo(
                icon: Icons.account_balance_wallet_outlined,
                iconColor: t.primary,
                title: 'Carteira: ${wallet != null ? brl(wallet) : '—'}',
                subtitle: debtCents > 0
                    ? 'Dívida ${brl(debtCents / 100)}'
                    : 'Saque PIX',
                subtitleColor: debtCents > 0 ? t.warning : null,
                onTap: () => Navigator.pushNamed(context, '/carteira'),
              ),
            ),
          ]),
          const SizedBox(height: AppSpace.m),
          // --- pausa (quando online) + CTA principal ---
          Row(children: [
            if (online) ...[
              _PauseButton(
                onTap: controller.busy ? null : controller.startBreak,
                remaining: paused ? controller.breakRemainingSeconds : null,
                formatSeconds: formatSeconds,
              ),
              const SizedBox(width: AppSpace.s),
            ],
            Expanded(
              child: GradientButton(
                gradient: paused
                    ? AppGradients.warn
                    : (online ? AppGradients.earn : AppGradients.primary),
                // Os gradientes escuros (earn/warn) pedem texto claro; o verde
                // claro de "FICAR ONLINE" mantém a tinta escura do tema.
                foregroundColor:
                    (online || paused) ? Colors.white : AppColors.ink,
                onPressed: controller.busy
                    ? null
                    : () async {
                        if (online || paused) {
                          if (paused) {
                            await controller.endBreak();
                          } else {
                            await controller.goOffline();
                          }
                        } else {
                          // O controller busca a posição real (injetável em
                          // teste) e publica a presença do radar.
                          await controller.goOnline();
                          if (controller.lastErrorCode == 'kyc_not_approved' &&
                              context.mounted) {
                            Navigator.pushNamed(context, '/onboarding');
                          }
                        }
                      },
                child: Text(
                  paused
                      ? 'ENCERRAR PAUSA'
                      : online
                          ? 'FICAR OFFLINE'
                          : 'FICAR ONLINE',
                ),
              ),
            ),
          ]),
          const SizedBox(height: 6),
          Row(children: [
            Icon(Icons.copyright, size: 10, color: t.hairline),
            const SizedBox(width: 3),
            Expanded(
              child: Text(
                'OpenStreetMap contributors',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 10, color: t.muted),
              ),
            ),
            Text('relógio do servidor (A7)',
                style: TextStyle(fontSize: 10, color: t.muted)),
          ]),
        ],
      ),
    );
  }
}

class _DockInfo extends StatelessWidget {
  const _DockInfo({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.subtitleColor,
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final Color? subtitleColor;

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppSpace.radiusCard),
        child: Padding(
          padding:
              const EdgeInsets.symmetric(horizontal: AppSpace.s, vertical: 2),
          child: Row(children: [
            Icon(icon, size: 20, color: iconColor),
            const SizedBox(width: AppSpace.s),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: t.ink,
                    ),
                  ),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      color: subtitleColor ?? t.muted,
                    ),
                  ),
                ],
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

class _PauseButton extends StatelessWidget {
  const _PauseButton({
    required this.onTap,
    required this.remaining,
    required this.formatSeconds,
  });

  final VoidCallback? onTap;
  final int? remaining;
  final String Function(int) formatSeconds;

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    return Tooltip(
      message: 'Fazer pausa (máx. 3h)',
      child: Semantics(
        button: true,
        label: 'Fazer pausa (máx. 3h)',
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(AppSpace.radiusPill),
            child: Ink(
              height: AppSpace.target,
              padding: const EdgeInsets.symmetric(horizontal: AppSpace.m),
              decoration: BoxDecoration(
                color: t.surface,
                borderRadius: BorderRadius.circular(AppSpace.radiusPill),
                border: Border.all(color: t.hairline.withValues(alpha: 0.35)),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.pause_circle_outline, size: 18, color: t.warning),
                const SizedBox(width: 5),
                Text(
                  remaining != null ? formatSeconds(remaining!) : 'PAUSA',
                  style: TextStyle(
                      fontSize: 11, fontWeight: FontWeight.w700, color: t.ink),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Avisos flutuantes.
// ---------------------------------------------------------------------------

class _KycGate extends StatelessWidget {
  const _KycGate({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppSpace.radiusCard),
        child: Ink(
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpace.m, vertical: AppSpace.s),
          decoration: _floatingDecoration(context),
          child: Row(children: [
            Icon(Icons.lock_outline, color: t.warning, size: 20),
            const SizedBox(width: AppSpace.s),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Cadastro em análise',
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: t.ink)),
                  Text('Complete o KYC para ficar online (F9).',
                      style: TextStyle(fontSize: 12, color: t.muted)),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: t.muted),
          ]),
        ),
      ),
    );
  }
}

class _PainelError extends StatelessWidget {
  const _PainelError({required this.code});
  final String code;

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpace.m, vertical: AppSpace.s),
      decoration: BoxDecoration(
        color: t.danger.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AppSpace.radiusCard),
        border: Border.all(color: t.danger.withValues(alpha: 0.45)),
      ),
      child: Row(children: [
        Icon(Icons.error_outline, color: t.danger, size: 18),
        const SizedBox(width: AppSpace.s),
        Expanded(
          child: Text(
              switch (code) {
                'kyc_not_approved' =>
                  'KYC ainda não aprovado — complete o cadastro.',
                'blocked' => 'Conta bloqueada — fale com o suporte.',
                'offline' => 'Sem conexão — ações indisponíveis (ADX-UX-3).',
                'em_corrida' => 'Não é possível pausar durante uma corrida.',
                'presence_unconfigured' =>
                  'Radar indisponível nesta build — você pode não aparecer aos passageiros.',
                'presence_error' =>
                  'Não foi possível publicar sua localização — o passageiro pode não ver você.',
                'location_unavailable' =>
                  'Ative a localização para ficar online — é ela que coloca você no radar.',
                _ => 'Erro: $code',
              },
              style: TextStyle(color: t.danger, fontSize: 13)),
        ),
      ]),
    );
  }
}
