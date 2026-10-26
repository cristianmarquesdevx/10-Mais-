import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../main.dart';
import '../api/client.dart';
import '../theme/theme.dart';

/// Tela de convite de motoristas (3.8).
///
/// Permite gerar um código de convite, copiá-lo e acompanhar os convites
/// já feitos. O backend é a fonte de verdade (GET /invites/mine e
/// POST /invites); a tela só reflete o estado devolvido pelo servidor.
class InviteScreen extends StatefulWidget {
  const InviteScreen({super.key});

  @override
  State<InviteScreen> createState() => _InviteScreenState();
}

class _InviteScreenState extends State<InviteScreen> {
  final _codeCtrl = TextEditingController();
  List<Invite> _invites = const [];
  bool _loading = true;
  bool _generating = false;
  String? _error;

  bool _loaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // AppScope é InheritedWidget: só pode ser lido depois que as
    // dependências existem (initState lança e a tela cairia em "offline").
    if (_loaded) return;
    _loaded = true;
    _loadInvites();
  }

  @override
  void dispose() {
    _codeCtrl.dispose();
    super.dispose();
  }

  void _syncCodeField() {
    if (_invites.isNotEmpty) {
      _codeCtrl.text = _invites.first.inviteCode;
    }
  }

  Future<void> _loadInvites() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final invites = await AppScope.apiOf(context).myInvites();
      if (!mounted) return;
      setState(() {
        _invites = invites;
        _syncCodeField();
      });
    } on ApiProblem catch (e) {
      if (mounted) setState(() => _error = e.code);
    } catch (_) {
      if (mounted) setState(() => _error = 'offline');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _generateInvite() async {
    setState(() {
      _generating = true;
      _error = null;
    });
    try {
      final invite = await AppScope.apiOf(context).generateInvite();
      if (!mounted) return;
      setState(() {
        _invites = [invite, ..._invites];
        _syncCodeField();
        _generating = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Código de convite gerado!'),
          backgroundColor: AppColors.earn,
        ),
      );
    } on ApiProblem catch (e) {
      if (mounted) {
        setState(() {
          _generating = false;
          _error = e.code;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _generating = false;
          _error = 'offline';
        });
      }
    }
  }

  Future<void> _copyCode() async {
    final code = _codeCtrl.text.trim();
    if (code.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: code));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Código $code copiado.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);

    return Scaffold(
      backgroundColor: t.background,
      appBar: AppBar(
        title: Text('Convide Motoristas', style: titleStyle(context)),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _loadInvites,
              child: ListView(
                padding: const EdgeInsets.all(AppSpace.l),
                children: [
                  _CodeCard(
                    controller: _codeCtrl,
                    generating: _generating,
                    onGenerate: _generating ? null : _generateInvite,
                    onCopy: _copyCode,
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: AppSpace.s),
                    Text(
                      _error == 'offline'
                          ? 'Sem conexão — tente novamente.'
                          : 'Não foi possível carregar os convites ($_error).',
                      style: const TextStyle(color: AppColors.danger),
                    ),
                  ],
                  const SizedBox(height: AppSpace.l),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Meus Convites', style: titleStyle(context)),
                      if (_invites.isNotEmpty)
                        TextButton(
                          onPressed: _loadInvites,
                          child: const Text('Atualizar'),
                        ),
                    ],
                  ),
                  const SizedBox(height: AppSpace.s),
                  if (_invites.isEmpty)
                    const _EmptyInvites()
                  else
                    for (final invite in _invites) _InviteTile(invite: invite),
                ],
              ),
            ),
    );
  }
}

class _CodeCard extends StatelessWidget {
  const _CodeCard({
    required this.controller,
    required this.generating,
    required this.onGenerate,
    required this.onCopy,
  });

  final TextEditingController controller;
  final bool generating;
  final VoidCallback? onGenerate;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    return Card(
      color: t.surface,
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.l),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Meu Código de Convite', style: titleStyle(context)),
            const SizedBox(height: AppSpace.m),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: controller,
                    readOnly: true,
                    style: bodyStyle(context),
                    decoration: InputDecoration(
                      labelText: 'Código',
                      hintText: 'Gere seu primeiro código',
                      border: OutlineInputBorder(
                        borderRadius:
                            BorderRadius.circular(AppSpace.radiusCard),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: AppSpace.s),
                IconButton.filledTonal(
                  onPressed: controller.text.isEmpty ? null : onCopy,
                  icon: const Icon(Icons.copy_outlined),
                  tooltip: 'Copiar código',
                ),
              ],
            ),
            const SizedBox(height: AppSpace.m),
            OutlinedButton(
              onPressed: onGenerate,
              child: generating
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('GERAR NOVO CÓDIGO'),
            ),
            const SizedBox(height: AppSpace.s),
            Text(
              'Compartilhe o código: quando o motorista concluir a primeira '
              'corrida, você ganha horas de passe.',
              style: labelStyle(context).copyWith(fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

class _InviteTile extends StatelessWidget {
  const _InviteTile({required this.invite});

  final Invite invite;

  @override
  Widget build(BuildContext context) {
    final completed = invite.status == 'COMPLETED';
    return Card(
      margin: const EdgeInsets.only(bottom: AppSpace.m),
      child: ListTile(
        leading: Icon(
          completed ? Icons.card_giftcard : Icons.schedule,
          color: completed ? AppColors.earn : AppColors.muted,
        ),
        title: Text(invite.inviteCode, style: bodyStyle(context)),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Status: ${_statusLabel(invite.status)}',
                style: labelStyle(context)),
            if (invite.rewardHours != null)
              Text(
                '${invite.rewardHours}h de recompensa',
                style: const TextStyle(fontSize: 12, color: AppColors.earn),
              ),
          ],
        ),
        trailing: completed
            ? const Icon(Icons.check_circle, color: AppColors.earn)
            : const Icon(Icons.pending, color: AppColors.muted),
      ),
    );
  }

  static String _statusLabel(String status) => switch (status) {
        'COMPLETED' => 'Concluído',
        'EXPIRED' => 'Expirado',
        _ => 'Aguardando',
      };
}

class _EmptyInvites extends StatelessWidget {
  const _EmptyInvites();

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpace.xl),
        child: Column(
          children: [
            const Icon(Icons.person_add_outlined,
                size: 64, color: AppColors.muted),
            const SizedBox(height: AppSpace.m),
            Text('Nenhum convite ainda.', style: bodyStyle(context)),
            const SizedBox(height: AppSpace.s),
            Text(
              'Compartilhe seu código de convite para ganhar 12h grátis.',
              style: labelStyle(context),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
}
