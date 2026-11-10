import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Sessão emitida pelo Supabase Auth (GoTrue).
///
/// Guardamos o necessário para (a) autenticar as chamadas à API e (b) renovar
/// sozinho quando o access token expira — sem guardar senha nenhuma no
/// aparelho: o fluxo é por código de uso único.
class AuthSession {
  const AuthSession({
    required this.accessToken,
    required this.refreshToken,
    required this.userId,
    required this.email,
    this.phone = '',
    required this.expiresAt,
  });

  final String accessToken;
  final String refreshToken;
  final String userId;
  final String email;
  final String phone;
  final DateTime expiresAt;

  bool get isExpired =>
      DateTime.now().isAfter(expiresAt.subtract(const Duration(seconds: 60)));

  /// Como a conta se identifica para o usuário: o e-mail do cadastro ou, em
  /// conta criada por telefone, o número (nunca os dois vazios).
  String get identity => email.isNotEmpty ? email : phone;

  bool get isPhone => email.isEmpty && phone.isNotEmpty;

  Map<String, dynamic> toJson() => {
        'access_token': accessToken,
        'refresh_token': refreshToken,
        'user_id': userId,
        'email': email,
        'phone': phone,
        'expires_at': expiresAt.toIso8601String(),
      };

  static AuthSession? fromJson(Map<String, dynamic> j) {
    final access = j['access_token'] as String?;
    final refresh = j['refresh_token'] as String?;
    final user = j['user_id'] as String?;
    if (access == null || refresh == null || user == null) return null;
    return AuthSession(
      accessToken: access,
      refreshToken: refresh,
      userId: user,
      email: (j['email'] as String?) ?? '',
      phone: (j['phone'] as String?) ?? '',
      expiresAt: DateTime.tryParse((j['expires_at'] as String?) ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}

/// Por que a autenticação falhou. A tela decide por este enum, nunca pelo
/// texto da mensagem — o texto é para o usuário, o enum é para o código.
enum AuthFailure { offline, codeInvalid, codeExpired, rateLimited, rejected, unknown }

class AuthException implements Exception {
  AuthException(this.failure, this.message, {this.code});
  final AuthFailure failure;
  final String message;
  final String? code;

  @override
  String toString() => 'AuthException($failure, $code)';
}

/// Autenticação real contra o Supabase Auth (GoTrue).
///
/// Dois canais, o mesmo fluxo de código de uso único (sem senha):
///
///   `sendCode(email)`  → e-mail com código de 6 dígitos → `verifyCode`
///   `sendPhoneCode`    → SMS   com código de 6 dígitos → `verifyPhoneCode`
///
/// A sessão fica persistida e é renovada com o refresh token, de forma
/// single-flight (duas chamadas simultâneas não disparam duas renovações — o
/// GoTrue rotaciona o refresh token e a segunda seria rejeitada).
class AuthService extends ChangeNotifier {
  AuthService({
    required this.baseUrl,
    required this.anonKey,
    this.role = 'PASSENGER',
    http.Client? client,
  }) : _http = client ?? http.Client();

  /// Base do GoTrue, ex.: `http://10.0.2.2:54321/auth/v1` (sem barra no fim).
  final String baseUrl;

  /// Chave pública do projeto (publishable/anon). Não é segredo: quem protege
  /// os dados é o RLS + o token do usuário.
  final String anonKey;

  /// Papel criado no cadastro: PARTNER (app do parceiro) ou PASSENGER.
  final String role;

  final http.Client _http;
  static const _prefsKey = 'dezemais.auth.session.v1';

  AuthSession? _session;
  Future<void>? _refreshing;

  AuthSession? get session => _session;
  bool get isSignedIn => _session != null;
  String? get email => _session?.email;
  String? get phone => _session?.phone;
  String? get userId => _session?.userId;

  // --- ciclo de vida --------------------------------------------------------

  /// Recupera a sessão salva e, se estiver vencida, tenta renovar.
  ///
  /// Falha de rede mantém a sessão (o app volta quando a rede voltar); falha
  /// de credencial limpa tudo e o app volta para o login.
  Future<void> restore() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null) return;
    AuthSession? saved;
    try {
      saved = AuthSession.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } on FormatException {
      saved = null;
    }
    if (saved == null) {
      await prefs.remove(_prefsKey);
      return;
    }
    _session = saved;
    notifyListeners();
    if (saved.isExpired) {
      try {
        await _refresh();
      } on AuthException catch (e) {
        if (e.failure == AuthFailure.offline) return; // tenta de novo depois
        await signOut();
      }
    }
  }

  /// Pede o código de 6 dígitos por e-mail. Cria a conta se ainda não existir.
  Future<void> sendCode(String email) async {
    final clean = email.trim().toLowerCase();
    if (!_looksLikeEmail(clean)) {
      throw AuthException(AuthFailure.rejected, 'Informe um e-mail válido.');
    }
    await _call(
      'POST',
      '/otp',
      body: {
        'email': clean,
        'create_user': true,
        'data': {'role': role},
      },
    );
  }

  /// Pede o código de 6 dígitos por SMS. Cria a conta se ainda não existir.
  ///
  /// O GoTrue só aceita o número em E.164 (`+55…`), então a máscara da tela
  /// vira dígitos aqui — a tela mostra com parênteses, a rede não.
  Future<void> sendPhoneCode(String input) async {
    final phone = normalizePhone(input);
    if (!_looksLikePhone(phone)) {
      throw AuthException(
          AuthFailure.rejected, 'Informe DDD e número do celular.');
    }
    await _call(
      'POST',
      '/otp',
      body: {
        'phone': phone,
        'create_user': true,
        'data': {'role': role},
      },
    );
  }

  /// Troca o código do e-mail pela sessão.
  Future<void> verifyCode(String email, String code) async {
    final clean = email.trim().toLowerCase();
    final digits = _codeDigits(code);
    final body = await _call('POST', '/verify', body: {
      'type': 'email',
      'email': clean,
      'token': digits,
    });
    final session = _sessionFrom(body, fallbackEmail: clean);
    if (session == null) {
      throw AuthException(AuthFailure.unknown, 'Resposta de login sem sessão.');
    }
    await _save(session);
  }

  /// Troca o código do SMS pela sessão.
  Future<void> verifyPhoneCode(String input, String code) async {
    final phone = normalizePhone(input);
    final digits = _codeDigits(code);
    final body = await _call('POST', '/verify', body: {
      'type': 'sms',
      'phone': phone,
      'token': digits,
    });
    final session = _sessionFrom(body, fallbackPhone: phone);
    if (session == null) {
      throw AuthException(AuthFailure.unknown, 'Resposta de login sem sessão.');
    }
    await _save(session);
  }

  /// Registra o telefone na conta (melhor esforço).
  ///
  /// O piloto não tem provedor de SMS: o código chega por e-mail. Mesmo assim
  /// o telefone precisa ficar no backend — é a identidade de contato e o que o
  /// despacho mostra. O GoTrue aceita `PUT /user` com o telefone e o guarda
  /// só com dígitos; quem normaliza para E.164 é o trigger do banco.
  ///
  /// Devolve `true` quando o telefone foi gravado. Falha aqui NÃO é falha de
  /// login: a sessão já existe e o piloto funciona sem o telefone.
  Future<bool> attachPhone(String input) async {
    final phone = normalizePhone(input);
    if (!_looksLikePhone(phone)) return false;
    final token = _session?.accessToken;
    if (token == null || token.isEmpty) return false;
    try {
      await _call('PUT', '/user', token: token, body: {'phone': phone});
      return true;
    } on AuthException {
      return false;
    }
  }

  /// Encerra a sessão no servidor (melhor esforço) e apaga a local.
  Future<void> signOut() async {
    final token = _session?.accessToken;
    _session = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsKey);
    notifyListeners();
    if (token != null && token.isNotEmpty) {
      try {
        await _call('POST', '/logout', token: token);
      } on AuthException {
        // Sair é local: se o servidor não responder, a sessão já foi apagada.
      }
    }
  }

