import 'package:flutter/material.dart';

import '../../main.dart';
import '../api/client.dart';
import '../theme/theme.dart';

/// P6 Passe — PassCard: estado atual, fila FIFO (A3), preço vigente da
/// cidade e compra em 1 toque (checkout PIX/cartão hospedado). Ativação
/// agendada no 1º ONLINE (A2); vencimento é relógio do servidor (A7).
class PasseScreen extends StatefulWidget {
  const PasseScreen({super.key});

  @override
  State<PasseScreen> createState() => _PasseScreenState();
}

class _PasseScreenState extends State<PasseScreen> {
  static String _shortId(String? id) =>
      id == null || id.length <= 8 ? (id ?? '—') : id.substring(0, 8);

  PassState? _state;
  String? _error;
  bool _buying = false;
  String? _checkoutPix;
  bool _loaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loaded) {
      _loaded = true;
      _load();
    }
  }

  Future<void> _load() async {
    try {
      final s = await AppScope.apiOf(context).passes();
      if (mounted) setState(() => _state = s);
    } on ApiProblem catch (p) {
      if (mounted) setState(() => _error = p.code);
    } catch (_) {
      if (mounted) setState(() => _error = 'offline');
    }
  }

  Future<void> _buy() async {
    setState(() {
      _buying = true;
      _error = null;
    });
    try {
      final r = await AppScope.apiOf(context).buyPass();
      final checkout = r['checkout'] as Map<String, dynamic>?;
      if (mounted) {
        setState(() => _checkoutPix = checkout?['pix'] as String?);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Passe comprado — ativa no 1º online (A2)')));
      }
      await _load();
    } on ApiProblem catch (p) {
      if (mounted) setState(() => _error = p.code);
    } finally {
      if (mounted) setState(() => _buying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _state;
    return Scaffold(
      appBar: AppBar(title: const Text('Passe')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpace.l),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(AppSpace.l),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Icon(
                      s?.mode == 'PASSE_ATIVO'
                          ? Icons.workspace_premium
                          : Icons.workspace_premium_outlined,
                      color: s?.mode == 'PASSE_ATIVO'
                          ? AppColors.earn
                          : AppColors.muted,
                    ),
                    const SizedBox(width: AppSpace.s),
                    Text(
                      s?.mode == 'PASSE_ATIVO'
                          ? 'PASSE ATIVO — 100% seu'
                          : 'COMISSÃO 12%',
                      style: AppType.title.copyWith(
                        color: s?.mode == 'PASSE_ATIVO'
                            ? AppColors.earn
                            : AppColors.ink,
                      ),
                    ),
                  ]),
                  const SizedBox(height: AppSpace.s),
                  if (s?.expiresAt != null)
                    Text(
                      'Vence em servidor: ${s!.expiresAt!.toLocal()}',
                      style: AppType.label,
                    ),
                  if (s?.countingStrategy != null)
                    Text(
                      s!.countingStrategy == 'RELOGIO_CORRIDO'
                          ? 'Relógio corrido da ativação (A1 padrão)'
                          : 'Conta horas online (A1 opcional da cidade)',
                      style: AppType.label,
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: AppSpace.l),
          if (s != null && s.queue.isNotEmpty) ...[
            const Text('Fila de passes', style: AppType.title),
            const SizedBox(height: AppSpace.s),
            Card(
              child: Column(children: [
                for (final q in s.queue)
                  ListTile(
                    leading: const Icon(Icons.schedule_outlined),
                    title: Text('Passe ${_shortId(q['pass_id'] as String?)}'),
                    subtitle: Text('Status: ${q['status'] ?? 'SCHEDULED'}'),
                  ),
              ]),
            ),
            const SizedBox(height: AppSpace.l),
          ],
          if (_checkoutPix != null) ...[
            const Text('PIX do passe', style: AppType.title),
            const SizedBox(height: AppSpace.s),
            Card(
              child: SelectableText(_checkoutPix!,
                  style: const TextStyle(fontFeatures: [
                    FontFeature.tabularFigures(),
                  ], fontSize: 13)),
            ),
            const SizedBox(height: AppSpace.l),
          ],
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpace.m),
              child: Text(
                _error == 'purchase_in_flight'
                    ? 'Você já tem uma compra em andamento.'
                    : 'Erro: $_error',
                style: const TextStyle(color: AppColors.danger),
              ),
            ),
          FilledButton.icon(
            onPressed: _buying || s == null ? null : _buy,
            icon: const Icon(Icons.shopping_cart_outlined),
            label: Text(s?.price != null
                ? 'Comprar passe — ${brl(s!.price!)}'
                : 'Comprar passe'),
          ),
          const SizedBox(height: AppSpace.s),
          const Text(
            'Vencimento nunca interrompe corrida em andamento (A5); '
            'a renovação entra em fila atrás do atual (A3).',
            style: AppType.label,
          ),
        ],
      ),
    );
  }
}
