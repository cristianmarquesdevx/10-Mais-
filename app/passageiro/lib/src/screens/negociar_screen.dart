import 'package:flutter/material.dart';

import '../../main.dart';
import '../theme/theme.dart';

/// C3 Negociar — proposta com piso/teto do servidor (D2) e contraproposta.
class NegociarScreen extends StatefulWidget {
  const NegociarScreen({super.key});

  @override
  State<NegociarScreen> createState() => _NegociarScreenState();
}

class _NegociarScreenState extends State<NegociarScreen> {
  final _valor = TextEditingController();

  @override
  void dispose() {
    _valor.dispose();
    super.dispose();
  }

  Future<void> _enviar(String kind) async {
    final ride = AppScope.of(context);
    final v = double.tryParse(_valor.text.replaceAll(',', '.'));
    if (v == null) return;
    kind == 'PROPOSE' ? await ride.propose(v) : await ride.counter(v);
    if (!mounted) return;
    final code = ride.lastErrorCode;
    if (code == null) {
      Navigator.pushNamed(context, '/fila');
    } else {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(switch (code) {
          'below_floor' => 'Abaixo do piso da cidade. Mínimo 70% da tarifa.',
          'above_ceiling' => 'Acima do teto (3× a tarifa).',
          'rate_limited' => 'Muitas propostas agora. Tente em alguns minutos.',
          _ => 'Proposta não aceita. ($code)',
        }),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final ride = AppScope.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Negociar preço')),
      body: Padding(
        padding: const EdgeInsets.all(AppSpace.l),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (ride.proposedAmount != null)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.person_outline),
                  title: const Text('Sua proposta'),
                  trailing:
                      Text(brl(ride.proposedAmount!), style: AppType.money),
                ),
              ),
            const SizedBox(height: AppSpace.l),
            TextField(
              controller: _valor,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Valor (R\$)',
                helperText: 'O parceiro pode contrapropor (máx. 3 rodadas)',
              ),
            ),
            const Spacer(),
            FilledButton(
              onPressed: ride.busy ? null : () => _enviar('PROPOSE'),
              child: const Text('Propor valor'),
            ),
            const SizedBox(height: AppSpace.m),
            OutlinedButton(
              onPressed: ride.busy ? null : () => _enviar('COUNTER'),
              child: const Text('Contrapropor'),
            ),
          ],
        ),
      ),
    );
  }
}
