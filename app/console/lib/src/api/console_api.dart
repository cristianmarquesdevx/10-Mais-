import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Token de acesso da sessão.
///
/// Pode ser síncrono (testes de contrato) ou assíncrono (o serviço de auth
/// renova a sessão sozinho quando o token está perto de vencer — a chamada
/// precisa esperar por isso).
typedef TokenProvider = FutureOr<String> Function();

/// RFC7807 problem+json — a tela decide por [code], nunca pelo texto.
///
/// O console conversa com a Edge Function `kyc`, que devolve problemas no
/// formato do contrato (`{title, status, code}`).
class ApiProblem implements Exception {
  ApiProblem(this.status, this.code, this.title, [this.detail]);

  final int status;
  final String code;
  final String title;
  final String? detail;

  factory ApiProblem.fromResponse(http.Response r) {
    try {
      // `r.body` respeita o charset do `Content-Type`; decodificar sempre em
      // UTF-8 quebrava a resposta quando o servidor (ou um teste) manda
      // latin1 — o erro voltava como "unknown" e a tela perdia o código.
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      return ApiProblem(
        r.statusCode,
        (j['code'] as String?) ?? 'unknown',
        (j['title'] as String?) ?? 'Erro',
        j['detail'] as String?,
      );
    } catch (_) {
      return ApiProblem(r.statusCode, 'unknown', 'Erro inesperado', r.body);
    }
  }

  @override
  String toString() => 'ApiProblem($status, $code)';
}

/// A pessoa que está na fila (a conta do parceiro).
///
/// O console mostra o identificador da conta, não o nome: o KYC é o cadastro
/// do parceiro e a operação decide sobre a DOCUMENTAÇÃO. Nome e telefone
/// aparecem no detalhe, que é onde a operação precisa deles.
class QueueCase {
  const QueueCase({
    required this.caseId,
    required this.partnerUserId,
    required this.status,
    required this.createdAt,
    this.slaDueAt,
    this.position,
    this.documents = 0,
  });

  final String caseId;
  final String partnerUserId;
  final String status;
  final DateTime createdAt;
  final DateTime? slaDueAt;
  final int? position;
  final int documents;

  /// O caso está atrasado? O SLA é uma promessa de atendimento: passou do
  /// prazo, a operação precisa saber antes do parceiro perguntar.
  bool isOverdue(DateTime now) =>
      slaDueAt != null && slaDueAt!.isBefore(now);

  factory QueueCase.fromJson(Map<String, dynamic> j) => QueueCase(
        caseId: j['case_id'] as String,
        partnerUserId: (j['partner_user_id'] as String?) ?? '',
        status: (j['status'] as String?) ?? '',
        createdAt:
            DateTime.tryParse((j['created_at'] as String?) ?? '')?.toLocal() ??
                DateTime.fromMillisecondsSinceEpoch(0),
        slaDueAt:
            DateTime.tryParse((j['sla_due_at'] as String?) ?? '')?.toLocal(),
        position: (j['position'] as num?)?.toInt(),
        documents: (j['documents'] as num?)?.toInt() ?? 0,
      );
}

/// Um documento anexado ao caso.
class KycDocument {
  const KycDocument({
    required this.docType,
    required this.createdAt,
    this.uploadPending = false,
  });

  final String docType;
  final DateTime createdAt;

  /// O arquivo ainda NÃO foi enviado: o registro é honesto, não finge
  /// download. A operação precisa ver isso antes de aprovar.
  final bool uploadPending;

  factory KycDocument.fromJson(Map<String, dynamic> j) => KycDocument(
        docType: (j['doc_type'] as String?) ?? '',
        createdAt:
            DateTime.tryParse((j['created_at'] as String?) ?? '')?.toLocal() ??
                DateTime.fromMillisecondsSinceEpoch(0),
        uploadPending: (j['upload_pending'] as bool?) ?? false,
      );
}

/// O caso completo, com a documentação.
class CaseDetail {
  const CaseDetail({
    required this.caseId,
    required this.status,
    this.position,
    this.sla,
    this.rejectionCode,
    this.decidedAt,
    this.documents = const [],
  });

  final String caseId;
  final String status;
  final int? position;
  final DateTime? sla;
  final String? rejectionCode;
  final DateTime? decidedAt;
  final List<KycDocument> documents;

  factory CaseDetail.fromJson(Map<String, dynamic> j) => CaseDetail(
        caseId: j['case_id'] as String,
        status: (j['status'] as String?) ?? '',
        position: (j['position'] as num?)?.toInt(),
        sla: DateTime.tryParse((j['sla'] as String?) ?? '')?.toLocal(),
        rejectionCode: j['rejection_code'] as String?,
        decidedAt: DateTime.tryParse((j['decided_at'] as String?) ?? '')?.toLocal(),
        documents: ((j['documents'] as List?) ?? const [])
            .map((e) => KycDocument.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
      );
}

/// O resultado de uma decisão.
class ReviewResult {
  const ReviewResult({
    required this.caseId,
    required this.status,
    required this.partnerKycStatus,
  });

  final String caseId;
  final String status;
  final String partnerKycStatus;

  factory ReviewResult.fromJson(Map<String, dynamic> j) => ReviewResult(
        caseId: (j['case_id'] as String?) ?? '',
        status: (j['status'] as String?) ?? '',
        partnerKycStatus: (j['partner_kyc_status'] as String?) ?? '',
      );
}

/// Quem está logado — e se pode operar a fila.
class ConsoleMe {
  const ConsoleMe({
    required this.userId,
    required this.email,
    required this.role,
    required this.isAgent,
  });

