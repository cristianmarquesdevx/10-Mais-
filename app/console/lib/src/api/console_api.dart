import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// O bucket PRIVADO onde estão os documentos do KYC.
///
/// O nome é CONTRATO: vive em `scripts/contract.py`
/// (`KYC_STORAGE_BUCKET`) e `scripts/test_contract.py` confere que esta
/// cópia continua igual — um nome divergente faria o console procurar o
/// documento onde ele não está.
const String kycStorageBucket = 'kyc-docs';

/// Token de acesso da sessão.
///
/// Pode ser síncrono (testes de contrato) ou assíncrono (o serviço de auth
/// renova a sessão sozinho quando o token está perto de vencer — a chamada
/// precisa esperar por isso).
/// O provedor do token da sessão.
///
/// Pode devolver `null` (e **vai** devolver quando não há sessão): o
/// console trata isso como FALHA DE CREDENCIAL, não como falta de rede.
typedef TokenProvider = FutureOr<String?> Function();

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
/// A fila mostra o NOME e o TELEFONE do parceiro: "Parceiro 77777777" não
/// ajuda ninguém a decidir, e a operação precisa falar com a pessoa se o
/// documento estiver ruim. O uuid continua disponível como reserva.
class QueueCase {
  const QueueCase({
    required this.caseId,
    required this.partnerUserId,
    required this.status,
    required this.createdAt,
    this.slaDueAt,
    this.position,
    this.documents = 0,
    this.partnerName,
    this.partnerPhone,
  });

  final String caseId;
  final String partnerUserId;
  final String status;
  final DateTime createdAt;
  final DateTime? slaDueAt;
  final int? position;
  final int documents;

  /// O nome do parceiro (`profiles.full_name`).
  final String? partnerName;

  /// O telefone do parceiro (`users.phone_e164`).
  final String? partnerPhone;

  /// O nome de exibição: o nome quando o banco tem, o id curto quando não.
  String get displayName {
    final n = partnerName?.trim();
    if (n != null && n.isNotEmpty) return n;
    return 'Parceiro ${shortId(partnerUserId)}';
  }

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
        partnerName: (j['partner_name'] as String?)?.trim(),
        partnerPhone: (j['partner_phone'] as String?)?.trim(),
      );
}

/// O identificador curto da conta: os 8 últimos do uuid.
String shortId(String uuid) =>
    uuid.length <= 8 ? uuid : uuid.substring(uuid.length - 8);

/// Um documento anexado ao caso.
class KycDocument {
  const KycDocument({
    required this.docType,
    required this.createdAt,
    this.uploadPending = false,
    this.storagePath,
    this.hasFile = false,
  });

  final String docType;
  final DateTime createdAt;

  /// O arquivo ainda NÃO foi enviado: o registro é honesto, não finge
  /// download. A operação precisa ver isso antes de aprovar.
  final bool uploadPending;

  /// O nome do objeto no bucket privado (sem barra inicial).
  ///
  /// Vazio quando o registro é do modo legado/pendente: aí não existe
  /// objeto, e o console não inventa URL.
  final String? storagePath;

  /// O objeto EXISTE no bucket?
  ///
  /// O servidor pergunta ao BUCKET (`fn_kyc_storage_object_present`), não ao
  /// nome do caminho: um `storage_path` que não aponta para objeto nenhum
  /// é "sem arquivo". Sem esta distinção a tela pintava **ARQUIVO OK**
  /// (verde) e o preview falhava logo abaixo — duas afirmações contrárias
  /// na mesma tela.
  final bool hasFile;

  /// Dá para abrir o documento? Só se há arquivo de verdade.
  bool get isViewable => hasFile && (storagePath?.trim().isNotEmpty ?? false);

