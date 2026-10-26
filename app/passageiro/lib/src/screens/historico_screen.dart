import 'package:flutter/material.dart';

import '../api/client.dart';
import '../api/route_service.dart';
import '../../main.dart';
import '../theme/theme.dart';
import 'detalhe_corrida_screen.dart';

/// C9 Histórico — lista do GET /rides (cursor paginado, mais recente primeiro).
/// Estados: vazio / carregando / erro com retry (F2).
class HistoricoScreen extends StatefulWidget {
  const HistoricoScreen({super.key});

  @override
  State<HistoricoScreen> createState() => _HistoricoScreenState();
}

class _HistoricoScreenState extends State<HistoricoScreen> {
  List<Ride>? _rides;
  String? _error;
  bool _loading = false;

  bool _loaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // AppScope.of/apiOf exige didChangeDependencies (não initState).
    if (!_loaded) {
      _loaded = true;
      _load();
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rides = await AppScope.apiOf(context).rideHistory();
      if (mounted) setState(() => _rides = rides);
    } on ApiProblem catch (p) {
      if (mounted) setState(() => _error = p.code);
    } catch (_) {
      if (mounted) setState(() => _error = 'offline');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Histórico')),
      body: _loading && _rides == null
          ? const Center(child: CircularProgressIndicator())
          : _error != null && _rides == null
              ? Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Text('Não carregou ($_error)'),
                    const SizedBox(height: AppSpace.m),
                    FilledButton(
                        onPressed: _load, child: const Text('Tentar de novo')),
                  ]),
                )
              : (_rides == null || _rides!.isEmpty)
                  ? const Center(child: Text('Nenhuma corrida ainda'))
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView.separated(
                        itemCount: _rides!.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (context, i) {
                          final r = _rides![i];
                          return ListTile(
                            onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => DetalheCorridaScreen(ride: r),
                              ),
                            ),
                            leading: Icon(
                              r.status.isCancelled
                                  ? Icons.cancel_outlined
                                  : Icons.local_taxi_outlined,
                              color: r.status.isCancelled
                                  ? AppColors.danger
                                  : AppColors.primary,
                            ),
                            title: Text(r.destinationAddress ?? 'Corrida'),
                            subtitle: Text([
                              r.status.label,
                              // O km é o congelado no pedido: o mesmo que a
                              // cotação, a oferta do parceiro e o recibo.
                              if (r.distanceKm != null)
                                RouteResult.kmLabel(r.distanceKm!),
                              r.createdAtLabel,
                            ].join(' · ')),
                            trailing: r.fareTotal != null
                                ? Text(brl(r.fareTotal!))
                                : null,
                          );
                        },
                      ),
                    ),
    );
  }
}
