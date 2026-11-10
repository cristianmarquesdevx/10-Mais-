import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Edge Function `radar` no Supabase. Sem backend/token, o parceiro não
/// aparece para ninguém — e a tela avisa em vez de fingir presença.
const defaultRadarBase = String.fromEnvironment(
  'RADAR_BASE',
  defaultValue: 'http://10.0.2.2:54321/functions/v1/radar',
);

/// Token fixo (build de dev). Em uso normal o token vem da SESSÃO: o radar
/// exige o JWT do próprio parceiro, e é ele que impede um parceiro de
/// publicar presença no nome de outro.
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
    String? token,
    FutureOr<String> Function()? tokenProvider,
    http.Client? client,
    this.timeout = const Duration(seconds: 7),
  })  : _token = token,
        _tokenProvider = tokenProvider,
        _client = client ?? http.Client();

  final String baseUrl;

  /// Token fixo (build de dev). Tem precedência sobre nada: se houver um
  /// provider, ele manda — é a sessão real.
  final String? _token;

  /// Fornecedor do token da sessão. É assíncrono porque o serviço de auth
  /// renova a sessão quando o token está perto de vencer.
  final FutureOr<String> Function()? _tokenProvider;

  final Duration timeout;
  final http.Client _client;

  /// Sem token não há presença: o servidor recusa e o app não pode fingir
  /// que o parceiro está online.
  bool get configured =>
      baseUrl.isNotEmpty &&
      (_tokenProvider != null || (_token ?? '').isNotEmpty);

  Future<String> _bearer() async {
    final provider = _tokenProvider;
    if (provider != null) return await provider();
    return _token ?? '';
  }

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
            'authorization': 'Bearer ${await _bearer()}',
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