  final String userId;
  final String email;
  final String role;

  /// A pessoa é da operação? O console só mostra a fila para AGENT/ADMIN —
  /// o servidor também recusa, mas a tela recusa ANTES (a mensagem é o
  /// que importa).
  final bool isAgent;

  factory ConsoleMe.fromJson(Map<String, dynamic> j) => ConsoleMe(
        userId: (j['user_id'] as String?) ?? '',
        email: (j['email'] as String?) ?? '',
        role: (j['role'] as String?) ?? '',
        isAgent: (j['is_agent'] as bool?) ?? false,
      );
}

/// Cliente HTTP do console da operação.
///
/// Convenção de base (a mesma do app do parceiro): a base aponta para a
/// FUNÇÃO (`http://host/functions/v1/kyc`). A rota do contrato é
/// `/kyc/queue`; como a base já traz o nome da função, o prefixo `/kyc` não
/// é repetido e a URL final é `http://host/functions/v1/kyc/queue`.
class ConsoleApi {
  ConsoleApi({
    required this.baseUrl,
    required this.accessToken,
    http.Client? inner,
  }) : _http = inner ?? http.Client();

  final String baseUrl;
  final TokenProvider accessToken;
  final http.Client _http;

  /// O backend real está configurado? Vazio = o console não tem para onde
  /// falar — e a tela diz isso em vez de mostrar uma fila inventada.
  bool get isConfigured => baseUrl.trim().isNotEmpty;

  String get _root {
    final b = baseUrl.trim();
    return b.endsWith('/') ? b.substring(0, b.length - 1) : b;
  }

  /// A rota do CONTRATO é `/kyc/...`; a base já aponta para a função, então
  /// o prefixo não é repetido.
  String _path(String path) {
    if (_root.endsWith('/kyc') && path.startsWith('/kyc')) {
      return path.substring('/kyc'.length);
    }
    return path;
  }

  Future<Map<String, dynamic>> _req(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
  }) async {
    if (!isConfigured) {
      throw ApiProblem(0, 'not_configured',
          'Console sem backend: configure KYC_BASE no build.');
    }
    final uri = Uri.parse('$_root${_path(path)}')
        .replace(queryParameters: query);
    final headers = {
      'authorization': 'Bearer ${await accessToken()}',
      'content-type': 'application/json',
    };

    final req = http.Request(method, uri)
      ..headers.addAll(headers)
      ..encoding = utf8;
    if (body != null) req.body = jsonEncode(body);

    final http.Response resp;
    try {
      resp = await http.Response.fromStream(await _http.send(req));
    } on ApiProblem {
      rethrow;
    } catch (e) {
      throw ApiProblem(0, 'offline', 'Sem conexão com o servidor', '$e');
    }
    if (resp.statusCode >= 400) throw ApiProblem.fromResponse(resp);
    if (resp.body.isEmpty) return <String, dynamic>{};
    final decoded = jsonDecode(resp.body);
    return decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
  }

  /// Quem está logado (e se é da operação).
  Future<ConsoleMe> me() async =>
      ConsoleMe.fromJson(await _req('GET', '/kyc/me'));

  /// A fila do KYC: posição, prazo e quantos documentos tem.
  Future<List<QueueCase>> queue({int limit = 50}) async {
    final j = await _req('GET', '/kyc/queue', query: {'limit': '$limit'});
    return ((j['cases'] as List?) ?? const [])
        .map((e) => QueueCase.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  /// O caso com a documentação.
  Future<CaseDetail> caseDetail(String caseId) async =>
      CaseDetail.fromJson(await _req('GET', '/kyc/cases/$caseId'));

  /// A decisão da operação.
  ///
  /// [decision] ∈ APPROVED · REJECTED · RESUBMIT. Recusa e pedido de
  /// reenvio exigem [rejectionCode] — o servidor recusa sem ele (422
  /// `rejection_code_required`), porque sem motivo padronizado o parceiro
  /// não sabe o que corrigir.
  Future<ReviewResult> review(
    String caseId, {
    required String decision,
    String? rejectionCode,
    String? note,
  }) async {
    final body = <String, dynamic>{'decision': decision};
    final code = rejectionCode?.trim();
    if (code != null && code.isNotEmpty) body['rejection_code'] = code;
    final mensagem = note?.trim();
    if (mensagem != null && mensagem.isNotEmpty) body['note'] = mensagem;
    return ReviewResult.fromJson(
        await _req('POST', '/kyc/cases/$caseId/review', body: body));
  }
}

/// Motivos padronizados de recusa.
///
/// A recusa sem motivo padronizado é recusa sem ação possível para o
/// parceiro: o código é o que a tela dele mostra. O vocabulário vive em
/// `scripts/contract.py` (fonte única do contrato) e o teste
/// `scripts/test_contract.py` confere que esta lista continua igual.
abstract final class RejectionCodes {
  /// O código (o que vai para o banco) e o rótulo (o que a operação lê).
  static const List<(String, String)> all = [
    ('CNH_ILEGIVEL', 'CNH ilegível ou com reflexo'),
    ('CNH_VENCIDA', 'CNH vencida'),
    ('DOC_INCOMPLETO', 'Documentação incompleta'),
    ('FOTO_INVALIDA', 'Foto ou selfie inválida'),
    ('COMPROVANTE_INVALIDO', 'Comprovante de endereço inválido'),
    ('DADOS_DIVERGENTES', 'Dados divergentes do cadastro'),
  ];

  static String labelOf(String code) {
    for (final (value, label) in all) {
      if (value == code) return label;
    }
    return code;
  }
}
