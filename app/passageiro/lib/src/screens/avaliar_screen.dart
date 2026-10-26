import 'package:flutter/material.dart';

import '../../main.dart';
import '../theme/theme.dart';

/// C8 Avaliar — 1–5 estrelas + comentário opcional (máx. 500, validado
/// servidor). Uma avaliação por participante; repetir → 409 already_rated.
class AvaliarScreen extends StatefulWidget {
  const AvaliarScreen({super.key});

  @override
  State<AvaliarScreen> createState() => _AvaliarScreenState();
}

class _AvaliarScreenState extends State<AvaliarScreen> {
  int _stars = 0;
  final _comentario = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _comentario.dispose();
    super.dispose();
  }

  Future<void> _enviar() async {
    if (_stars == 0) return;
    final ride = AppScope.of(context);
    setState(() => _sending = true);
    await ride.rate(stars: _stars, comment: _comentario.text);
    if (!mounted) return;
    setState(() => _sending = false);
    if (ride.lastErrorCode == null) {
      Navigator.of(context).popUntil((r) => r.isFirst);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Valeu! Nota registrada.')),
      );
    } else if (ride.lastErrorCode == 'already_rated') {
      Navigator.of(context).popUntil((r) => r.isFirst);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text('Não foi possível avaliar (${ride.lastErrorCode})')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Avaliar a corrida')),
      body: Padding(
        padding: const EdgeInsets.all(AppSpace.l),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Como foi a viagem?', style: AppType.title),
            const SizedBox(height: AppSpace.xl),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(5, (i) {
                final filled = i < _stars;
                return IconButton(
                  iconSize: 48,
                  icon: Icon(
                    filled ? Icons.star : Icons.star_border,
                    color: filled ? AppColors.warning : AppColors.hairline,
                  ),
                  onPressed: () => setState(() => _stars = i + 1),
                  tooltip: '${i + 1} estrela${i > 0 ? 's' : ''}',
                );
              }),
            ),
            const SizedBox(height: AppSpace.l),
            TextField(
              controller: _comentario,
              maxLength: 500,
              decoration: const InputDecoration(
                hintText: 'Quer contar o que aconteceu? (opcional)',
              ),
            ),
            const Spacer(),
            FilledButton(
              onPressed: _sending || _stars == 0 ? null : _enviar,
              child: _sending
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Enviar avaliação'),
            ),
          ],
        ),
      ),
    );
  }
}
