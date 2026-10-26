import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

/// Rota de carro entre dois pontos — o traçado que o mapa desenha.
///
/// [approx] = true quando o servidor de rotas não respondeu e o app caiu numa
/// linha aproximada (nunca deixamos o mapa vazio por causa de rede).
class RouteResult {
  const RouteResult({
    required this.points,
    required this.distanceMeters,
    required this.durationSeconds,
    this.approx = false,
  });

  final List<LatLng> points;
  final double distanceMeters;
  final double durationSeconds;
  final bool approx;

  double get km => distanceMeters / 1000;

  int get minutes => (durationSeconds / 60).ceil();

  /// Rótulo pt-BR curto: `7,2 km · 14 min` (ou `−` quando não há rota).
  String get label => points.length < 2 && distanceMeters == 0
      ? '—'
      : '${kmLabel(km)} · $minutes min';

  static String kmLabel(double km) {
    if (km < 1) return '${(km * 1000).round()} m';
    return '${km.toStringAsFixed(1).replaceAll('.', ',')} km';
  }
}

/// Roteamento real por ruas (OSRM) com fallback local.
///
/// O endpoint público do OSRM é usado na demo; em produção isso vira um
/// serviço próprio da 10 é + (mesma assinatura de [route]).
class RouteService {
  RouteService({
    http.Client? client,
    this.baseUrl = 'https://router.project-osrm.org',
    this.timeout = const Duration(seconds: 7),
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final String baseUrl;
  final Duration timeout;

  /// Cache pequeno por par origem→destino (evita refazer a mesma rota a cada
  /// rebuild da tela).
  final Map<String, RouteResult> _cache = {};
  static const _cacheMax = 32;

  static String _key(LatLng a, LatLng b) =>
      '${a.latitude.toStringAsFixed(5)},${a.longitude.toStringAsFixed(5)}>'
      '${b.latitude.toStringAsFixed(5)},${b.longitude.toStringAsFixed(5)}';

  /// Traça a rota de carro [from] → [to]. Sempre devolve um resultado: se o
  /// OSRM falhar, cai na linha aproximada (Haversine × 1,35, 28 km/h).
  Future<RouteResult> route(LatLng from, LatLng to) async {
    final key = _key(from, to);
    final cached = _cache[key];
    if (cached != null) return cached;

    RouteResult result;
    try {
      result = await _fetch(from, to);
    } catch (_) {
      result = _approx(from, to);
    }
    if (_cache.length >= _cacheMax) _cache.remove(_cache.keys.first);
    _cache[key] = result;
    return result;
  }

  Future<RouteResult> _fetch(LatLng from, LatLng to) async {
    final url = Uri.parse(
      '$baseUrl/route/v1/driving/'
      '${from.longitude},${from.latitude};${to.longitude},${to.latitude}'
      '?overview=full&geometries=polyline&alternatives=false&steps=false',
    );
    final res = await _client.get(url, headers: const {
      // Política do OSRM demo: identificar a aplicação.
      'User-Agent': 'app.dezemais.passageiro/0.1',
      'Accept': 'application/json',
    }).timeout(timeout);
    if (res.statusCode != 200) {
      throw StateError('OSRM ${res.statusCode}');
    }
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    final routes = (json['routes'] as List?) ?? const [];
    if (routes.isEmpty) throw StateError('OSRM sem rota');
    final r = routes.first as Map<String, dynamic>;
    final pts = decodePolyline(r['geometry'] as String? ?? '');
    if (pts.length < 2) throw StateError('OSRM sem geometria');
    return RouteResult(
      points: pts,
      distanceMeters: (r['distance'] as num).toDouble(),
      durationSeconds: (r['duration'] as num).toDouble(),
    );
  }

  static RouteResult _approx(LatLng from, LatLng to) {
    const d = Distance();
    final meters = d.as(LengthUnit.Meter, from, to);
    // Fator de sinuosidade urbana + velocidade média de 28 km/h.
    final road = meters * 1.35;
    return RouteResult(
      points: [from, to],
      distanceMeters: road,
      durationSeconds: road / (28000 / 3600),
      approx: true,
    );
  }
}

/// Decodifica a polyline de precisão 5 usada pelo OSRM/Google.
List<LatLng> decodePolyline(String encoded) {
  final points = <LatLng>[];
  var index = 0;
  var lat = 0;
  var lng = 0;
  while (index < encoded.length) {
    var shift = 0;
    var result = 0;
    int byte;
    do {
      byte = encoded.codeUnitAt(index++) - 63;
      result |= (byte & 0x1f) << shift;
      shift += 5;
    } while (byte >= 0x20);
    lat += (result & 1) != 0 ? ~(result >> 1) : (result >> 1);

    shift = 0;
    result = 0;
    do {
      byte = encoded.codeUnitAt(index++) - 63;
      result |= (byte & 0x1f) << shift;
      shift += 5;
    } while (byte >= 0x20);
    lng += (result & 1) != 0 ? ~(result >> 1) : (result >> 1);

    points.add(LatLng(lat / 1e5, lng / 1e5));
  }
  return points;
}

/// Distância em linha reta (metros) — usada em resumos/ordenação.
double straightMeters(LatLng a, LatLng b) {
  const earth = 6371000.0;
  final dLat = (b.latitude - a.latitude) * math.pi / 180;
  final dLon = (b.longitude - a.longitude) * math.pi / 180;
  final h = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(a.latitude * math.pi / 180) *
          math.cos(b.latitude * math.pi / 180) *
          math.sin(dLon / 2) *
          math.sin(dLon / 2);
  return 2 * earth * math.asin(math.min(1, math.sqrt(h)));
}
