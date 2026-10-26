import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../main.dart';
import '../api/client.dart';
import '../theme/theme.dart';

/// Tela de cadastro completo do passageiro (3.6).
///
/// Exibida após o primeiro login (quando o perfil está incompleto) e também
/// acessível a partir da tela de Perfil para atualização.
///
/// Campos: nome completo, data de nascimento, peso, altura, telefone.
/// Peso e altura são opcionais (minimização de dados LGPD — finalidade
/// operacional apenas se justificada).
class ProfileSetupScreen extends StatefulWidget {
  const ProfileSetupScreen({super.key});

  @override
  State<ProfileSetupScreen> createState() => _ProfileSetupScreenState();
}

class _ProfileSetupScreenState extends State<ProfileSetupScreen> {
  final _nameCtrl = TextEditingController();
  final _birthDateCtrl = TextEditingController();
  final _weightCtrl = TextEditingController();
  final _heightCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();

  bool _busy = false;
  String? _error;
  String? _success;

  DateTime? _selectedBirthDate;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _birthDateCtrl.dispose();
    _weightCtrl.dispose();
    _heightCtrl.dispose();
    _phoneCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickBirthDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedBirthDate ?? DateTime(now.year - 18),
      firstDate: DateTime(now.year - 100),
      lastDate: DateTime(now.year - 13),
      builder: (context, child) => Theme(
        data: Theme.of(context).copyWith(
          colorScheme: const ColorScheme.light(
            primary: AppColors.primary,
            onPrimary: Colors.white,
            surface: AppColors.surface,
            onSurface: AppColors.ink,
          ),
        ),
        child: child!,
      ),
    );
    if (picked != null && mounted) {
      setState(() {
        _selectedBirthDate = picked;
        _birthDateCtrl.text = DateFormat('dd/MM/yyyy').format(picked);
      });
    }
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
      _success = null;
    });

    final birthDate = _selectedBirthDate;
    final weight = _weightCtrl.text.isNotEmpty
        ? double.tryParse(_weightCtrl.text.replaceAll(',', '.'))
        : null;
    final height = _heightCtrl.text.isNotEmpty
        ? double.tryParse(_heightCtrl.text.replaceAll(',', '.'))
        : null;

    try {
      await AppScope.apiOf(context).updateProfile(
        fullName:
            _nameCtrl.text.trim().isNotEmpty ? _nameCtrl.text.trim() : null,
        birthDate: birthDate,
        weight: weight,
        height: height,
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _success = 'Perfil atualizado com sucesso.';
      });
      // Recarrega o perfil na tela pai se houver callback
      await Future<void>.delayed(const Duration(seconds: 1));
      if (mounted) Navigator.pop(context, true);
    } on ApiProblem catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.code == 'unknown' ? 'Erro ao salvar perfil.' : e.code;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Erro inesperado ao salvar.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);

    return Scaffold(
      backgroundColor: t.background,
      appBar: AppBar(
        title: Text('Completar perfil', style: titleStyle(context)),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(AppSpace.l),
        children: [
          Card(
            color: t.surface,
            child: Padding(
              padding: const EdgeInsets.all(AppSpace.l),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Seus dados', style: titleStyle(context)),
                  const SizedBox(height: AppSpace.s),
                  Text(
                    'Preencha para completar seu cadastro. Campos com * são '
                    'obrigatórios.',
                    style: labelStyle(context),
                  ),
                  const SizedBox(height: AppSpace.l),
                  TextField(
                    controller: _nameCtrl,
                    autofocus: true,
                    style: bodyStyle(context),
                    decoration: InputDecoration(
                      labelText: 'Nome completo *',
                      labelStyle: labelStyle(context),
                      border: OutlineInputBorder(
                        borderRadius:
                            BorderRadius.circular(AppSpace.radiusCard),
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpace.m),
                  TextField(
                    controller: _phoneCtrl,
                    keyboardType: TextInputType.phone,
                    style: bodyStyle(context),
                    decoration: InputDecoration(
                      labelText: 'Celular *',
                      labelStyle: labelStyle(context),
                      hintText: '(69) 9 9999-9999',
                      prefixIcon: const Icon(Icons.phone_iphone),
                      border: OutlineInputBorder(
                        borderRadius:
                            BorderRadius.circular(AppSpace.radiusCard),
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpace.m),
                  TextField(
                    controller: _birthDateCtrl,
                    readOnly: true,
                    onTap: _pickBirthDate,
                    style: bodyStyle(context),
                    decoration: InputDecoration(
                      labelText: 'Data de nascimento *',
                      labelStyle: labelStyle(context),
                      hintText: 'dd/mm/aaaa',
                      suffixIcon: const Icon(Icons.calendar_today_outlined),
                      border: OutlineInputBorder(
                        borderRadius:
                            BorderRadius.circular(AppSpace.radiusCard),
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpace.m),
                  TextField(
                    controller: _weightCtrl,
                    keyboardType: TextInputType.number,
                    style: bodyStyle(context),
                    decoration: InputDecoration(
                      labelText: 'Peso (kg) — opcional',
                      labelStyle: labelStyle(context),
                      hintText: 'ex.: 75',
                      border: OutlineInputBorder(
                        borderRadius:
                            BorderRadius.circular(AppSpace.radiusCard),
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpace.m),
                  TextField(
                    controller: _heightCtrl,
                    keyboardType: TextInputType.number,
                    style: bodyStyle(context),
                    decoration: InputDecoration(
                      labelText: 'Altura (m) — opcional',
                      labelStyle: labelStyle(context),
                      hintText: 'ex.: 1.75',
                      border: OutlineInputBorder(
                        borderRadius:
                            BorderRadius.circular(AppSpace.radiusCard),
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpace.l),
                  const Text(
                    'Peso e altura são opcionais e servem apenas para '
                    'finalidades operacionais da plataforma. Você pode '
                    'ignorá-los.',
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.muted,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: AppSpace.l),
          if (_error != null)
            Container(
              padding: const EdgeInsets.all(AppSpace.m),
              decoration: BoxDecoration(
                color: AppColors.danger.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(AppSpace.radiusCard),
              ),
              child: Text(_error!,
                  style: const TextStyle(color: AppColors.danger)),
            ),
          if (_success != null)
            Container(
              padding: const EdgeInsets.all(AppSpace.m),
              decoration: BoxDecoration(
                color: AppColors.earn.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(AppSpace.radiusCard),
              ),
              child: Text(_success!,
                  style: const TextStyle(color: AppColors.earn)),
            ),
          const SizedBox(height: AppSpace.l),
          GradientButton(
            onPressed: _busy ? null : _save,
            child: _busy
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: AppColors.ink),
                  )
                : const Text('SALVAR PERFIL'),
          ),
          const SizedBox(height: AppSpace.m),
          OutlinedButton(
            onPressed: _busy ? null : () => Navigator.pop(context),
            child: const Text('Pular por agora'),
          ),
        ],
      ),
    );
  }
}
