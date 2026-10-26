import 'package:flutter/material.dart';

import '../../main.dart';
import '../api/client.dart';
import '../theme/theme.dart';

/// P7 Extrato/Carteira — saldo, dívida (ADR-003: bloqueia só dinheiro) e
/// extrato ITEMIZADO por componente (REQ-003 transparência: cada lançamento
/// do ledger com direção D/C). Saque PIX: 202 na fila; 409 insufficient|debt.
class CarteiraScreen extends StatefulWidget {
  const CarteiraScreen({super.key});

  @override
  State<CarteiraScreen> createState() => _CarteiraScreenState();
}

class _CarteiraScreenState extends State<CarteiraScreen> {
  Wallet? _wallet;
  String? _error;
  bool _withdrawing = false;
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
      final w = await AppScope.apiOf(context).wallet();
      if (mounted) setState(() => _wallet = w);
    } on ApiProblem catch (p) {
      if (mounted) setState(() => _error = p.code);
    } catch (_) {
      if (mounted) setState(() => _error = 'offline');
    }
  }

  Future<void> _withdraw() async {
    setState(() {
      _withdrawing = true;
      _error = null;
    });
    try {
      await AppScope.apiOf(context).withdraw();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Saque PIX na fila — concluí em minutos.')));
      }
      await _load();
    } on ApiProblem catch (p) {
      if (mounted) {
        setState(() => _error = p.code);
        // Atualiza saldo local quando o erro carrega estado novo.
        await _load();
      }
    } finally {
      if (mounted) setState(() => _withdrawing = false);
    }
  }

  String _fmt(DateTime dt) {
    final l = dt.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(l.day)}/${two(l.month)} ${two(l.hour)}:${two(l.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final w = _wallet;
    return Scaffold(
      appBar: AppBar(title: const Text('Carteira')),
      body: w == null && _error == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(AppSpace.l),
                children: [
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(AppSpace.xl),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Saldo disponível', style: AppType.label),
                          Text(
                            w != null ? brl(w.balance) : '—',
                            style: AppType.money,
                          ),
                          if (w != null && w.debtCents > 0) ...[
                            const SizedBox(height: AppSpace.s),
                            Text(
                              'Dívida: ${brl(w.debtCents / 100)} — novas corridas '
                              'em DINHEIRO ficam bloqueadas até quitar (ADR-003). '
                              'PIX/cartão continuam liberados.',
                              style: const TextStyle(color: AppColors.warning),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpace.m),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppSpace.m),
                      child: Text(
                        switch (_error) {
                          'insufficient' => 'Saldo insuficiente para saque.',
                          'debt' =>
                            'Quite a dívida (ou pague em PIX) para sacar.',
                          'offline' => 'Sem conexão — tente de novo.',
                          _ => 'Erro: $_error',
                        },
                        style: const TextStyle(color: AppColors.danger),
                      ),
                    ),
                  FilledButton.icon(
                    onPressed: _withdrawing || w == null || w.balance <= 0
                        ? null
                        : _withdraw,
                    icon: const Icon(Icons.pix),
                    label: Text(_withdrawing
                        ? 'Solicitando…'
                        : 'Sacar via PIX (${w != null && w.balance > 0 ? brl(w.balance) : ''})'),
                  ),
                  const SizedBox(height: AppSpace.xl),
                  const Text('Extrato', style: AppType.title),
                  const SizedBox(height: AppSpace.s),
                  if (w != null && w.statement.isEmpty)
                    const Card(
                      child: Padding(
                        padding: EdgeInsets.all(AppSpace.l),
                        child: Text('Nenhum lançamento ainda',
                            style: AppType.label),
                      ),
                    ),
                  if (w != null && w.statement.isNotEmpty)
                    Card(
                      child: Column(children: [
                        for (final e in w.statement)
                          ListTile(
                            dense: true,
                            leading: Icon(
                              e.direction == 'C'
                                  ? Icons.add_circle_outline
                                  : Icons.remove_circle_outline,
                              color: e.direction == 'C'
                                  ? AppColors.earn
                                  : AppColors.warning,
                            ),
                            title: Text(e.description,
                                style: AppType.body.copyWith(fontSize: 14)),
                            subtitle: Text(_fmt(e.createdAt)),
                            trailing: Text(
                              '${e.direction == 'C' ? '+' : '−'} ${brl(e.amount)}',
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                color: e.direction == 'C'
                                    ? AppColors.earn
                                    : AppColors.ink,
                                fontFeatures: const [
                                  FontFeature.tabularFigures()
                                ],
                              ),
                            ),
                          ),
                      ]),
                    ),
                ],
              ),
            ),
    );
  }
}
