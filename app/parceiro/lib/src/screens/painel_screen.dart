import 'package:flutter/material.dart';

import '../../main.dart';
import '../api/client.dart';
import '../state/partner_controller.dart';
import '../theme/theme.dart';
import '../widgets/heatmap_map.dart';
import '../widgets/wallet_balance_card.dart';

/// P2 Painel — o mapa ocupa a tela inteira e os controles flutuam sobre ele
/// (ADX-UX-2). O topo é minimalista: **só** o menu e o saldo flutuante do
/// motorista. O status (online/offline) fica no CTA do painel flutuante e na
/// cor do marcador no mapa; passe/comissão ficam no painel inferior.
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
  HeatSnapshot _heat = const HeatSnapshot();

  /// Controller em cache: `dispose` não pode consultar o InheritedWidget
  /// (dependência depois do descarte é erro em debug).
  PartnerController? _controller;

  @override
  void initState() {
    super.initState();
    // O saldo é lido continuamente enquanto esta tela está aberta (e só
    // enquanto ela está aberta: nada de poll em segundo plano).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _controller?.startWalletLive();
    });
  }

  @override
  void dispose() {
    _controller?.stopWalletLive();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final p = AppScope.of(context);
    _controller = p;
    if (!_loaded) {
      _loaded = true;

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) p.loadMe();
      });
      _loadHeat();
    }
  }

  Future<void> _loadHeat() async {
    try {
      final snapshot = await AppScope.apiOf(context).heatmap();
      if (mounted) setState(() => _heat = snapshot);
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
          HeatmapMap(
            zones: _heat.zones,
            online: online,
            demo: _heat.demo,
            showAttribution: false,
          ),
          SafeArea(
            bottom: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // --- topo minimalista: menu + saldo flutuante ---
                // Todo chip saiu do topo: o status está no CTA e na cor do
                // marcador; passe/comissão, no painel inferior. O saldo é o
                // único número que o motorista precisa ver sem abrir nada.
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                      AppSpace.l, AppSpace.s, AppSpace.l, 0),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (widget.onMenu != null)
                        _RoundGlassButton(
                          icon: Icons.menu_rounded,
                          tooltip: 'Menu',
                          onTap: widget.onMenu!,
                        )
                      else
                        const SizedBox(width: AppSpace.target),
                      const Spacer(),
                      WalletBalanceCard(
                        balance: p.walletBalance,
                        updatedAt: p.walletUpdatedAt,
                        loading: p.walletLoading,
                        stale: p.walletStale,
                        onTap: () => Navigator.pushNamed(context, '/carteira'),
                      ),
                    ],
                  ),
                ),
                // Selo "DEMO" da camada de demanda: logo abaixo da linha de
                // controles, no mesmo fluxo — não pode cair por baixo do
                // cartão de saldo (topo direito).
                if (_heat.demo && _heat.zones.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                        AppSpace.l, AppSpace.s, AppSpace.l, 0),
                    child: const Align(
                      alignment: Alignment.centerLeft,
                      child: DemoHeatBadge(),
                    ),
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
                // --- estado da camada de demanda (fora do topo) ---
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                      AppSpace.l, 0, AppSpace.l, AppSpace.s),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: _HeatPill(
                      zones: _heat.zones.length,
                      demo: _heat.demo,
                    ),
                  ),
                ),
                // --- painel de controle flutuante ---
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                      AppSpace.l, 0, AppSpace.l, AppSpace.m),
                  child: _ControlDock(
                    controller: p,
                    info: info,
                    formatSeconds: _formatSeconds,
                    demandAt: _heat.generatedAt == null
                        ? null
                        : '${_heat.generatedAt!.hour.toString().padLeft(2, '0')}:'
                            '${_heat.generatedAt!.minute.toString().padLeft(2, '0')}',
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

/// Estado da camada de demanda, mostrado fora do topo.
///
/// Regra de honestidade: quando não há dado real, o app **diz que não há** —
/// nunca inventa número. Dado de demonstração vem marcado como DEMO.
class _HeatPill extends StatelessWidget {
  const _HeatPill({required this.zones, required this.demo});

  final int zones;

  /// O servidor marcou a resposta como demonstração.
  final bool demo;

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    final empty = zones == 0;
    final label = empty
        ? 'Sem dados de demanda agora'
        : demo
            ? 'DEMO · $zones zonas (simulado)'
            : '$zones zonas quentes';
    final icon = empty
        ? Icons.remove_circle_outline
        : demo
            ? Icons.science_outlined
            : Icons.local_fire_department;
    final iconColor = empty ? t.muted : (demo ? t.warning : t.warning);
    return Semantics(
      label: empty
          ? 'Sem dados de demanda no momento'
          : demo
              ? 'Camada de demanda em modo demonstração: $zones zonas'
              : '$zones zonas com demanda',
      child: Container(
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.m),
        decoration: _floatingDecoration(context, radius: AppSpace.radiusChip),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, color: iconColor, size: 16),
          const SizedBox(width: AppSpace.xs),
          // Texto flexível: em tela estreita (ou com fonte maior) o rótulo
          // encolhe com reticências em vez de estourar a linha.
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: empty ? t.muted : t.ink,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ]),
      ),
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
    this.demandAt,
  });

  final PartnerController controller;
  final PartnerInfo? info;

  /// Horário do servidor da leitura de demanda ("HH:MM"), quando existe.
  final String? demandAt;
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
    final wallet = controller.walletBalance ?? info?.walletBalance;
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
            // Horário real do servidor: o timestamp da leitura de demanda.
            // (O antigo "relógio do servidor (A7)" era um texto fixo que
            // prometia um relógio que o app não tinha.)
            if (demandAt != null)
              Text('demanda às $demandAt',
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