  /// Token para as chamadas de API, renovando antes de vencer.
  ///
  /// Devolve `null` quando não há sessão — quem chama decide o que fazer
  /// (hoje: a tela de login já está na frente, então é caso de borda).
  Future<String?> accessToken() async {
    final current = _session;
    if (current == null) return null;
    if (!current.isExpired) return current.accessToken;
    try {
      await _refresh();
    } on AuthException catch (e) {
      if (e.failure == AuthFailure.offline) return current.accessToken;
      await signOut();
      return null;
    }
    return _session?.accessToken;
  }

  // --- telefone -------------------------------------------------------------

  /// Telefone brasileiro em E.164: `+55` + DDD + número.
  ///
  /// Aceita o que a pessoa digita (com máscara, com ou sem `+55`, com zero na
  /// frente) e recusa o que não dá para completar. Quem decide o formato é o
  /// GoTrue: número fora de E.164 é recusado lá.
  static String normalizePhone(String input) {
    var digits = input.replaceAll(RegExp(r'\D'), '');
    if (digits.startsWith('0')) digits = digits.substring(1);
    if (digits.length == 10 || digits.length == 11) {
      digits = '55$digits'; // DDD + número, sem o código do país
    }
    return digits.isEmpty ? '' : '+$digits';
  }

  /// `+55` + DDD (2) + número (8 fixo ou 9 celular).
  static bool _looksLikePhone(String e164) =>
      RegExp(r'^55\d{10,11}$').hasMatch(e164.replaceAll(RegExp(r'\D'), ''));

  static String _codeDigits(String code) {
    final digits = code.replaceAll(RegExp(r'\D'), '');
    if (digits.length != 6) {
      throw AuthException(AuthFailure.rejected, 'O código tem 6 dígitos.');
    }
    return digits;
  }

  // --- interno --------------------------------------------------------------

