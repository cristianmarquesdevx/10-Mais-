import 'dart:async';

import 'package:flutter/material.dart';

import '../../main.dart';
import '../api/client.dart';
import '../theme/theme.dart';
import '../widgets/scratch_card.dart';
import 'widgets/raspadinha_onboarding.dart';

/// Tela de campanhas de raspadinha disponíveis (3.8).
class ScratchCampaignsScreen extends StatefulWidget {
  const ScratchCampaignsScreen({super.key});

  @override
  State<ScratchCampaignsScreen> createState() => _ScratchCampaignsScreenState();
}

class _ScratchCampaignsScreenState extends State<ScratchCampaignsScreen> {
  List<ScratchCampaign> _campaigns = [];
  bool _loading = true;
  String? _error;

  bool _loaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    _loaded = true;
    _load();
    _abrirOnboardingSePrecisa();
  }

  /// M5: na primeira visita (por versão de conteúdo) o onboarding abre sozinho.
  /// Qualquer forma de fechar (Pular, Começar ou voltar) grava o flag — só
  /// depois que a rota é fechada, então fechar o app no meio não conta.
  Future<void> _abrirOnboardingSePrecisa() async {
    if (!await RaspadinhaOnboardingPrefs.precisaMostrar()) return;
    if (!mounted) return;
    await RaspadinhaOnboardingScreen.abrir(context);
    await RaspadinhaOnboardingPrefs.marcarVisto();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final campaigns = await AppScope.apiOf(context).scratchCampaigns();
      if (mounted) setState(() => _campaigns = campaigns);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);

    return Scaffold(
      backgroundColor: t.background,
      appBar: AppBar(
        title: Text('Raspadinha de Prêmios', style: titleStyle(context)),
        actions: [
          TextButton(
            onPressed: () => RaspadinhaOnboardingScreen.abrir(context),
            child: const Text('Como funciona'),
          ),
        ],
      ),
      body: _buildBody(t),
    );
  }

  Widget _buildBody(ColorSchemeColorTokens t) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 48, color: AppColors.danger),
            const SizedBox(height: AppSpace.m),
            Text('Erro ao carregar campanhas', style: bodyStyle(context)),
            const SizedBox(height: AppSpace.s),
            GradientButton(
              onPressed: _load,
              child: const Text('TENTAR NOVAMENTE'),
            ),
          ],
        ),
      );
    }
    if (_campaigns.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.card_giftcard, size: 48, color: AppColors.muted),
            const SizedBox(height: AppSpace.m),
            Text('Nenhuma campanha disponível no momento.',
                style: bodyStyle(context)),
          ],
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.all(AppSpace.l),
      itemCount: _campaigns.length,
      itemBuilder: (context, i) {
        final c = _campaigns[i];
        return Card(
          color: t.surface,
          margin: const EdgeInsets.only(bottom: AppSpace.m),
          child: ListTile(
            leading: const Icon(Icons.card_giftcard, color: AppColors.primary),
            title: Text(c.name, style: bodyStyle(context)),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (c.description != null)
                  Text(c.description!, style: labelStyle(context)),
                const SizedBox(height: AppSpace.xs),
                Text(
                  'Participações: ${c.maxParticipationsPerUser} por usuário',
                  style: labelStyle(context).copyWith(fontSize: 12),
                ),
              ],
            ),
            trailing: const Icon(Icons.chevron_right, color: AppColors.muted),
            onTap: () => Navigator.pushNamed(
              context,
              '/scratch-play',
              arguments: c,
            ),
          ),
        );
      },
    );
  }
}

/// Tela de raspagem (3.8).
class ScratchPlayScreen extends StatefulWidget {
  const ScratchPlayScreen({super.key});

  @override
  State<ScratchPlayScreen> createState() => _ScratchPlayScreenState();
}

class _ScratchPlayScreenState extends State<ScratchPlayScreen> {
  ScratchCampaign? _campaign;
  ScratchTicket? _ticket;
  bool _loading = true;
  bool _showResult = false;
  String? _error;
  bool _scratching = false;

