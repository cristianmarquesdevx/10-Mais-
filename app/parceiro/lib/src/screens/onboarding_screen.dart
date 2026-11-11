import 'package:flutter/material.dart';

import '../../main.dart';
import '../api/client.dart';
import '../theme/theme.dart';

/// P1 Onboarding/KYC — submissão do caso (captura guiada já realizada; o
/// módulo de câmera ML Kit entra no módulo KYC, F9). 5 faixas de decisão:
/// AUTO_APPROVED (automático) · APPROVED (aprovado pela operação) ·
/// IN_REVIEW (na fila, com posição e prazo) · RESUBMIT (documentação
/// reenviada, volta para a fila) · REJECTED (recusado — só aí o parceiro
/// pode reenviar o documento).
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  bool _submitting = false;
  KycCase? _case;
  String? _error;

  /// O caso está NA FILA da operação (em análise ou já reenviado)?
  static bool _naFila(String? status) =>
      status == 'IN_REVIEW' || status == 'RESUBMIT';

  /// Reenvia a documentação de um caso recusado. No backend real o caso
  /// volta para a fila (RESUBMIT, com posição e prazo novos).
  ///
  /// Se o servidor não responder com o caso (modo demonstração), o estado
  /// NÃO é inventado: a faixa continua mostrando a recusa. Mentir sobre a
  /// fila é pior do que uma tela a menos.
  Future<void> _resubmit(KycCase current) async {
    final atualizado =
        await AppScope.apiOf(context).resubmitDocument(current.caseId);
    if (!mounted) return;
    setState(() => _case = atualizado ?? current);
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Documentação reenviada.')));
  }

  Future<void> _submit() async {
    final atual = _case;
    // Caso RECUSADO: o botão reenvia o documento — não abre um caso novo
    // (o servidor devolveria o mesmo caso).
    if (atual != null && atual.status == 'REJECTED') {
      setState(() {
        _submitting = true;
        _error = null;
      });
      try {
        await _resubmit(atual);
      } on ApiProblem catch (p) {
        if (mounted) setState(() => _error = p.code);
      } catch (_) {
        if (mounted) setState(() => _error = 'offline');
      } finally {
        if (mounted) setState(() => _submitting = false);
      }
      return;
    }

    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final c = await AppScope.apiOf(context).submitKyc();
      if (!mounted) return;
      setState(() => _case = c);
      if (c.status == 'AUTO_APPROVED' && context.mounted) {
        // Aprovação automática (demonstração): o parceiro já pode online, a
        // tela sai. A aprovação MANUAL fica na tela: ela é a informação que
        // o parceiro esperava ver depois de horas na fila.
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Aprovado! Você já pode ficar online.')));
        Navigator.pop(context);
      } else if (c.status == 'APPROVED') {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Aprovado pela operação. Você já pode ficar online.')));
      }
    } on ApiProblem catch (p) {
      if (mounted) setState(() => _error = p.code);
    } catch (_) {
      if (mounted) setState(() => _error = 'offline');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = _case;
    return Scaffold(
      appBar: AppBar(title: const Text('Cadastro de parceiro')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpace.l),
        children: [
          const Text('Documentos', style: AppType.title),
          const SizedBox(height: AppSpace.s),
          const Card(
            child: Column(children: [
              ListTile(
                leading: Icon(Icons.badge_outlined),
                title: Text('Documento com foto'),
                subtitle: Text('CNH ou RG — captura guiada (borrão/reflexo)'),
                trailing: Icon(Icons.check_circle_outline),
              ),
              Divider(height: 1),
              ListTile(
                leading: Icon(Icons.credit_card_outlined),
                title: Text('CNH'),
                subtitle: Text('Frente e verso'),
                trailing: Icon(Icons.check_circle_outline),
              ),
              Divider(height: 1),
              ListTile(
                leading: Icon(Icons.face_outlined),
                title: Text('Selfie'),
                subtitle: Text('Prova de vida — comparação facial'),
                trailing: Icon(Icons.check_circle_outline),
              ),
            ]),
          ),
          const SizedBox(height: AppSpace.l),
          if (c != null) _CaseStatus(kycCase: c),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpace.m),
              child: Text('Erro: $_error',
                  style: const TextStyle(color: AppColors.danger)),
            ),
          FilledButton.icon(
            // Com o caso NA FILA (em análise ou reenviado), o botão fica
            // travado: quem manda no ritmo do caso é a operação, não o
            // parceiro. Só a recusa libera um novo envio.
            onPressed: _submitting || _naFila(_case?.status)
                ? null
                : _submit,
            icon: _submitting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.upload_file_outlined),
            label: Text(
                _case?.status == 'REJECTED'
                    ? 'Reenviar documento'
                    : _naFila(_case?.status)
                        ? 'Em análise'
                        : 'Enviar documentação'),
          ),
          const SizedBox(height: AppSpace.m),
          const Text(
            'Enviado? A análise automática leva minutos; na fila manual, '
            'o prazo aparece aqui. Em análise você ainda não pode ficar online.',
            style: AppType.label,
          ),
        ],
      ),
    );
  }
}

class _CaseStatus extends StatelessWidget {
  const _CaseStatus({required this.kycCase});
  final KycCase kycCase;

  @override
  Widget build(BuildContext context) {
    final (icon, color, text) = switch (kycCase.status) {
      'AUTO_APPROVED' => (
          Icons.check_circle_outline,
          AppColors.earn,
          'Aprovado automaticamente.'
        ),
      'APPROVED' => (
          Icons.verified_outlined,
          AppColors.earn,
          'Aprovado pela operação.'
        ),
      'IN_REVIEW' => (
          Icons.hourglass_top_outlined,
          AppColors.warning,
          'Em análise — posição na fila: ${kycCase.position ?? '—'}'
        ),
      'RESUBMIT' => (
          Icons.hourglass_top_outlined,
          AppColors.warning,
          'Documentação reenviada — posição na fila: ${kycCase.position ?? '—'}'
        ),
      'REJECTED' => (
          Icons.replay_outlined,
          AppColors.danger,
          'Documentação rejeitada — reenvie apenas o documento indicado.'
        ),
      _ => (Icons.help_outline, AppColors.muted, kycCase.status),
    };
    return Card(
      child: ListTile(
        leading: Icon(icon, color: color),
        title: Text(text),
        subtitle: kycCase.sla != null
            ? Text('SLA até ${kycCase.sla!.toLocal()}')
            : null,
      ),
    );
  }
}
