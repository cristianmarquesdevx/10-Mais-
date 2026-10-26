import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Edge Function `radar` no Supabase. Sem backend/token, o parceiro não
/// aparece para ninguém — e a tela avisa em vez de fingir presença.
const defaultRadarBase = String.fromEnvironment(
  'RADAR_BASE',
  defaultValue: 'http://10.0.2.2:54321/functions/v1/radar',
);

const defaultRadarToken = String.fromEnvironment('RADAR_TOKEN');

class PresenceProblem implements Exception {
  const PresenceProblem(this.code, {this.status});

  final String code;
  final int? status;

  @override
  String toString() => 'PresenceProblem($code, $status)';
}

class PresenceApi {
  PresenceApi({
    this.baseUrl = defaultRadarBase,
    this.token = defaultRadarToken,
    http.Client? client,
    this.timeout = const Duration(seconds: 7),
  }) : _client = client ?? http.Client();

  final String baseUrl;
  final String token;
  final Duration timeout;
  final http.Client _client;

  bool get configured => token.isNotEmpty && baseUrl.isNotEmpty;

  /// `ONLINE_DISPONIVEL` | `PAUSA` | `OFFLINE`. Posição é obrigatória nos dois
  /// primeiros (o servidor recusa sem ela).
  Future<void> setStatus(
    String status, {
    double? lat,
    double? lon,
  }) async {
    if (!configured) throw const PresenceProblem('presence_unconfigured');
    final res = await _client
        .post(
          Uri.parse('$baseUrl/presence'),
          headers: {
            'authorization': 'Bearer $token',
            'content-type': 'application/json',
          },
          body: jsonEncode({
            'status': status,
            if (lat != null) 'lat': lat,
            if (lon != null) 'lon': lon,
          }),
        )
        .timeout(timeout);

    if (res.statusCode != 200) {
      String code = 'presence_error';
      try {
        final j = jsonDecode(res.body) as Map<String, dynamic>;
        code = j['code'] as String? ?? code;
      } catch (_) {
        // corpo não-JSON: mantém o código genérico
      }
      throw PresenceProblem(code, status: res.statusCode);
    }
  }
}
