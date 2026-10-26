import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../main.dart';
import '../api/client.dart';
import '../theme/theme.dart';

/// Tela de cadastro completo do motorista (3.7).
///
/// Exibida após o primeiro login (quando o cadastro está incompleto) e
/// também acessível a partir da tela de Perfil para atualização.
///
/// Campos obrigatórios: nome completo, celular, número da CNH, categoria da
/// CNH, validade da CNH, placa do veículo, modelo, ano.
/// Campos opcionais: foto de perfil.
///
/// Bloqueia o motorista de ficar online até que o cadastro esteja completo
/// e aprovado (KYC + verificação cadastral).
class PartnerSetupScreen extends StatefulWidget {
  const PartnerSetupScreen({super.key});

  @override
  State<PartnerSetupScreen> createState() => _PartnerSetupScreenState();
}

class _PartnerSetupScreenState extends State<PartnerSetupScreen> {
  final _nameCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _cnhCtrl = TextEditingController();
  final _cnhCategoryCtrl = TextEditingController();
  final _cnhExpiryCtrl = TextEditingController();
  final _plateCtrl = TextEditingController();
  final _modelCtrl = TextEditingController();
  final _yearCtrl = TextEditingController();

  DateTime? _cnhExpiryDate;
  bool _busy = false;
  String? _error;
  String? _success;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    _cnhCtrl.dispose();
    _cnhCategoryCtrl.dispose();
    _cnhExpiryCtrl.dispose();
    _plateCtrl.dispose();
    _modelCtrl.dispose();
    _yearCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickCnhExpiry() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _cnhExpiryDate ?? DateTime(now.year + 5),
      firstDate: DateTime(now.year - 5),
      lastDate: DateTime(now.year + 20),
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
        _cnhExpiryDate = picked;
        _cnhExpiryCtrl.text = DateFormat('dd/MM/yyyy').format(picked);
      });
    }
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
      _success = null;
    });

    try {
      await AppScope.apiOf(context).updatePartnerProfile(
        fullName:
            _nameCtrl.text.trim().isNotEmpty ? _nameCtrl.text.trim() : null,
        phoneE164:
            _phoneCtrl.text.trim().isNotEmpty ? _phoneCtrl.text.trim() : null,
        cnhNumber:
            _cnhCtrl.text.trim().isNotEmpty ? _cnhCtrl.text.trim() : null,
        cnhCategory: _cnhCategoryCtrl.text.trim().isNotEmpty
            ? _cnhCategoryCtrl.text.trim()
            : null,
        cnhExpiry: _cnhExpiryDate,
        vehiclePlate:
            _plateCtrl.text.trim().isNotEmpty ? _plateCtrl.text.trim() : null,
        vehicleModel:
            _modelCtrl.text.trim().isNotEmpty ? _modelCtrl.text.trim() : null,
        vehicleYear:
            _yearCtrl.text.trim().isNotEmpty ? _yearCtrl.text.trim() : null,
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _success = 'Cadastro atualizado com sucesso.';
      });
      await Future<void>.delayed(const Duration(seconds: 1));
      if (mounted) Navigator.pop(context, true);
    } on ApiProblem catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.code == 'unknown' ? 'Erro ao salvar cadastro.' : e.code;
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
        title: Text('Cadastro de motorista', style: titleStyle(context)),
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
                    'Preencha para completar seu cadastro de motorista. '
                    'Campos com * são obrigatórios.',
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
                    controller: _cnhCtrl,
                    keyboardType: TextInputType.number,
                    style: bodyStyle(context),
                    decoration: InputDecoration(
                      labelText: 'Número da CNH *',
                      labelStyle: labelStyle(context),
                      hintText: 'ex.: 123456789',
                      border: OutlineInputBorder(
                        borderRadius:
                            BorderRadius.circular(AppSpace.radiusCard),
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpace.m),
                  TextField(
                    controller: _cnhCategoryCtrl,
                    keyboardType: TextInputType.text,
                    style: bodyStyle(context),
                    decoration: InputDecoration(
                      labelText: 'Categoria da CNH *',
                      labelStyle: labelStyle(context),
                      hintText: 'ex.: AB',
                      border: OutlineInputBorder(
                        borderRadius:
                            BorderRadius.circular(AppSpace.radiusCard),
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpace.m),
                  TextField(
                    controller: _cnhExpiryCtrl,
                    readOnly: true,
                    onTap: _pickCnhExpiry,
                    style: bodyStyle(context),
                    decoration: InputDecoration(
                      labelText: 'Validade da CNH *',
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
                    controller: _plateCtrl,
                    keyboardType: TextInputType.text,
                    style: bodyStyle(context),
                    decoration: InputDecoration(
                      labelText: 'Placa do veículo *',
                      labelStyle: labelStyle(context),
                      hintText: 'ABC-1234',
                      border: OutlineInputBorder(
                        borderRadius:
                            BorderRadius.circular(AppSpace.radiusCard),
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpace.m),
                  TextField(
                    controller: _modelCtrl,
                    keyboardType: TextInputType.text,
                    style: bodyStyle(context),
                    decoration: InputDecoration(
                      labelText: 'Modelo do veículo *',
                      labelStyle: labelStyle(context),
                      hintText: 'ex.: Honda Biz',
                      border: OutlineInputBorder(
                        borderRadius:
                            BorderRadius.circular(AppSpace.radiusCard),
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpace.m),
                  TextField(
                    controller: _yearCtrl,
                    keyboardType: TextInputType.number,
                    style: bodyStyle(context),
                    decoration: InputDecoration(
                      labelText: 'Ano do veículo *',
                      labelStyle: labelStyle(context),
                      hintText: 'ex.: 2020',
                      border: OutlineInputBorder(
                        borderRadius:
                            BorderRadius.circular(AppSpace.radiusCard),
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpace.l),
                  const Text(
                    'Esses dados são usados para verificação cadastral e '
                    'segurança da plataforma. Você não poderá ficar online '
                    'até que o cadastro seja aprovado.',
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
                : const Text('SALVAR CADASTRO'),
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