  bool _argsLoaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_argsLoaded) return;
    _argsLoaded = true;
    final args = ModalRoute.of(context)?.settings.arguments;
    if (args is ScratchCampaign) {
      _campaign = args;
      _play();
    } else {
      setState(() => _error = 'Campanha não encontrada');
      _loading = false;
    }
  }

  Future<void> _play() async {
    if (_campaign == null) return;
    setState(() {
      _loading = true;
      _error = null;
      _showResult = false;
    });
    try {
      final ticket = await AppScope.apiOf(context).scratchPlay(_campaign!.id);
      if (mounted) setState(() => _ticket = ticket);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _revealResult() async {
    if (_ticket == null) return;
    setState(() => _scratching = true);
    try {
      final ticket = await AppScope.apiOf(context).scratchResult(_ticket!.id);
      if (mounted) {
        setState(() {
          _ticket = ticket;
          _showResult = true;
          _scratching = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _scratching = false;
        });
      }
    }
  }

  Future<void> _redeem() async {
    if (_ticket == null || _ticket!.prizeId == null) return;
    setState(() => _scratching = true);
    try {
      await AppScope.apiOf(context).scratchRedeem(_ticket!.id);
      if (mounted) {
        setState(() {
          _ticket = ScratchTicket(
            id: _ticket!.id,
            campaignId: _ticket!.campaignId,
            userId: _ticket!.userId,
            prizeId: _ticket!.prizeId,
            result: _ticket!.result,
            status: 'REDEEMED',
            scratchedAt: _ticket!.scratchedAt,
            redeemedAt: DateTime.now(),
            createdAt: _ticket!.createdAt,
          );
          _scratching = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Prêmio resgatado com sucesso!')),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _scratching = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);

    return Scaffold(
      backgroundColor: t.background,
      appBar: AppBar(
        title: Text('Raspadinha', style: titleStyle(context)),
      ),
      body: _buildBody(t),
    );
  }

  Widget _buildBody(ColorSchemeColorTokens t) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 48, color: AppColors.danger),
            const SizedBox(height: AppSpace.m),
            Text(_error!, style: bodyStyle(context)),
            const SizedBox(height: AppSpace.l),
            GradientButton(
              onPressed: _play,
              child: const Text('TENTAR NOVAMENTE'),
            ),
          ],
        ),
      );
    }
    return Column(
      children: [
        Card(
          color: t.surface,
          child: Padding(
            padding: const EdgeInsets.all(AppSpace.l),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _campaign?.name ?? 'Campanha',
                  style: titleStyle(context),
                ),
                if (_campaign?.description != null) ...[
                  const SizedBox(height: AppSpace.s),
                  Text(_campaign!.description!, style: labelStyle(context)),
                ],
                const SizedBox(height: AppSpace.m),
                Text(
                  'Clique e arraste para raspar',
                  style: labelStyle(context),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: AppSpace.l),
        // Altura fixa: com Expanded a máscara cobria a tela inteira e o
        // percentual de raspagem ficava impossível de atingir.
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.l),
          child: SizedBox(
            height: 200,
            child: ScratchCard(
              thresholdPercent: 60,
              brushWidth: 30,
              onScratchComplete: _revealResult,
              child: Container(
                width: double.infinity,
                height: 200,
                decoration: BoxDecoration(
                  color: AppColors.primary,
                  borderRadius: BorderRadius.circular(AppSpace.radiusSheet),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.primary.withValues(alpha: 0.4),
                      blurRadius: 12,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: const Center(
                  child: Text(
                    'RASPAR',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        if (_scratching)
          const Padding(
            padding: EdgeInsets.all(AppSpace.m),
            child: CircularProgressIndicator(),
          ),
        if (_showResult && _ticket != null) ...[
          const SizedBox(height: AppSpace.l),
          ScratchResultCard(
            ticket: _ticket!,
            onRedeem: _ticket!.canRedeem && !_scratching ? _redeem : null,
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: AppSpace.l),
          Container(
            padding: const EdgeInsets.all(AppSpace.m),
            color: AppColors.danger.withValues(alpha: 0.15),
            child:
                Text(_error!, style: const TextStyle(color: AppColors.danger)),
          ),
        ],
      ],
    );
  }
}

/// Tela de histórico de raspadinhas (3.8).
class ScratchHistoryScreen extends StatefulWidget {
  const ScratchHistoryScreen({super.key});

  @override
  State<ScratchHistoryScreen> createState() => _ScratchHistoryScreenState();
}

class _ScratchHistoryScreenState extends State<ScratchHistoryScreen> {
  List<ScratchTicket> _tickets = [];
  bool _loading = true;
  String? _error;

  bool _loaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    _loaded = true;
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final tickets = await AppScope.apiOf(context).scratchHistory();
      if (mounted) setState(() => _tickets = tickets);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);

    return Scaffold(
      backgroundColor: t.background,
      appBar: AppBar(
        title: Text('Minhas Raspadinhas', style: titleStyle(context)),
      ),
      body: _buildBody(t),
    );
  }

  Widget _buildBody(ColorSchemeColorTokens t) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 48, color: AppColors.danger),
            const SizedBox(height: AppSpace.m),
            Text('Erro ao carregar histórico', style: bodyStyle(context)),
            const SizedBox(height: AppSpace.s),
            GradientButton(
              onPressed: _load,
              child: const Text('TENTAR NOVAMENTE'),
            ),
          ],
        ),
      );
    }
    if (_tickets.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.history, size: 48, color: AppColors.muted),
            const SizedBox(height: AppSpace.m),
            Text('Você ainda não raspou nenhuma raspadinha.',
                style: bodyStyle(context)),
          ],
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.all(AppSpace.l),
      itemCount: _tickets.length,
      itemBuilder: (context, i) {
        final ticket = _tickets[i];
        final isWinner = ticket.isWinner;
        return Card(
          color: t.surface,
          margin: const EdgeInsets.only(bottom: AppSpace.m),
          child: ListTile(
            leading: Icon(
              isWinner ? Icons.card_giftcard : Icons.close,
              color: isWinner ? AppColors.earn : AppColors.muted,
            ),
            title: Text(
              isWinner ? 'Você ganhou!' : 'Não foi desta vez',
              style: bodyStyle(context),
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${ticket.createdAt.day.toString().padLeft(2, '0')}/'
                  '${ticket.createdAt.month.toString().padLeft(2, '0')}/'
                  '${ticket.createdAt.year}',
                  style: labelStyle(context).copyWith(fontSize: 12),
                ),
                if (ticket.status == 'SCRATCHED' || ticket.status == 'REDEEMED')
                  Text(
                    ticket.status == 'SCRATCHED'
                        ? 'Raspado, aguardando resgate'
                        : 'Resgatado',
                    style: labelStyle(context).copyWith(
                      fontSize: 12,
                      color: ticket.status == 'REDEEMED'
                          ? AppColors.earn
                          : AppColors.warning,
                    ),
                  ),
              ],
            ),
            trailing: const Icon(Icons.chevron_right, color: AppColors.muted),
            onTap: () {},
          ),
        );
      },
    );
  }
}
