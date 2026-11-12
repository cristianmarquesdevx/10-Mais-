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
class QueueScreen extends StatefulWidget {
  const QueueScreen({super.key, required this.controller, this.onLogout});

  final ConsoleController controller;

  /// Sai da conta (o login volta).
  final VoidCallback? onLogout;

  @override
  State<QueueScreen> createState() => _QueueScreenState();
}

class _QueueScreenState extends State<QueueScreen> {
  @override
  void initState() {
    super.initState();
    widget.controller.load();
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
            return const Center(child: CircularProgressIndicator());
          }
          if (c.error != null && c.queue.isEmpty) {
            return _ErrorState(
              code: c.error!,
              onRetry: () => c.load(),
            );
          }
          if (c.queue.isEmpty) {
            return const EmptyState(
              icon: Icons.inbox_outlined,
              title: 'Nenhum cadastro na fila',
              message:
                  'Quando um parceiro enviar a documentação, o caso aparece aqui '
                  'com a posição e o prazo.',
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
            children: [
              _PositionBadge(position: item.position),
              const SizedBox(width: AppSpace.m),
              Expanded(
                child: Text(
                  'Parceiro ${_short(item.partnerUserId)}',
                  style: AppType.title.copyWith(color: t.ink, fontSize: 16),
                ),
              ),
              StatusChip(
                label: overdue ? 'ATRASADO' : 'NO PRAZO',
                tone: overdue ? StatusTone.danger : StatusTone.success,
                icon: overdue
                    ? Icons.warning_amber_rounded
                    : Icons.schedule_outlined,
              ),
            ],
          ),
          const SizedBox(height: AppSpace.m),
          Wrap(
            spacing: AppSpace.s,
            runSpacing: AppSpace.xs,
            children: [
              _Meta(
                icon: Icons.timer_outlined,
                text: slaLabel(item.slaDueAt, now),
                color: overdue ? t.danger : t.muted,
              ),
              _Meta(
                icon: Icons.hourglass_bottom_outlined,
                text: waitingLabel(item.createdAt, now),
              ),
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

  /// O identificador curto da conta: o console mostra o ID, não o nome —
  /// o nome vem no detalhe do caso, que é onde ele é necessário.
  static String _short(String uuid) =>
      uuid.length <= 8 ? uuid : uuid.substring(uuid.length - 8);
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
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 15, color: c),
        const SizedBox(width: AppSpace.xs),
        Text(text, style: AppType.label.copyWith(color: c)),
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
      title: title,
      message: message,
      action: OutlinedButton.icon(
        onPressed: onRetry,
        icon: const Icon(Icons.refresh),
        label: const Text('Tentar de novo'),
      ),
    );
  }
}