  factory KycDocument.fromJson(Map<String, dynamic> j) => KycDocument(
        docType: (j['doc_type'] as String?) ?? '',
        createdAt:
            DateTime.tryParse((j['created_at'] as String?) ?? '')?.toLocal() ??
                DateTime.fromMillisecondsSinceEpoch(0),
        uploadPending: (j['upload_pending'] as bool?) ?? false,
        storagePath: (j['storage_path'] as String?)?.trim(),
        hasFile: (j['has_file'] as bool?) ?? false,
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
    this.partnerUserId,
    this.partnerName,
    this.partnerPhone,
  });

  final String caseId;
  final String status;
  final int? position;
  final DateTime? sla;
  final String? rejectionCode;
  final DateTime? decidedAt;
  final List<KycDocument> documents;

  /// A conta do parceiro do caso.
  final String? partnerUserId;

  /// O nome do parceiro (`profiles.full_name`).
  final String? partnerName;

  /// O telefone do parceiro (`users.phone_e164`).
  final String? partnerPhone;

  /// O nome de exibição: o nome quando o banco tem, o id curto quando não.
  String get displayName {
    final n = partnerName?.trim();
    if (n != null && n.isNotEmpty) return n;
    return 'Parceiro ${shortId(partnerUserId ?? '')}';
  }

  factory CaseDetail.fromJson(Map<String, dynamic> j) => CaseDetail(
        caseId: j['case_id'] as String,
        status: (j['status'] as String?) ?? '',
        position: (j['position'] as num?)?.toInt(),
        sla: DateTime.tryParse((j['sla'] as String?) ?? '')?.toLocal(),
        rejectionCode: j['rejection_code'] as String?,
        decidedAt: DateTime.tryParse((j['decided_at'] as String?) ?? '')?.toLocal(),
        partnerUserId: (j['partner_user_id'] as String?)?.trim(),
        partnerName: (j['partner_name'] as String?)?.trim(),
        partnerPhone: (j['partner_phone'] as String?)?.trim(),
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
    this.storageBase,
    this.requestTimeout = const Duration(seconds: 20),
    this.downloadTimeout = const Duration(seconds: 60),
    http.Client? inner,
  }) : _http = inner ?? http.Client();

  final String baseUrl;
  final TokenProvider accessToken;

  /// A base do Storage REST (o bucket é privado: o GET exige o JWT do
  /// chamador). Vem do build (`STORAGE_BASE`); quando não vem, é derivada
  /// da base da função — o Storage mora no mesmo host do projeto.
  final String? storageBase;

  /// Quanto tempo a operação espera o servidor responder.
  ///
  /// Sem prazo, uma leitura pendurada deixa a tela presa no "carregando"
  /// para sempre — e a pessoa não sabe se o servidor está fora ou lento.
  /// Passado o prazo, a leitura vira o erro `offline` (a tela avisa e
  /// oferece tentar de novo).
  ///
  /// O prazo cobre **tudo**: os cabeçalhos, o corpo **e** a busca do
  /// token. Um token que nunca chega trava a tela do mesmo jeito que um
  /// servidor mudo — e o `finally` do controller nunca roda.
  final Duration requestTimeout;

  /// Quanto tempo a operação espera o **documento** baixar.
  ///
  /// O download tem prazo próprio, **maior** que o da API: uma foto de
  /// celular (vários MB) num 3G lento leva mais que 20 s — cortar isso
  /// seria trocar "demorou" por "não foi possível carregar o documento".
  /// Ainda assim tem prazo: sem ele, o preview ficaria pendurado para
  /// sempre, sem botão de recuperar.
  final Duration downloadTimeout;

  final http.Client _http;

  /// O backend real está configurado? Vazio = o console não tem para onde
  /// falar — e a tela diz isso em vez de mostrar uma fila inventada.
  bool get isConfigured => baseUrl.trim().isNotEmpty;

  String get _root {
    final b = baseUrl.trim();
    return b.endsWith('/') ? b.substring(0, b.length - 1) : b;
  }

  /// A base do Storage REST, já normalizada (sem barra final).
  String get storageRoot {
    final explicit = storageBase?.trim() ?? '';
    if (explicit.isNotEmpty) {
      return explicit.endsWith('/')
          ? explicit.substring(0, explicit.length - 1)
          : explicit;
    }
    final uri = Uri.tryParse(_root);
    if (uri == null || uri.host.isEmpty) return '';
    return '${uri.scheme}://${uri.authority}/storage/v1';
  }

  /// A rota do CONTRATO é `/kyc/...`; a base já aponta para a função, então
  /// o prefixo não é repetido.
  String _path(String path) {
    if (_root.endsWith('/kyc') && path.startsWith('/kyc')) {
      return path.substring('/kyc'.length);
    }
    return path;
  }

  /// O token da sessão, com **prazo** e com **erro honesto**.
  ///
  /// O provedor pode devolver o token de imediato (`FutureOr`), mas a
  /// sessão também pode precisar **renovar** o token (uma ida ao servidor
  /// que, se travar, trava a tela junto). O prazo cobre essa espera.
  ///
  /// Três falhas, três códigos diferentes — a tela precisa saber qual é:
  ///
  ///   * o token **não chega** (o prazo estoura) → `offline`;
  ///   * o token **não existe** (sessão ausente) → `unauthorized`;
  ///   * o provedor **lança** um `ApiProblem` → repassado como está.
  ///
  /// Sem o segundo item, um provedor que devolvesse `null` estourava um
  /// `TypeError` dentro do `catch` genérico e virava `'offline'` — a
  /// operação culparia a rede por uma sessão que já tinha acabado, e o
  /// botão "tentar de novo" nunca resolveria.
  Future<String> _token(Duration limit) async {
    final token =
        await Future<String?>.sync(() => accessToken()).timeout(limit);
    if (token == null || token.trim().isEmpty) {
      throw ApiProblem(401, 'unauthorized',
          'Sem sessão: entre no console de novo.', '');
    }
    return token;
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

    final http.Request req;
    try {
      // O TOKEN também tem prazo: um token que nunca chega trava a tela do
      // mesmo jeito que um servidor mudo (o `finally` do controller nunca
      // rodaria e o spinner ficaria preso para sempre).
      req = http.Request(method, uri)
        ..headers['authorization'] = 'Bearer ${await _token(requestTimeout)}'
        ..headers['content-type'] = 'application/json'
        ..encoding = utf8;
    } on ApiProblem {
      // Um erro de CREDENCIAL do provedor de token (sessão expirada,
      // sem permissão) tem o seu próprio código: mascará-lo como
      // 'offline' faria a operação culpar a rede por uma sessão morta.
      rethrow;
    } on TimeoutException {
      throw ApiProblem(0, 'offline', 'A sessão não respondeu a tempo', '');
    } catch (e) {
      throw ApiProblem(0, 'offline', 'Sem conexão com o servidor', '$e');
    }
    if (body != null) req.body = jsonEncode(body);

    final http.Response resp;
    try {
      // O prazo cobre a espera pelos CABEÇALHOS e a leitura do corpo: um
      // `.timeout` só no `fromStream` não protege nada, porque o `send`
      // (que é o que fica pendurado quando o servidor não responde) já
      // esperou para sempre antes do corpo existir.
      final streamed = await _http.send(req).timeout(requestTimeout);
      resp = await http.Response.fromStream(streamed).timeout(requestTimeout);
    } on ApiProblem {
      rethrow;
    } on TimeoutException {
      throw ApiProblem(0, 'offline', 'O servidor não respondeu a tempo', '');
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

  /// Baixa o DOCUMENTO do bucket privado.
  ///
  /// Quem autoriza é a RLS do Storage: o dono da pasta ou o papel de
  /// operação (`app_is_agent()`). O console usa o PRÓPRIO token do agente —
  /// não há service role no caminho do produto, nem URL assinada para
  /// compartilhar (uma URL assinada vazaria o documento).
  ///
  /// O motivo da falha é **discriminado**: rede (`offline`), sessão
  /// (`unauthorized`), recusa (`forbidden`), objeto que o Storage não
  /// entregou (`not_found`) e erro do servidor (`server_error`) chegam
  /// com códigos diferentes. Antes, tudo virava `null` e a tela dizia
  /// sempre "Não foi possível carregar o documento" — indistinguível de
  /// rede caída, sessão morta e arquivo apagado. A operação precisa
  /// saber qual dos três é: só um deles se resolve com "tentar de novo".
  Future<Uint8List> documentBytes(String storagePath) async {
    final root = storageRoot;
    final path = storagePath.trim();
    if (root.isEmpty) {
      throw ApiProblem(0, 'not_configured',
          'Console sem Storage: configure STORAGE_BASE no build.', '');
    }
    if (path.isEmpty) {
      throw ApiProblem(404, 'not_found',
          'Este documento não tem arquivo no bucket.', '');
    }
    final encoded = path
        .split('/')
        .where((p) => p.isNotEmpty)
        .map(Uri.encodeComponent)
        .join('/');
    final uri = Uri.parse('$root/object/$kycStorageBucket/$encoded');
    try {
      final req = http.Request('GET', uri);
      // O token tem prazo (mesmo problema da API: um token que não chega
      // trava o preview para sempre).
      req.headers['authorization'] =
          'Bearer ${await _token(downloadTimeout)}';
      // O download tem prazo próprio, **maior** que o da API (uma foto de
      // celular em 3G lento leva mais que 20 s) — e cobre os cabeçalhos E
      // o corpo: um `.timeout` só no `fromStream` não protege nada, porque
      // o `send` já esperaria para sempre.
      final streamed = await _http.send(req).timeout(downloadTimeout);
      final resp = await http.Response.fromStream(streamed).timeout(downloadTimeout);
      if (resp.statusCode >= 400) throw _problemaDoStorage(resp);
      return resp.bodyBytes;
    } on ApiProblem {
      // O código do problema (credencial, recusa, arquivo ausente) é o
      // que a tela mostra: mascará-lo como 'offline' faria a operação
      // culpar a rede pelo motivo errado.
      rethrow;
    } on TimeoutException {
      throw ApiProblem(0, 'offline', 'O download não respondeu a tempo.', '');
    } catch (e) {
      throw ApiProblem(0, 'offline', 'Sem conexão com o servidor do Storage.',
          '$e');
    }
  }

  /// O erro do Storage, traduzido para um código que a tela entende.
  ///
  /// MEDIDO no stack local: o Storage responde **HTTP 400/500** e escreve
  /// o motivo no CORPO (o status HTTP, sozinho, não diz nada):
  ///
  ///   * objeto inexistente →
  ///     `{"statusCode":"404","error":"not_found","code":"NoSuchKey"}`;
  ///   * credencial que não enxerga o bucket (token inválido/expirado ou
  ///     papel sem acesso) →
  ///     `{"statusCode":"404","error":"Bucket not found","code":"NoSuchBucket"}`;
  ///   * registro no banco **sem** objeto no storage →
  ///     `{"statusCode":"500","code":"InternalError"}` (a instância do
  ///     servidor falhou — não é "o arquivo sumiu");
  ///   * sem permissão no objeto → o Storage **MASCARA** como `NoSuchKey`
  ///     (não entrega se o objeto existe).
  ///
  /// Por isso o código olha o CORPO, não só o status: classificar pelo
  /// status chamaria "arquivo apagado" o que é, na verdade, "a sua
  /// credencial não viu o bucket" — e as duas coisas pedem ações
  /// diferentes da operação.
  ApiProblem _problemaDoStorage(http.Response resp) {
    String? codigo;
    int? status;
    try {
      final j = jsonDecode(resp.body);
      if (j is Map<String, dynamic>) {
        codigo = j['code'] as String?;
        status = (j['statusCode'] as num?)?.toInt();
      }
    } catch (_) {
      // O corpo não é JSON: o status HTTP serve.
    }
    if (codigo == 'NoSuchBucket') {
      return ApiProblem(401, 'unauthorized',
          'O servidor não reconheceu a credencial deste console.', '');
    }
    if (codigo == 'NoSuchKey' || status == 404 || resp.statusCode == 404) {
      // O texto NÃO afirma que o arquivo sumiu: o Storage mascara a
      // falta de permissão como "não achei o objeto".
      return ApiProblem(404, 'not_found',
          'O servidor registrou o arquivo, mas não o entregou.', '');
    }
    if (resp.statusCode == 401 || status == 401) {
      return ApiProblem(401, 'unauthorized',
          'A sessão expirou: entre de novo.', '');
    }
    if (resp.statusCode == 403 || status == 403) {
      return ApiProblem(403, 'forbidden', 'O servidor recusou este documento.',
          '');
    }
    return ApiProblem(resp.statusCode, 'server_error',
        'O servidor falhou ao entregar o arquivo (${resp.statusCode}).', '');
  }

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
