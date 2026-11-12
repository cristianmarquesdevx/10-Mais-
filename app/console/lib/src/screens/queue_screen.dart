import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ten_design/ten_design.dart';

import '../api/console_api.dart';
import '../sla.dart';
import '../state/console_controller.dart';
import 'case_screen.dart';

/// A fila do KYC: quem está esperando, em que posição, até quando, e o botão
/// que abre o caso para decidir.
///
/// É a PRIMEIRA tela do console (a pessoa "Cris" abre o app e a fila está
/// na frente): o que a operação precisa primeiro é saber o que está
/// esperando e o que vence primeiro.
///
/// A fila se ATUALIZA sozinha (polling): quem opera passa boa parte do
/// expediente com um caso aberto, e a fila parada é uma fila mentirosa.
class QueueScreen extends StatefulWidget {
  const QueueScreen({
    super.key,
    required this.controller,
    this.onLogout,
    this.pollInterval = const Duration(seconds: 30),
  });

  final ConsoleController controller;

  /// Sai da conta (o login volta).
  final VoidCallback? onLogout;

  /// De quanto em quanto tempo a fila se atualiza sozinha.
  ///
  /// `null` desliga o polling (é o que os testes fazem: um timer pendente
  /// no fim do teste é falha).
  final Duration? pollInterval;

  @override
  State<QueueScreen> createState() => _QueueScreenState();
}

class _QueueScreenState extends State<QueueScreen> {
  Timer? _poll;
  int _lastErrorShown = 0;