  Future<void> _refresh() {
    // Single-flight: quem chega no meio espera a renovação em curso.
    return _refreshing ??= _doRefresh().whenComplete(() => _refreshing = null);
  }

  Future<void> _doRefresh() async {
    final current = _session;
    if (current == null) return;
    final body = await _call(
      'POST',
      '/token?grant_type=refresh_token',
      body: {'refresh_token': current.refreshToken},
    );
    final renewed = _sessionFrom(
      body,
      fallbackEmail: current.email,
      fallbackPhone: current.phone,
    );
    if (renewed == null) {
      throw AuthException(AuthFailure.unknown, 'Renovação sem sessão.');
    }
    await _save(renewed);
  }

  AuthSession? _sessionFrom(
    Map<String, dynamic> body, {
    String? fallbackEmail,
    String? fallbackPhone,
  }) {
    final access = body['access_token'] as String?;
    if (access == null || access.isEmpty) return null;
    final user = body['user'] as Map<String, dynamic>?;
    final expiresIn = (body['expires_in'] as num?)?.toInt() ?? 3600;
    return AuthSession(
      accessToken: access,
      refreshToken: (body['refresh_token'] as String?) ?? '',
      userId: (user?['id'] as String?) ?? '',
      email: (user?['email'] as String?) ?? fallbackEmail ?? '',
      phone: (user?['phone'] as String?) ?? fallbackPhone ?? '',
      expiresAt: DateTime.now().add(Duration(seconds: expiresIn)),
    );
  }

  Future<void> _save(AuthSession session) async {
    _session = session;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, jsonEncode(session.toJson()));
    notifyListeners();
  }

  Future<Map<String, dynamic>> _call(
    String method,
    String path, {
    Object? body,
    String? token,
  }) async {
    final uri = Uri.parse('$baseUrl$path');
    final headers = {
      'apikey': anonKey,
      'authorization': 'Bearer ${token ?? anonKey}',
      'content-type': 'application/json',
    };
    http.Response resp;
    try {
      final req = http.Request(method, uri)..headers.addAll(headers);
      if (body != null) req.body = jsonEncode(body);
      resp = await http.Response.fromStream(await _http.send(req));
    } catch (e) {
      // Log só em debug: em release a exceção crua não vai para o log do
      // aparelho (pode conter host/porta), mas em desenvolvimento ela é a
      // única pista quando o servidor de acesso não responde.
      throw AuthException(
        AuthFailure.offline,
        // Em debug a causa vai na mensagem: sem isso, "sem conexão" esconde
        // DNS, porta errada e recusa de conexão atrás do mesmo texto.
        kDebugMode
            ? 'Sem conexão com o servidor de acesso. ${e.toString()}'
            : 'Sem conexão com o servidor de acesso.',
      );
    }
    if (resp.statusCode >= 200 && resp.statusCode < 300) {
      final text = utf8.decode(resp.bodyBytes);
      if (text.trim().isEmpty) return const {};
      final decoded = jsonDecode(text);
      return decoded is Map<String, dynamic> ? decoded : const {};
    }
    throw _problem(resp);
  }

  AuthException _problem(http.Response resp) {
    String code = '';
    String message = '';
    try {
      final j = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      code = (j['error_code'] ?? j['code'] ?? j['error'] ?? '') as String? ?? '';
      message = (j['msg'] ?? j['message'] ?? j['error_description'] ?? '') as String? ?? '';
    } on FormatException {
      // resposta sem JSON: decide só pelo status
    }
    final lower = '$code $message'.toLowerCase();
    final sms = lower.contains('sms') || lower.contains('phone');
    if (resp.statusCode == 429 || lower.contains('rate_limit')) {
      return AuthException(AuthFailure.rateLimited,
          'Muitos pedidos de código. Espere alguns minutos.', code: code);
    }
    if (lower.contains('expired')) {
      return AuthException(AuthFailure.codeExpired,
          'Este código expirou. Peça um novo.', code: code);
    }
    if (resp.statusCode == 401 || resp.statusCode == 403 || lower.contains('invalid')) {
      return AuthException(
          AuthFailure.codeInvalid, 'Código incorreto. Confira o código recebido.',
          code: code);
    }
    // Sem provedor de SMS configurado o GoTrue devolve 5xx: dizer "tente o
    // e-mail" é mais útil do que um erro genérico de servidor.
    if (sms && resp.statusCode >= 500) {
      return AuthException(AuthFailure.rejected,
          'Envio de SMS indisponível agora. Entre com e-mail.', code: code);
    }
    if (resp.statusCode == 422 || resp.statusCode == 400) {
      return AuthException(
          AuthFailure.rejected,
          sms
              ? 'Não foi possível usar este telefone.'
              : 'Não foi possível usar este e-mail.',
          code: code);
    }
    return AuthException(AuthFailure.unknown,
        'Falha ao falar com o servidor de acesso.', code: code);
  }

  static bool _looksLikeEmail(String value) =>
      RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(value);
}
