import 'package:flutter/material.dart';

import '../api/client.dart';
import '../../main.dart';
import '../theme/theme.dart';

/// C10 Perfil/Pagamentos — dados, métodos de pagamento (F6) e LGPD por
/// finalidade (consentimentos revogáveis).
class PerfilScreen extends StatefulWidget {
  const PerfilScreen({super.key});

  @override
  State<PerfilScreen> createState() => _PerfilScreenState();
}

class _PerfilScreenState extends State<PerfilScreen> {
  Me? _me;
  String? _error;

  bool _loaded = false;

  // Tema
  ThemeModePref _themeMode = ThemeModePref.light;
  bool _themeLoaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loaded) {
      _loaded = true;
      _load();
    }
    if (!_themeLoaded) {
      _themeLoaded = true;
      _loadTheme();
    }
  }

  Future<void> _load() async {
    try {
      final me = await AppScope.apiOf(context).me();
      if (mounted) setState(() => _me = me);
    } on ApiProblem catch (p) {
      if (mounted) setState(() => _error = p.code);
    } catch (_) {
      if (mounted) setState(() => _error = 'offline');
    }
  }

  Future<void> _loadTheme() async {
    final mode = await ThemePrefs.getMode();
    if (mounted) setState(() => _themeMode = mode);
  }

  Future<void> _setTheme(ThemeModePref mode) async {
    await ThemePrefs.setMode(mode);
    // Avisa o app inteiro na hora (antes só valia ao reabrir).
    themeModeNotifier.value = mode;
    if (mounted) setState(() => _themeMode = mode);
  }

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);

    return Scaffold(
      backgroundColor: t.surface,
      appBar: AppBar(
        title: Text('Perfil', style: titleStyle(context)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(AppSpace.l),
        children: [
          // Identidade
          Card(
            color: t.surface,
            child: ListTile(
              leading: CircleAvatar(
                child: Icon(Icons.person, color: t.primary),
              ),
              title: Text(
                _me?.fullName ??
                    _me?.userId ??
                    (_error != null ? '— ($_error)' : 'Carregando…'),
                style: bodyStyle(context),
              ),
              subtitle: Text(
                _me?.phoneE164 ?? '',
                style: labelStyle(context),
              ),
            ),
          ),
          const SizedBox(height: AppSpace.l),

          // Dados do cadastro
          if (_me?.fullName != null || _me?.birthDate != null) ...[
            Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: AppSpace.l, vertical: AppSpace.s),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_me?.fullName != null)
                    Text(
                      'Nome: ${_me!.fullName}',
                      style: labelStyle(context),
                    ),
                  if (_me?.phoneE164 != null)
                    Text(
                      'Telefone: ${_me!.phoneE164}',
                      style: labelStyle(context),
                    ),
                  if (_me?.birthDate != null)
                    Text(
                      'Nasc.: ${_me!.birthDate!.day}/${_me!.birthDate!.month}/${_me!.birthDate!.year}',
                      style: labelStyle(context),
                    ),
                  if (_me?.weight != null)
                    Text(
                      'Peso: ${_me!.weight!.toStringAsFixed(1)} kg',
                      style: labelStyle(context),
                    ),
                  if (_me?.height != null)
                    Text(
                      'Altura: ${_me!.height!.toStringAsFixed(2)} m',
                      style: labelStyle(context),
                    ),
                ],
              ),
            ),
            const SizedBox(height: AppSpace.l),

            // Botão editar perfil
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: t.primary,
                  side: BorderSide(color: t.primary),
                ),
                onPressed: () => Navigator.pushNamed(context, '/perfil-setup'),
                icon: Icon(Icons.edit, size: 18, color: t.primary),
                label: Text('EDITAR CADASTRO',
                    style: TextStyle(color: t.primary, fontWeight: FontWeight.w600)),
              ),
            ),
            const SizedBox(height: AppSpace.l),
          ],

          // Tema
          Text('Aparência', style: titleStyle(context)),
          const SizedBox(height: AppSpace.s),
          _Section(
            context: context,
            title: 'Aparência',
            children: [
              RadioGroup<ThemeModePref>(
                groupValue: _themeMode,
                onChanged: (v) {
                  if (v != null) _setTheme(v);
                },
                child: Column(
                  children: [
                    _themeTile(
                      context: context,
                      icon: Icons.brightness_high,
                      title: 'Claro',
                      subtitle: 'Sempre em cores claras',
                      value: ThemeModePref.light,
                      onChanged: _setTheme,
                    ),
                    const Divider(height: 1),
                    _themeTile(
                      context: context,
                      icon: Icons.brightness_low,
                      title: 'Escuro',
                      subtitle: 'Sempre em cores escuras',
                      value: ThemeModePref.dark,
                      onChanged: _setTheme,
                    ),
                    const Divider(height: 1),
                    _themeTile(
                      context: context,
                      icon: Icons.device_unknown,
                      title: 'Seguir o sistema',
                      subtitle: 'Usa a configuração do celular',
                      value: ThemeModePref.system,
                      onChanged: _setTheme,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.l),

          // Raspadinha de Prêmios e convites (3.8)
          _Section(
            context: context,
            title: 'Ganhe mais',
            children: [
              _entry(context, Icons.card_giftcard, 'Raspadinha de prêmios', () {
                Navigator.pushNamed(context, '/scratch-campaigns');
              }),
              _entry(
                  context,
                  Icons.person_add_alt_1_outlined,
                  'Convide motoristas',
                  () {
                    Navigator.pushNamed(context, '/invite');
                  }),
            ],
          ),
          const SizedBox(height: AppSpace.xl),

          // Privacidade (LGPD)
          Text('Privacidade (LGPD)', style: titleStyle(context)),
          const SizedBox(height: AppSpace.s),
          Card(
            color: t.surface,
            child: Column(children: [
              SwitchListTile(
                value: true,
                onChanged: null,
                title: Text(
                  'Compartilhar dados de viagem para melhorar rotas',
                  style: bodyStyle(context),
                ),
                subtitle: Text(
                  'Finalidade: rota e ETA — revogável',
                  style: labelStyle(context),
                ),
              ),
              const Divider(height: 1),
              SwitchListTile(
                value: false,
                onChanged: null,
                title: Text(
                  'Marketing e promoções',
                  style: bodyStyle(context),
                ),
                subtitle: Text(
                  'Finalidade: anúncios — revogável',
                  style: labelStyle(context),
                ),
              ),
            ]),
          ),
        ],
      ),
    );
  }

  static Widget _entry(
    BuildContext context,
    IconData icon,
    String label,
    VoidCallback onTap,
  ) {
    final t = tokensOf(context);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: t.primary),
      title: Text(label, style: TextStyle(fontSize: 15, color: t.ink)),
      trailing: Icon(Icons.chevron_right, color: t.muted),
      onTap: onTap,
    );
  }

  static Widget _themeTile({
    required BuildContext context,
    required IconData icon,
    required String title,
    required String subtitle,
    required ThemeModePref value,
    required ValueChanged<ThemeModePref> onChanged,
  }) {
    final t = tokensOf(context);
    return ListTile(
      leading: Icon(icon, color: t.primary),
      title: Text(title,
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: t.ink)),
      subtitle: Text(subtitle, style: TextStyle(fontSize: 13, color: t.muted)),
      // Sem groupValue/onChanged: quem agrupa é o RadioGroup acima.
      trailing: Radio<ThemeModePref>(
        value: value,
        activeColor: t.primary,
      ),
      onTap: () => onChanged(value),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({
    required this.context,
    required this.title,
    required this.children,
  });
  final BuildContext context;
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title.toUpperCase(),
            style: TextStyle(
                fontSize: 12,
                letterSpacing: 1,
                color: t.muted,
                fontWeight: FontWeight.w600)),
        const SizedBox(height: AppSpace.s),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.l),
          decoration: BoxDecoration(
            color: t.surface,
            borderRadius: BorderRadius.circular(AppSpace.radiusCard),
            border: Border.all(color: t.hairline.withValues(alpha: 0.35)),
          ),
          child: Column(children: children),
        ),
      ],
    );
  }
}
