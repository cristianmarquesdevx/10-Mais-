import 'package:flutter/material.dart';

import '../../main.dart';
import '../api/client.dart';
import '../state/partner_controller.dart';
import '../theme/theme.dart';

/// "Teste de status" (Configurar solicitações): confere, num lugar só, o que
/// pode impedir uma chamada de chegar — servidor, modo do parceiro, tipos
/// ligados e cadastro.
///
/// É um diagnóstico do que o app consegue ver **agora**: não cria uma oferta
/// de teste nem altera estado no servidor. O botão refaz as checagens.
class StatusSolicitacaoScreen extends StatefulWidget {
  const StatusSolicitacaoScreen({super.key});

  @override
  State<StatusSolicitacaoScreen> createState() =>
      _StatusSolicitacaoScreenState();
}

enum _CheckState { ok, warn, bad, info }

class _Check {
  const _Check(this.state, this.title, this.detail);
  final _CheckState state;
  final String title, detail;
}

class _StatusSolicitacaoScreenState extends State<StatusSolicitacaoScreen> {
  bool _running = true;
  String? _latency; // "214 ms" quando o servidor respondeu
  String? _error; // código problem+json / offline
  DateTime? _checkedAt;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final p = AppScope.of(context);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (p.me == null) p.loadMe(); // preenche a linha do cadastro
      if (!p.prefsLoaded) p.loadPreferences(); // tipos ligados no servidor
      _run();
    });
  }

  Future<void> _run() async {
    final api = AppScope.apiOf(context);
    setState(() => _running = true);
    final sw = Stopwatch()..start();
    String? erro;
    try {
      await api.me();
    } on ApiProblem catch (p) {
      erro = p.code;
    } catch (_) {
      erro = 'offline';
    }
    sw.stop();
    if (!mounted) return;
    setState(() {
      _running = false;
      _error = erro;
      _latency = erro == null ? '${sw.elapsedMilliseconds} ms' : null;
      _checkedAt = DateTime.now();
    });
  }

  List<_Check> _checks(PartnerController p) {
    final tipos = p.servicePrefs;
    return [
      _Check(
        _running
            ? _CheckState.info
            : (_error == null ? _CheckState.ok : _CheckState.bad),
        'Conexão com o servidor',
        _running
            ? 'Testando…'
            : _error == null
                ? 'Respondeu em $_latency'
                : 'Sem resposta ($_error)',
      ),
      _Check(
        switch (p.status) {
          PartnerStatus.online => _CheckState.ok,
          PartnerStatus.paused => _CheckState.warn,
          PartnerStatus.emCorrida => _CheckState.info,
          PartnerStatus.offline => _CheckState.bad,
        },
        'Modo',
        switch (p.status) {
          PartnerStatus.online => 'ONLINE — você recebe ofertas',
          PartnerStatus.paused =>
            'EM PAUSA — chamadas suspensas até o fim da pausa',
          PartnerStatus.emCorrida =>
            'EM CORRIDA — novas ofertas voltam ao finalizar',
          PartnerStatus.offline =>
            'OFFLINE — fique online no painel para receber',
        },
      ),
      _Check(
        tipos.isEmpty ? _CheckState.bad : _CheckState.ok,
        'Tipos ligados',
        tipos.isEmpty
            ? 'Nenhum tipo ligado — nada chega'
            : tipos.map(serviceName).join(' · '),
      ),
      _Check(
        p.kycApproved ? _CheckState.ok : _CheckState.warn,
        'Cadastro',
        p.me == null
            ? 'Ainda não carregado'
            : p.kycApproved
                ? 'Aprovado'
                : 'KYC em análise — não é possível ficar online',
      ),
      _Check(
        _CheckState.info,
        'Ofertas abertas agora',
        p.offers.isEmpty
            ? 'Nenhuma no momento'
            : '${p.offers.length} aguardando resposta',
      ),
    ];
  }

  static String _hora(DateTime d) {
    final l = d.toLocal();
    String dois(int v) => v.toString().padLeft(2, '0');
    return '${dois(l.hour)}:${dois(l.minute)}:${dois(l.second)}';
  }

  @override
  Widget build(BuildContext context) {
    final p = AppScope.of(context);
    final t = Theme.of(context);
    final tokens = tokensOf(context);
    final checks = _checks(p);

    return Scaffold(
      backgroundColor: tokens.background,
      appBar: AppBar(title: const Text('Teste de status')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpace.l),
        children: [
          Text(
            'O que o app vê agora',
            style: t.textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: AppSpace.s),
          Card(
            child: Column(children: [
              for (var i = 0; i < checks.length; i++) ...[
                if (i > 0) const Divider(height: 1),
                _CheckRow(check: checks[i]),
              ],
            ]),
          ),
          const SizedBox(height: AppSpace.l),
          FilledButton.icon(
            onPressed: _running ? null : _run,
            icon: _running
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.play_arrow_rounded),
            label: Text(_running ? 'TESTANDO…' : 'TESTAR AGORA'),
          ),
          if (_checkedAt != null)
            Padding(
              padding: const EdgeInsets.only(top: AppSpace.s),
              child: Center(
                child: Text(
                  'Última verificação às ${_hora(_checkedAt!)}',
                  style: TextStyle(
                      fontSize: 12, color: t.colorScheme.onSurfaceVariant),
                ),
              ),
            ),
          const SizedBox(height: AppSpace.xl),
          Text(
            'O teste confere servidor, modo, tipos ligados e cadastro — ele não '
            'cria uma chamada de teste. Se tudo estiver certo e a oferta não '
            'chegar, fale com o suporte pelo perfil.',
            style: TextStyle(
                fontSize: 12, color: t.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _CheckRow extends StatelessWidget {
  const _CheckRow({required this.check});
  final _Check check;

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    final (icon, color) = switch (check.state) {
      _CheckState.ok => (Icons.check_circle, t.primary),
      _CheckState.warn => (Icons.warning_amber_rounded, t.warning),
      _CheckState.bad => (Icons.error_outline, t.danger),
      _CheckState.info => (Icons.info_outline, t.muted),
    };
    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(check.title),
      subtitle: Text(check.detail),
    );
  }
}
