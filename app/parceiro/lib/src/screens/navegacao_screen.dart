import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:ten_map/ten_map.dart';

import '../../main.dart';
import '../api/client.dart';
import '../location/location_service.dart';
import '../theme/theme.dart';

/// Navegação do parceiro: mapa em tela cheia com a rota por ruas e as
/// instruções curva a curva (OSRM `steps=true`).
///
/// Alvo: o ponto de embarque enquanto a corrida não começou; o destino
/// depois de "passageiro a bordo". A posição de partida é o GPS do aparelho
/// (sem GPS, o embarque do pedido — a tela avisa).
class NavegacaoScreen extends StatefulWidget {
  const NavegacaoScreen({super.key, this.location = const LocationService()});

  final LocationService location;

  @override
  State<NavegacaoScreen> createState() => _NavegacaoScreenState();
}

class _NavegacaoScreenState extends State<NavegacaoScreen> {
  static const _osrm = 'https://router.project-osrm.org/route/v1/driving';

  bool _loading = true;
  String? _error;
  LatLng? _from;
  LatLng? _to;
  List<LatLng> _points = const [];
  List<_Step> _steps = const [];
  double _km = 0;
  int _min = 0;
  bool _gpsFallback = false;

  bool _started = false;

  // AppScope (corrida ativa) é InheritedWidget: ler no initState lança
  // "dependOnInheritedWidgetOfExactType was called before initState
  // completed" e a tela abria sem mapa nenhum. didChangeDependencies roda
  // depois do primeiro build e é o lugar certo para começar a carregar.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _load();
  }

  Future<void> _load() async {
    final partner = AppScope.of(context);
    final ride = partner.ride;
    if (ride == null) {
      setState(() {
        _loading = false;
        _error = 'Nenhuma corrida ativa.';
      });
      return;
    }
    final target = ride.status == RideStatus.emViagem
        ? ride.destination
        : ride.origin;
    if (target == null) {
      setState(() {
        _loading = false;
        _error = 'A corrida não tem o ponto de destino.';
      });
      return;
    }
    LatLng from;
    try {
      final fix = await widget.location.current(
        timeout: const Duration(seconds: 8),
      );
      from = LatLng(fix.lat, fix.lon);
    } catch (_) {
      final origin = ride.origin;
      if (origin == null) {
        setState(() {
          _loading = false;
          _error = 'Sem GPS e sem embarque para começar a navegação.';
        });
        return;
      }
      from = LatLng(origin.lat, origin.lon);
      _gpsFallback = true;
    }
    if (!mounted) return;
    setState(() {
      _from = from;
      _to = LatLng(target.lat, target.lon);
    });
    await _fetchRoute(from, _to!);
  }

  Future<void> _fetchRoute(LatLng from, LatLng to) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final url = Uri.parse('$_osrm/${from.longitude},${from.latitude};'
        '${to.longitude},${to.latitude}'
        '?overview=full&geometries=geojson&steps=true');
    try {
      final res = await http.get(url, headers: {
        'User-Agent': 'app.dezemais.parceiro/1.0',
      }).timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) throw const FormatException('OSRM');
      final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      final routes = (data['routes'] as List?) ?? const [];
      if (routes.isEmpty) throw const FormatException('sem rota');
      final route = routes.first as Map<String, dynamic>;
      final coords = ((route['geometry'] as Map?)?['coordinates'] as List?) ??
          const [];
      final points = [
        for (final c in coords)
          LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()),
      ];
      final steps = <_Step>[];
      for (final leg in (route['legs'] as List?) ?? const []) {
        for (final s in (leg['steps'] as List?) ?? const []) {
          final m = (s['maneuver'] as Map?) ?? const {};
          steps.add(_Step(
            text: _instruction(
              m['type'] as String?,
              m['modifier'] as String?,
              s['name'] as String?,
              m['exit'] as int?,
            ),
            icon: _icon(m['type'] as String?, m['modifier'] as String?),
            meters: ((s['distance'] as num?) ?? 0).toDouble(),
          ));
        }
      }
      if (!mounted) return;
      setState(() {
        _points = points;
        _steps = steps;
        _km = ((route['distance'] as num?) ?? 0).toDouble() / 1000;
        _min = (((route['duration'] as num?) ?? 0).toDouble() / 60).ceil();
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Não foi possível traçar a rota agora. Verifique a conexão.';
      });
    }
  }

  static IconData _icon(String? type, String? modifier) {
    if (type == 'arrive') return Icons.flag_rounded;
    if (type == 'depart') return Icons.navigation_rounded;
    if (type == 'roundabout' || type == 'rotary') return Icons.loop_rounded;
    switch (modifier) {
      case 'left':
      case 'sharp left':
      case 'slight left':
        return Icons.turn_left_rounded;
      case 'right':
      case 'sharp right':
      case 'slight right':
        return Icons.turn_right_rounded;
      case 'uturn':
        return Icons.u_turn_left_rounded;
      default:
        return Icons.straight_rounded;
    }
  }

  static String _instruction(
      String? type, String? modifier, String? name, int? exit) {
    final via = (name == null || name.trim().isEmpty) ? 'a via' : 'na ${name.trim()}';
    switch (type) {
      case 'depart':
        return 'Siga $via';
      case 'arrive':
        return 'Chegue ao destino';
      case 'roundabout':
      case 'rotary':
        return exit == null
            ? 'Entre na rotatória'
            : 'Na rotatória, pegue a $exitª saída';
      case 'merge':
        return 'Entre $via';
      case 'on ramp':
        return 'Pegue o acesso $via';
      case 'off ramp':
        return 'Saia $via';
      case 'fork':
        return modifier == 'left'
            ? 'Mantenha-se à esquerda $via'
            : 'Mantenha-se à direita $via';
      case 'end of road':
        return modifier == 'left'
            ? 'No fim da via, vire à esquerda $via'
            : 'No fim da via, vire à direita $via';
      case 'new name':
      case 'continue':
        return 'Continue $via';
      case 'turn':
        if (modifier == 'left' || modifier == 'sharp left' ||
            modifier == 'slight left') {
          return 'Vire à esquerda $via';
        }
        if (modifier == 'uturn') return 'Faça o retorno $via';
        return 'Vire à direita $via';
    }
    return 'Siga $via';
  }

  static String _distance(double meters) {
    if (meters < 1000) return '${meters.round()} m';
    return '${(meters / 1000).toStringAsFixed(1).replaceAll('.', ',')} km';
  }

  @override
  Widget build(BuildContext context) {
    final from = _from;
    final to = _to;
    return Scaffold(
      appBar: AppBar(title: const Text('Navegação')),
      body: from == null || to == null
          ? _estado(context)
          : Stack(
              children: [
                // Mesmo mapa vetorial do resto do app (Console Noturno):
                // o traçado é o que o parceiro segue, então ele fica acima
                // do calor e abaixo dos rótulos da rua.
                RouteMapView(
                  points: _points,
                  driver: from,
                  destination: to,
                  padding: 48,
                ),
                SafeArea(
                  child: Column(
                    children: [
                      _banner(context),
                      const Spacer(),
                      _painel(),
                    ],
                  ),
                ),
              ],
            ),
      );
  }

  Widget _estado(BuildContext context) {
    final t = tokensOf(context);
    return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.xl),
          child: _error != null
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.wrong_location_outlined,
                        size: 34, color: t.warning),
                    const SizedBox(height: AppSpace.s),
                    Text(_error!, textAlign: TextAlign.center),
                    const SizedBox(height: AppSpace.m),
                    FilledButton(
                        onPressed: () {
                          setState(() => _error = null);
                          _load();
                        },
                        child: const Text('Tentar de novo')),
                  ],
                )
              : const CircularProgressIndicator(),
        ),
      );
  }

  Widget _banner(BuildContext context) {
    final next = _steps.isEmpty ? null : _steps.first;
    final t = tokensOf(context);
    return Container(
      margin: const EdgeInsets.all(AppSpace.m),
      padding: const EdgeInsets.all(AppSpace.l),
      decoration: BoxDecoration(
        color: t.primary,
        borderRadius: BorderRadius.circular(AppSpace.radiusCard),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.2),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Row(children: [
        Icon(next?.icon ?? Icons.navigation_rounded,
            color: Colors.white, size: 30),
        const SizedBox(width: AppSpace.m),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                next?.text ?? (_loading ? 'Traçando a rota…' : 'Siga em frente'),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
              ),
              if (next != null && next.meters > 0)
                Text('em ${_distance(next.meters)}',
                    style: const TextStyle(
                        color: Colors.white70, fontSize: 12)),
            ],
          ),
        ),
      ]),
    );
  }

  Widget _painel() {
    final t = tokensOf(context);
    return Container(
      margin: const EdgeInsets.all(AppSpace.m),
      padding: const EdgeInsets.all(AppSpace.l),
      constraints: const BoxConstraints(maxHeight: 300),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(AppSpace.radiusSheet),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.18),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Icon(Icons.route_rounded, size: 18, color: t.primary),
            const SizedBox(width: 6),
            Text(
              _loading
                  ? 'Calculando…'
                  : 'Restam ${_distance(_km * 1000)} · $_min min',
              style: AppType.title.copyWith(fontSize: 15),
            ),
            const Spacer(),
            if (_gpsFallback)
              Text('GPS indisponível',
                  style: TextStyle(fontSize: 11, color: t.warning)),
            const SizedBox(width: 6),
            IconButton(
              tooltip: 'Recalcular rota',
              onPressed: _from == null || _to == null
                  ? null
                  : () => _fetchRoute(_from!, _to!),
              icon: const Icon(Icons.refresh_rounded, size: 20),
            ),
          ]),
          const Divider(height: AppSpace.l),
          Expanded(
            child: ListView.builder(
              padding: EdgeInsets.zero,
              itemCount: _steps.length,
              itemBuilder: (context, i) {
                final s = _steps[i];
                return ListTile(
                  dense: true,
                  leading: Icon(s.icon,
                      size: 22,
                      color: i == 0 ? t.primary : t.muted),
                  title: Text(s.text,
                      style: TextStyle(
                        fontWeight:
                            i == 0 ? FontWeight.w700 : FontWeight.w400,
                        color: t.ink,
                      )),
                  trailing: Text(_distance(s.meters),
                      style: AppType.label.copyWith(fontSize: 12)),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _Step {
  const _Step({required this.text, required this.icon, required this.meters});
  final String text;
  final IconData icon;
  final double meters;
}