  @override
  void initState() {
    super.initState();
    widget.controller.load();
    widget.controller.addListener(_onControllerChanged);
    final interval = widget.pollInterval;
    if (interval != null && interval > Duration.zero) {
      _poll = Timer.periodic(interval, (_) {
        if (!mounted) return;
        widget.controller.load(silent: true);
      });
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    widget.controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  /// O erro de uma atualização silenciosa não pode ser silencioso: a pessoa
  /// precisa saber que a fila que está vendo pode estar velha.
  void _onControllerChanged() {
    final c = widget.controller;
    if (c.error == null || c.queue.isEmpty) return;
    if (c.errorCount == _lastErrorShown) return;
    _lastErrorShown = c.errorCount;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Row(
            children: [
              Icon(Icons.cloud_off_outlined, color: Colors.white),
              SizedBox(width: AppSpace.s),
              Expanded(child: Text('Não foi possível atualizar a fila.')),
            ],
          ),
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Fila do KYC'),
        actions: [
          IconButton(
            tooltip: 'Atualizar',
            onPressed: () => widget.controller.load(silent: true),
            icon: const Icon(Icons.refresh),
          ),
          if (widget.onLogout != null)
            IconButton(
              tooltip: 'Sair',
              onPressed: widget.onLogout,
              icon: const Icon(Icons.logout),
            ),
        ],
      ),
      body: ListenableBuilder(
        listenable: widget.controller,
        builder: (context, _) {
          final c = widget.controller;
          if (c.loading && c.queue.isEmpty) {
            return const Center(
              child: CircularProgressIndicator(color: AppColors.primaryInk),
            );
          }
          if (c.error != null && c.queue.isEmpty) {
            return _ErrorState(
              code: c.error!,
              onRetry: () => c.load(),
            );
          }
          if (c.queue.isEmpty) {
            return EmptyState(
              icon: Icons.inbox_outlined,
              title: 'Nenhum cadastro na fila',
              message:
                  'Quando um parceiro enviar a documentação, o caso aparece aqui '
                  'com a posição e o prazo.',
              action: OutlinedButton.icon(
                key: const ValueKey('queue-refresh'),
                onPressed: () => c.load(),
                icon: const Icon(Icons.refresh),
                label: const Text('Atualizar agora'),
                style: OutlinedButton.styleFrom(foregroundColor: t.ink),
              ),
            );
          }
          return RefreshIndicator(
            onRefresh: () => c.load(silent: true),
            child: ListView.separated(
              key: const ValueKey('queue-list'),
              padding: const EdgeInsets.all(AppSpace.l),
              itemCount: c.queue.length,
              separatorBuilder: (_, __) => const SizedBox(height: AppSpace.m),
              itemBuilder: (context, i) => _CaseTile(
                item: c.queue[i],
                controller: widget.controller,
              ),
            ),
          );
        },
      ),
      bottomNavigationBar: ListenableBuilder(
        listenable: widget.controller,
        builder: (context, _) {
          final loaded = widget.controller.loadedAt;
          if (loaded == null) return const SizedBox.shrink();
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppSpace.l, AppSpace.xs, AppSpace.l, AppSpace.s),
              child: Text(
                'Atualizado às ${loaded.hour.toString().padLeft(2, '0')}:'
                '${loaded.minute.toString().padLeft(2, '0')}',
                textAlign: TextAlign.center,
                style: AppType.caption.copyWith(color: t.muted),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Um caso na fila.
class _CaseTile extends StatelessWidget {
  const _CaseTile({required this.item, required this.controller});

  final QueueCase item;
  final ConsoleController controller;

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    final now = DateTime.now();
    final overdue = item.isOverdue(now);
    final phone = item.partnerPhone?.trim();
    return AppCard(
      onTap: () async {
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => CaseScreen(
              caseId: item.caseId,
              api: controller.api,
              controller: controller,
            ),
          ),
        );
      },
      semanticLabel: 'Caso na posição ${item.position ?? '?'}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _PositionBadge(position: item.position),
              const SizedBox(width: AppSpace.m),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.displayName,
                      style: AppType.title.copyWith(color: t.ink, fontSize: 16),
                    ),
                    if (phone != null && phone.isNotEmpty) ...[
                      const SizedBox(height: AppSpace.xs),
                      Text(
                        phone,
                        style: AppType.caption.copyWith(color: t.muted),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.m),
          // O chip fica na SUA LINHA: na mesma linha do nome, com a fonte do
          // sistema grande, ele estourava o cartão.
          StatusChip(
            label: overdue ? 'ATRASADO' : 'NO PRAZO',
            tone: overdue ? StatusTone.danger : StatusTone.success,
            icon: overdue
                ? Icons.warning_amber_rounded
                : Icons.schedule_outlined,
          ),
          const SizedBox(height: AppSpace.m),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Meta(
                icon: Icons.timer_outlined,
                text: slaLabel(item.slaDueAt, now),
                color: overdue ? t.danger : t.muted,
              ),
              const SizedBox(height: AppSpace.xs),
              _Meta(
                icon: Icons.hourglass_bottom_outlined,
                text: waitingLabel(item.createdAt, now),
              ),
              const SizedBox(height: AppSpace.xs),
              _Meta(
                icon: Icons.description_outlined,
                text: '${item.documents} '
                    '${item.documents == 1 ? 'documento' : 'documentos'}',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PositionBadge extends StatelessWidget {
  const _PositionBadge({required this.position});

  final int? position;

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    return Container(
      width: 40,
      height: 40,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: t.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppSpace.radiusCard),
      ),
      child: Text(
        position == null ? '—' : '#$position',
        style: AppType.title.copyWith(color: t.primaryInk, fontSize: 16),
      ),
    );
  }
}

/// Uma linha de metadado. O texto é `Flexible`: com a fonte do sistema
/// grande, ele quebra em vez de estourar a linha.
class _Meta extends StatelessWidget {
  const _Meta({required this.icon, required this.text, this.color});

  final IconData icon;
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    final c = color ?? t.muted;
    return Row(
      children: [
        Icon(icon, size: 15, color: c),
        const SizedBox(width: AppSpace.xs),
        Flexible(
          child: Text(text, style: AppType.label.copyWith(color: c)),
        ),
      ],
    );
  }
}

/// Erro na carga da fila.
class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.code, required this.onRetry});

  final String code;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    final (icon, title, message) = switch (code) {
      'offline' => (
          Icons.cloud_off_outlined,
          'Sem conexão com o servidor',
          'A fila não pôde ser lida. Nada foi inventado: o que você vê aqui é '
              'o que o servidor devolveu.',
        ),
      'forbidden' => (
          Icons.lock_outline,
          'Esta conta não é da operação',
          'Só papel AGENT ou ADMIN enxerga a fila do KYC.',
        ),
      'not_configured' => (
          Icons.settings_ethernet,
          'Console sem backend',
          'Configure KYC_BASE no build para falar com o servidor do KYC.',
        ),
      _ => (
          Icons.error_outline,
          'Não foi possível ler a fila',
          'O servidor respondeu com o código "$code".',
        ),
    };
    return EmptyState(
      icon: icon,
      tone: StatusTone.danger,
      title: title,
      message: message,
      action: OutlinedButton.icon(
        onPressed: onRetry,
        icon: const Icon(Icons.refresh),
        label: const Text('Tentar de novo'),
        style: OutlinedButton.styleFrom(foregroundColor: t.ink),
      ),
    );
  }
}
