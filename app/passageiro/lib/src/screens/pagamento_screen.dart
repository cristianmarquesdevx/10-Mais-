import 'package:flutter/material.dart';

import '../../main.dart';
import '../api/route_service.dart';
import '../theme/theme.dart';

/// C7 Revisão/Pagamento (FINALIZADA) — PIX (QR + copia-e-cola) ou cartão
/// hosted; recusa → retry idempotente (F6). Decisão por code.
class PagamentoScreen extends StatefulWidget {
  const PagamentoScreen({super.key});

  @override
  State<PagamentoScreen> createState() => _PagamentoScreenState();
}

class _PagamentoScreenState extends State<PagamentoScreen> {
  String? _qr;
  String? _copiaCopia;
  bool _sending = false;
  bool _confirming = false;
  String? _confirmError;

  /// "Já paguei" — pergunta ao servidor se o PSP confirmou. A tela só avança
  /// quando o backend diz CONFIRMED; sem isso mostra aguardando/erro e o
  /// passageiro pode tentar de novo.
  Future<void> _confirmarPagamento() async {
    final ride = AppScope.of(context);
    setState(() {
      _confirming = true;
      _confirmError = null;
    });
    final ok = await ride.confirmPayment();
    if (!mounted) return;
    setState(() => _confirming = false);
    if (ok) {
      Navigator.pushNamed(context, '/avaliar');
      return;
    }
    final code = ride.lastErrorCode;
    setState(() {
      _confirmError = code == 'network' || code == 'offline'
          ? 'Sem conexão com o servidor. Seu pagamento não foi perdido — '
              'tente confirmar de novo.'
          : 'O servidor ainda não confirmou o PIX (${code ?? 'aguardando'}). '
              'Se você já pagou, tente de novo em instantes.';
    });
  }

  Future<void> _pagar(String metodo) async {
    final ride = AppScope.of(context);
    setState(() => _sending = true);
    final payload = await ride.pay(metodo);
    if (!mounted) return;
    setState(() => _sending = false);
    final code = ride.lastErrorCode;
    if (code == null) {
      if (metodo == 'PIX') {
        // Resposta do PSP: { payment_id, pix: { qr, copia_cola, expires_at } }
        final pix = payload?['pix'] as Map<String, dynamic>?;
        if (!mounted) return;
        setState(() {
          _qr = pix?['qr'] as String? ?? 'PIX';
          _copiaCopia = pix?['copia_cola'] as String? ?? '';
        });
      } else {
        Navigator.pushNamed(context, '/avaliar');
      }
    } else {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(switch (code) {
          'payment_already_confirmed' => 'Já estava pago.',
          _ => 'Pagamento não concluído. Tente de novo ($code)',
        }),
        action: SnackBarAction(
            label: 'Tentar de novo', onPressed: () => _pagar(metodo)),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final ride = AppScope.of(context);
    final r = ride.ride;
    final total = r?.fareTotal;
    // O recibo repete a distância congelada no pedido: é o mesmo km que a
    // cotação mostrou e que o parceiro viu na oferta.
    final km = r?.distanceKm;
    final jaPago = r?.paymentStatus == 'CONFIRMED';
    return Scaffold(
      appBar: AppBar(title: const Text('Pagamento')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpace.l),
        children: [
          Card(
            child: Column(children: [
              ListTile(
                title: const Text('Total da corrida'),
                trailing: Text(total != null ? brl(total) : '—',
                    style: AppType.money),
              ),
              if (km != null)
                ListTile(
                  leading: const Icon(Icons.route_outlined,
                      color: AppColors.primary),
                  title: const Text('Distância'),
                  trailing:
                      Text(RouteResult.kmLabel(km), style: AppType.label),
                ),
            ]),
          ),
          const SizedBox(height: AppSpace.l),
          // O parceiro já declarou o dinheiro no P5: não pede pagamento de
          // novo — só confirma e segue para a avaliação.
          if (jaPago) ...[
            const Card(
              child: ListTile(
                leading: Icon(Icons.check_circle, color: AppColors.earn),
                title: Text('Pagamento confirmado'),
                subtitle: Text('O parceiro confirmou o recebimento.'),
              ),
            ),
            const SizedBox(height: AppSpace.l),
            FilledButton(
              onPressed: () => Navigator.pushNamed(context, '/avaliar'),
              child: const Text('Avaliar corrida'),
            ),
          ] else if (_qr != null) ...[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(AppSpace.l),
                child: Column(children: [
                  const Icon(Icons.qr_code_2, size: 160),
                  const SizedBox(height: AppSpace.m),
                  SelectableText(
                    _copiaCopia ?? '',
                    style: AppType.label,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: AppSpace.m),
                  FilledButton(
                    onPressed: _confirming ? null : _confirmarPagamento,
                    child: _confirming
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('Já paguei'),
                  ),
                  if (_confirmError != null) ...[
                    const SizedBox(height: AppSpace.s),
                    Text(_confirmError!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            color: AppColors.danger, fontSize: 12)),
                  ],
                ]),
              ),
            ),
          ] else ...[
            FilledButton.icon(
              onPressed: _sending ? null : () => _pagar('PIX'),
              icon: const Icon(Icons.pix),
              label: const Text('Pagar com PIX'),
            ),
            const SizedBox(height: AppSpace.m),
            OutlinedButton.icon(
              onPressed: _sending ? null : () => _pagar('CARD'),
              icon: const Icon(Icons.credit_card),
              label: const Text('Pagar com cartão'),
            ),
            const SizedBox(height: AppSpace.m),
            OutlinedButton(
              onPressed: () => Navigator.pushNamed(context, '/avaliar'),
              child: const Text('Pagar em dinheiro'),
            ),
          ],
        ],
      ),
    );
  }
}
