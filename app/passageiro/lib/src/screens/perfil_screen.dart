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
    if (mounted) setState(() => _themeMode = mode);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);

    return Scaffold(
      backgroundColor: t.colorScheme.surface,
      appBar: AppBar(
        title: Text('Perfil', style: titleStyle(context)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(AppSpace.l),
        children: [
          // Identidade
          Card(
            color: t.colorScheme.surface,
            child: ListTile(
              leading: const CircleAvatar(child: Icon(Icons.person)),
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
                onPressed: () => Navigator.pushNamed(context, '/perfil-setup'),
                icon: const Icon(Icons.edit, size: 18),
                label: const Text('EDITAR CADASTRO'),
              ),
            ),
            const SizedBox(height: AppSpace.l),
          ],

          // Tema
          Text('Aparência', style: titleStyle(context)),
          const SizedBox(height: AppSpace.s),
          Card(
            color: t.colorScheme.surface,
            child: RadioGroup<ThemeModePref>(
              groupValue: _themeMode,
              onChanged: (v) {
                if (v != null) _setTheme(v);
              },
              child: Column(
                children: [
                  _themeTile(
                    icon: Icons.brightness_high,
                    title: 'Claro',
                    subtitle: 'Sempre em cores claras',
                    value: ThemeModePref.light,
                    onChanged: _setTheme,
                  ),
                  const Divider(height: 1),
                  _themeTile(
                    icon: Icons.brightness_low,
                    title: 'Escuro',
                    subtitle: 'Sempre em cores escuras',
                    value: ThemeModePref.dark,
                    onChanged: _setTheme,
                  ),
                  const Divider(height: 1),
                  _themeTile(
                    icon: Icons.device_unknown,
                    title: 'Seguir o sistema',
                    subtitle: 'Usa a configuração do celular',
                    value: ThemeModePref.system,
                    onChanged: _setTheme,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: AppSpace.l),

          // Raspadinha de Prêmios e convites (3.8)
          _Section(
            title: 'Ganhe mais',
            children: [
              _entry(Icons.card_giftcard, 'Raspadinha de prêmios', () {
                Navigator.pushNamed(context, '/scratch-campaigns');
              }),
              _entry(Icons.person_add_alt_1_outlined, 'Convide motoristas', () {
                Navigator.pushNamed(context, '/invite');
              }),
            ],
          ),
          const SizedBox(height: AppSpace.xl),

          // Privacidade (LGPD)
          Text('Privacidade (LGPD)', style: titleStyle(context)),
          const SizedBox(height: AppSpace.s),
          Card(
            color: t.colorScheme.surface,
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

  static Widget _entry(IconData icon, String label, VoidCallback onTap) =>
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(icon, color: AppColors.primary),
        title: Text(label,
            style: const TextStyle(fontSize: 15, color: AppColors.ink)),
        trailing:
            const Icon(Icons.chevron_right, color: AppColors.onGraphiteMuted),
        onTap: onTap,
      );

  static Widget _themeTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required ThemeModePref value,
    required ValueChanged<ThemeModePref> onChanged,
  }) {
    return ListTile(
      leading: Icon(icon, color: AppColors.primary),
      title: Text(title,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
      subtitle: Text(subtitle, style: const TextStyle(fontSize: 13)),
      // Sem groupValue/onChanged: quem agrupa é o RadioGroup acima.
      trailing: Radio<ThemeModePref>(
        value: value,
        activeColor: AppColors.primary,
      ),
      onTap: () => onChanged(value),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title.toUpperCase(),
            style: TextStyle(
                fontSize: 12,
                letterSpacing: 1,
                color: t.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600)),
        const SizedBox(height: AppSpace.s),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.l),
          decoration: BoxDecoration(
            color: AppColors.graphite,
            borderRadius: BorderRadius.circular(AppSpace.radiusCard),
          ),
          child: Column(children: children),
        ),
      ],
    );
  }
}
