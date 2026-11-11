import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Base da API do app — o radar consulta o MESMO backend do resto do app
/// (POST /partner/online publica a presença; GET /partners/nearby a lê).
/// `RADAR_BASE` continua servindo para apontar a Edge Function dedicada.
const _apiBase = String.fromEnvironment(
  'API_BASE',
  defaultValue: 'http://10.0.2.2:8787',
);

/// Base do radar de **demonstração**: a API de demo servindo
/// `/partners/nearby` (motoristas sintéticos).
///
/// Só vale no modo demo. Com o backend real ligado, mostrar motorista
/// sintético seria mentira — lá o radar é o do Postgres (`RADAR_BASE`) e,
/// sem ele, a tela diz "radar indisponível".
const demoRadarBase = '$_apiBase/partners';

/// Base do radar REAL (Edge Function `radar` — Postgres).
///
/// **Vazio = sem radar real**: o app não tem onde buscar motorista de
/// verdade. O build de piloto define `RADAR_BASE`.
const envRadarBase = String.fromEnvironment('RADAR_BASE', defaultValue: '');

/// Base usada quando nada é injetado: a de demonstração.
const defaultRadarBase = demoRadarBase;

/// JWT do usuário (mesmo token do login). No backend da demo a sessão já
/// identifica o passageiro; em produção a Edge Function exige o token.
const defaultRadarToken = String.fromEnvironment('RADAR_TOKEN');

/// Motorista como o passageiro pode ver antes do aceite: posição aproximada,
/// distância arredondada e id pseudônimo — nada de identidade.
class RadarDriver {
  const RadarDriver({
    required this.driverId,
    required this.lat,
    required this.lon,
    required this.distanceKm,
    this.vehicle,
  });

  final String driverId;
  final double lat;
  final double lon;
  final double distanceKm;
  final String? vehicle;

  bool get available => true;
}

class RadarSnapshot {
  const RadarSnapshot({
    required this.drivers,
    required this.eligibleCount,
    required this.radiusKm,
    required this.generatedAt,
  });

  final List<RadarDriver> drivers;
  final int eligibleCount;
  final double radiusKm;
  final DateTime generatedAt;
}

class RadarProblem implements Exception {
  const RadarProblem(this.code, {this.status, this.title});

  final String code;
  final int? status;
  final String? title;

  @override
  String toString() => 'RadarProblem($code, $status, $title)';
}

class RadarApi {
  RadarApi({
    this.baseUrl = defaultRadarBase,
    this.token = defaultRadarToken,
    FutureOr<String> Function()? tokenProvider,
    http.Client? client,
    this.timeout = const Duration(seconds: 7),
  })  : _tokenProvider = tokenProvider,
        _client = client ?? http.Client();

  final String baseUrl;
  final String token;
  final Duration timeout;
  final http.Client _client;

  /// Fornecedor do token da sessão. É assíncrono porque o serviço de auth
  /// renova a sessão quando o token está perto de vencer — o radar real
  /// (`radar` no Postgres) exige o JWT do passageiro.
  final FutureOr<String> Function()? _tokenProvider;

  /// O radar existe com backend configurado. O token é opcional porque o
  /// backend do app já autentica a sessão; a Edge Function dedicada usa
  /// `RADAR_TOKEN` quando presente.
  bool get configured => baseUrl.isNotEmpty;

  Future<String> _bearer() async {
    final provider = _tokenProvider;
    if (provider != null) return await provider();
    return token;
  }

  Future<RadarSnapshot> nearby({
    required double lat,
    required double lon,
    double radiusKm = 5,
  }) async {
    if (!configured) {
      throw const RadarProblem('radar_unconfigured');
    }
    // A base pode já ser o endpoint completo (RADAR_BASE antigo apontava para
    // `.../partners/nearby`): nunca duplicar o sufixo, senão a consulta cai em
    // 404 e a tela anuncia "radar indisponível" mesmo com backend no ar.
    final base = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    final uri = Uri.parse(
            base.endsWith('/nearby') ? base : '$base/nearby')
        .replace(queryParameters: {
      'lat': lat.toString(),
      'lon': lon.toString(),
      'radius_km': radiusKm.toString(),
    });
    final bearer = await _bearer();
    final res = await _client.get(uri, headers: {
      if (bearer.isNotEmpty) 'authorization': 'Bearer $bearer',
      'accept': 'application/json',
    }).timeout(timeout);

    if (res.statusCode != 200) {
      throw _problem(res);
    }
    final json = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final drivers = ((json['drivers'] as List?) ?? const [])
        .map((e) => _driver(e as Map<String, dynamic>))
        .whereType<RadarDriver>()
        .toList();
    return RadarSnapshot(
      drivers: drivers,
      eligibleCount: (json['eligible_count'] as num?)?.toInt() ?? drivers.length,
      radiusKm: (json['radius_km'] as num?)?.toDouble() ?? radiusKm,
      generatedAt: DateTime.tryParse(json['generated_at'] as String? ?? '') ??
          DateTime.now(),
    );
  }

  static RadarDriver? _driver(Map<String, dynamic> j) {
    final lat = (j['lat'] as num?)?.toDouble();
    final lon = (j['lon'] as num?)?.toDouble();
    if (lat == null || lon == null) return null;
    return RadarDriver(
      driverId: j['driver_id'] as String? ?? '',
      lat: lat,
      lon: lon,
      distanceKm: (j['distance_km'] as num?)?.toDouble() ?? 0,
      vehicle: j['vehicle'] as String?,
    );
  }

  static RadarProblem _problem(http.Response res) {
    try {
      // `res.body` respeita o charset do header; o code é ASCII e continua
      // legível mesmo se o servidor omitir o charset.
      final j = jsonDecode(res.body) as Map<String, dynamic>;
      return RadarProblem(
        j['code'] as String? ?? 'radar_error',
        status: res.statusCode,
        title: j['title'] as String?,
      );
    } catch (_) {
      return RadarProblem('radar_error', status: res.statusCode);
    }
  }
}
