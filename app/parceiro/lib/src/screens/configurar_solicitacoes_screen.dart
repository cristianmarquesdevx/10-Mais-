import 'package:flutter/material.dart';

import '../../main.dart';
import '../state/partner_controller.dart';
import '../theme/theme.dart';

/// "Configurar solicitações" do parceiro: quais tipos ele quer receber e o
/// atalho para o teste de status.
///
/// As preferências são do **servidor** (GET/PUT /partner/preferences): é ele
/// que deixa de criar ofertas de um tipo desligado — filtrar só na tela faria
/// o parceiro continuar recebendo o que desligou. Enquanto o PUT não volta, o
/// switch fica otimista e reverte com o motivo em caso de recusa.
class ConfigurarSolicitacoesScreen extends StatefulWidget {
  const ConfigurarSolicitacoesScreen({super.key});

  @override
  State<ConfigurarSolicitacoesScreen> createState() =>
      _ConfigurarSolicitacoesScreenState();
}

class _ConfigurarSolicitacoesScreenState
    extends State<ConfigurarSolicitacoesScreen> {
  /// Escolha local enquanto o PUT está no ar; null = espelha o controller.
  Set<String>? _draft;
  bool _loaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    _loaded = true;
    final p = AppScope.of(context);
    // AppScope/api exigem didChangeDependencies; o postFrame evita notify
    // durante o build da tela.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) p.loadPreferences();
    });
  }

  Set<String> _services(PartnerController p) => _draft ?? p.servicePrefs;

  Future<void> _toggle(PartnerController p, String service, bool on) async {
    final next = {..._services(p)};
    if (on) {
      next.add(service);
    } else {
      next.remove(service);
    }
    if (next.isEmpty) {
      // O servidor também recusa (422 invalid_services); avisar antes evita
      // um round-trip que terminaria no mesmo switch.
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content:
              Text('Deixe pelo menos um tipo ligado para receber chamadas.')));
      return;
    }
    setState(() => _draft = next);
    final ok = await p.savePreferences(next);
    if (!mounted) return;
    setState(() => _draft = null); // volta a espelhar o servidor (aceito ou não)
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
          'Não consegui salvar (${p.lastErrorCode ?? 'erro'}). Tente de novo.',
        ),
      ));
    }
  }

  /// Resumo do que o parceiro vai receber agora — mesma leitura do painel.
  /// As cores vêm dos tokens do tema ativo (o vermelho do claro não se lê no
  /// escuro e vice-versa).
  (String, Color) _resumo(BuildContext context, PartnerController p) {
    final t = tokensOf(context);
    if (p.servicePrefs.isEmpty) {
      return ('Nenhum tipo ligado — você não recebe chamadas', t.danger);
    }
    if (p.status == PartnerStatus.offline) {
      return ('Offline — fique online para receber', t.warning);
    }
    if (p.status == PartnerStatus.paused) {
      return ('Em pausa — chamadas suspensas', t.warning);
    }
    return ('Pronto para receber', t.earn);
  }

  @override
  Widget build(BuildContext context) {
    final p = AppScope.of(context);
    final t = tokensOf(context);
    final services = _services(p);
    final (resumo, cor) = _resumo(context, p);

    return Scaffold(
      backgroundColor: t.background,
      appBar: AppBar(title: const Text('Configurar solicitações')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpace.l),
        children: [
          const _SectionTitle('Preferências de solicitações'),
          Card(
            child: Column(children: [
              SwitchListTile(
                secondary: const Icon(Icons.two_wheeler_outlined,
                    color: AppColors.primary),
                title: const Text('Moto'),
                subtitle: const Text('Corridas pela tarifa do momento'),
                value: services.contains('MOTO'),
                onChanged: p.busy
                    ? null
                    : (v) => _toggle(p, 'MOTO', v),
              ),
              const Divider(height: 1),
              SwitchListTile(
                secondary: const Icon(Icons.handshake_outlined,
                    color: AppColors.primary),
                title: const Text('Moto Negocia'),
                subtitle: const Text('O passageiro propõe o preço'),
                value: services.contains('MOTO_NEGOCIA'),
                onChanged: p.busy
                    ? null
                    : (v) => _toggle(p, 'MOTO_NEGOCIA', v),
              ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpace.xs, AppSpace.s, AppSpace.xs, 0),
            child: Text(
              'O servidor só manda ofertas dos tipos ligados. Desligar um tipo '
              'não cancela a oferta que já está na tela.',
              style: AppType.label.copyWith(fontSize: 12),
            ),
          ),
          const SizedBox(height: AppSpace.l),
          const _SectionTitle('Valor mínimo por corrida'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(AppSpace.l),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'O despacho não envia oferta abaixo deste valor. Use 0 '
                    'para receber todas.',
                    style: AppType.label.copyWith(fontSize: 12),
                  ),
                  const SizedBox(height: AppSpace.s),
                  _MinFareField(
                    value: p.minFare,
                    busy: p.busy,
                    onSave: (value) async {
                      final ok = await p.savePreferences(p.servicePrefs,
                          minFare: value);
                      if (!context.mounted) return ok;
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        content: Text(ok
                            ? 'Valor mínimo salvo.'
                            : 'Não consegui salvar '
                                '(${p.lastErrorCode ?? 'erro'}).'),
                      ));
                      return ok;
                    },
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: AppSpace.xl),
          const _SectionTitle('Status da solicitação'),
          Card(
            child: ListTile(
              leading: const Icon(Icons.monitor_heart_outlined,
                  color: AppColors.primary),
              title: const Text('Teste de status'),
              subtitle: Text(resumo),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration:
                      BoxDecoration(color: cor, shape: BoxShape.circle),
                ),
                const SizedBox(width: AppSpace.s),
                const Icon(Icons.chevron_right,
                    color: AppColors.onGraphiteMuted),
              ]),
              onTap: () => Navigator.pushNamed(context, '/status-solicitacao'),
            ),
          ),
          const SizedBox(height: AppSpace.l),
          Text(
            'Precisa de ajuda com uma chamada que não chegou? O teste de status '
            'mostra servidor, modo e tipos ligados no mesmo lugar.',
            style: AppType.label.copyWith(fontSize: 12),
          ),
        ],
      ),
    );
  }
}

/// Campo do piso por corrida: dono do próprio controller (o valor chega do
/// servidor depois do primeiro build, sem sobrescrever o que está sendo
/// digitado).
class _MinFareField extends StatefulWidget {
  const _MinFareField({
    required this.value,
    required this.busy,
    required this.onSave,
  });

  final double value;
  final bool busy;
  final Future<bool> Function(double value) onSave;

  @override
  State<_MinFareField> createState() => _MinFareFieldState();
}

class _MinFareFieldState extends State<_MinFareField> {
  late final TextEditingController _ctrl =
      TextEditingController(text: _fmt(widget.value));
  bool _dirty = false;

  static String _fmt(double v) => v.toStringAsFixed(2).replaceAll('.', ',');

  @override
  void didUpdateWidget(covariant _MinFareField old) {
    super.didUpdateWidget(old);
    if (!_dirty && old.value != widget.value) {
      _ctrl.text = _fmt(widget.value);
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final raw = _ctrl.text.trim().replaceAll('.', '').replaceAll(',', '.');
    final value = double.tryParse(raw);
    if (value == null || value < 0 || value > 500) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Informe um valor entre R\$ 0,00 e R\$ 500,00.'),
      ));
      return;
    }
    final ok = await widget.onSave(value);
    if (!mounted) return;
    if (ok) {
      setState(() => _dirty = false);
      _ctrl.text = _fmt(value);
    }
  }

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Expanded(
            child: TextField(
              controller: _ctrl,
              enabled: !widget.busy,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              onChanged: (_) => setState(() => _dirty = true),
              decoration: const InputDecoration(
                prefixText: 'R\$ ',
                labelText: 'Mínimo por corrida',
                hintText: '0,00',
              ),
            ),
          ),
          const SizedBox(width: AppSpace.s),
          // Largura fixa: o tema define FilledButton com largura total, o que
          // é inválido dentro de um Row.
          SizedBox(
            width: 116,
            height: 52,
            child: FilledButton(
              onPressed: widget.busy || !_dirty ? null : _save,
              child: const Text('SALVAR'),
            ),
          ),
        ],
      );
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.s),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          fontSize: 12,
          letterSpacing: 1,
          fontWeight: FontWeight.w600,
          color: t.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
