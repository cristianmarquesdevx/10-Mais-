import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Contrato tipado do app passageiro — espelho de docs/fase2/openapi.yaml.
/// Toda mutação envia `Idempotency-Key` (UUID) e todo erro vira [ApiProblem]
/// (problem+json com `code` estável — as telas decidem por `code`, nunca por
/// mensagem).

// ---------------------------------------------------------------------------
// Modelos (espelho dos schemas do OpenAPI)
// ---------------------------------------------------------------------------

enum PricingMode { tariff, negotiated }

enum RideStatus {
  criada,
  buscando,
  ofertada,
  aceita,
  aCaminho,
  chegou,
  emViagem,
  finalizada,
  falhaPagamento,
  expirada,
  canceladaCliente,
  canceladaParceiro,
  canceladaSistema,
  canceladaSuporte;

  static RideStatus fromWire(String s) => values.firstWhere(
        (v) => v.name == _camelize(s),
        orElse: () => RideStatus.criada,
      );

  static String _camelize(String s) {
    final parts = s.toLowerCase().split('_');
    if (parts.length == 1) return parts.first;
    return parts.first +
        parts.skip(1).map((p) => p[0].toUpperCase() + p.substring(1)).join();
  }

  bool get isOpen =>
      this == RideStatus.criada ||
      this == RideStatus.buscando ||
      this == RideStatus.ofertada ||
      this == RideStatus.aceita ||
      this == RideStatus.aCaminho ||
      this == RideStatus.chegou ||
      this == RideStatus.emViagem;

  bool get isCancelled => name.startsWith('cancelada');

  /// Corrida ainda em busca (pré-aceite): CRIADA, BUSCANDO ou OFERTADA.
  bool get isSearching =>
      this == RideStatus.criada ||
      this == RideStatus.buscando ||
      this == RideStatus.ofertada;

  /// Texto para a tela (pt-BR). O nome do enum não é para o passageiro:
  /// "canceladaCliente" não se lê num histórico.
  String get label => switch (this) {
        RideStatus.criada => 'Criada',
        RideStatus.buscando => 'Buscando parceiro',
        RideStatus.ofertada => 'Ofertada',
        RideStatus.aceita => 'Aceita',
        RideStatus.aCaminho => 'Parceiro a caminho',
        RideStatus.chegou => 'Parceiro chegou',
        RideStatus.emViagem => 'Em viagem',
        RideStatus.finalizada => 'Finalizada',
        RideStatus.falhaPagamento => 'Falha no pagamento',
        RideStatus.expirada => 'Expirada',
        RideStatus.canceladaCliente => 'Cancelada por você',
        RideStatus.canceladaParceiro => 'Cancelada pelo parceiro',
        RideStatus.canceladaSistema => 'Cancelada pelo sistema',
        RideStatus.canceladaSuporte => 'Cancelada pelo suporte',
      };
}

class GeoPoint {
  final double lat, lon;
  const GeoPoint(this.lat, this.lon);
  Map<String, dynamic> toJson() => {'lat': lat, 'lon': lon};
}

class Ride {
  final String rideId;
  final RideStatus status;
  final String? pricingMode; // PASSE | COMISSAO | null antes do aceite
  final double? fareTotal;
  final double? proposedAmount;
  final int? etaSeconds; // sempre do servidor (SPECS §4)
  /// Distância rodoviária congelada no pedido — a mesma que a cotação
  /// mostrou e que o parceiro vê na oferta.
  final double? distanceKm;
  final GeoPoint? origin, destination;
  final String? originAddress, destinationAddress;
  final String? partnerName;
  final double? partnerRating;
  final String? partnerVehicle;
  final String paymentStatus;
  final DateTime createdAt;

  /// Posição do parceiro no percurso (rota real), atualizada a cada poll.
  /// É o que move a moto no mapa do passageiro até o embarque/destino.
  final GeoPoint? partnerPosition;
  final double? partnerRemainingKm;

  /// Data/hora local no formato curto do app. O `DateTime.toString()` cru
  /// vazava os microssegundos (`17:26:05.979153`) e quebrava a linha do
  /// histórico em duas.
  String get createdAtLabel {
    final l = createdAt.toLocal();
    String dois(int v) => v.toString().padLeft(2, '0');
    return '${dois(l.day)}/${dois(l.month)}/${l.year}'
        ' às ${dois(l.hour)}:${dois(l.minute)}';
  }

  Ride({
    required this.rideId,
    required this.status,
    this.pricingMode,
    this.fareTotal,
    this.proposedAmount,
    this.etaSeconds,
    this.distanceKm,
    this.origin,
    this.destination,
    this.originAddress,
    this.destinationAddress,
    this.partnerName,
    this.partnerRating,
    this.partnerVehicle,
    required this.paymentStatus,
    required this.createdAt,
    this.partnerPosition,
    this.partnerRemainingKm,
  });

  factory Ride.fromJson(Map<String, dynamic> j) => Ride(
        rideId: j['ride_id'] as String,
        status: RideStatus.fromWire(j['status'] as String),
        pricingMode: j['pricing_mode'] as String?,
        fareTotal: (j['fare_total'] as num?)?.toDouble(),
        proposedAmount: (j['proposed_amount'] as num?)?.toDouble(),
        etaSeconds: j['eta_seconds'] as int?,
        distanceKm: (j['distance_km'] as num?)?.toDouble(),
        origin: _pt(j['origin']),
        destination: _pt(j['destination']),
        originAddress: j['origin_address'] as String?,
        destinationAddress: j['destination_address'] as String?,
        partnerName:
            (j['partner'] as Map<String, dynamic>?)?['name'] as String?,
        partnerRating:
            ((j['partner'] as Map<String, dynamic>?)?['rating'] as num?)
                ?.toDouble(),
        partnerVehicle:
            (j['partner'] as Map<String, dynamic>?)?['vehicle'] as String?,
        paymentStatus: (j['payment_status'] as String?) ?? 'NOT_DUE',
        createdAt: DateTime.parse(j['created_at'] as String),
        partnerPosition: _pt(j['partner_position']),
        partnerRemainingKm:
            ((j['partner_position'] as Map<String, dynamic>?)?['remaining_km']
                    as num?)
                ?.toDouble(),
      );

  static GeoPoint? _pt(dynamic v) => v is Map<String, dynamic>
      ? GeoPoint((v['lat'] as num).toDouble(), (v['lon'] as num).toDouble())
      : null;
}

/// Preço do momento (GET /quote) — tarifa dinâmica calculada no servidor;
/// o valor pode mudar a qualquer instante e é honrado só por [expiresIn].
class Quote {
  final double fareTotal;
  final int expiresIn;

  /// Id que o POST /rides apresenta para o servidor honrar EXATAMENTE este
  /// valor (uso único, até expirar). Sem ele o servidor recalcula.
  final String? quoteId;
  final String? currency;
  final Map<String, dynamic>? breakdown;
  final DateTime fetchedAt;

  Quote({
    required this.fareTotal,
    required this.expiresIn,
    this.quoteId,
    this.currency,
    this.breakdown,
  }) : fetchedAt = DateTime.now();

  DateTime get expiresAt => fetchedAt.add(Duration(seconds: expiresIn));
  bool get expired => DateTime.now().isAfter(expiresAt);

  factory Quote.fromJson(Map<String, dynamic> j) => Quote(
        fareTotal: (j['fare_total'] as num).toDouble(),
        expiresIn: j['expires_in'] as int? ?? 90,
        quoteId: j['quote_id'] as String?,
        currency: j['currency'] as String?,
        breakdown: j['breakdown'] as Map<String, dynamic>?,
      );
}

/// Campanha de raspadinha (3.8)
class ScratchCampaign {
  final String id;
  final String name;
  final String? description;
  final String status; // SCHEDULED | ACTIVE | INACTIVE | ENDED
  final DateTime startedAt;
  final DateTime? endedAt;
  final int maxParticipationsPerUser;
  final String participationType; // FREE | PROMO | ACTION_BASED

  ScratchCampaign({
    required this.id,
    required this.name,
    this.description,
    required this.status,
    required this.startedAt,
    this.endedAt,
    required this.maxParticipationsPerUser,
    required this.participationType,
  });

  factory ScratchCampaign.fromJson(Map<String, dynamic> j) => ScratchCampaign(
        id: j['id'] as String,
        name: j['name'] as String,
        description: j['description'] as String?,
        status: j['status'] as String,
        startedAt: DateTime.parse(j['started_at'] as String),
        endedAt: j['ended_at'] != null
            ? DateTime.parse(j['ended_at'] as String)
            : null,
        maxParticipationsPerUser:
            (j['max_participations_per_user'] as num?)?.toInt() ?? 1,
        participationType: j['participation_type'] as String? ?? 'FREE',
      );
}

/// Prêmio disponível em uma campanha (3.8)
class ScratchPrize {
  final String id;
  final String campaignId;
  final String
      type; // DISCOUNT_COUPON | PROMO_CREDIT | FEE_DISCOUNT | FREE_HOURS | OTHER
  final String title;
  final String? description;
  final double value;
  final int validityDays;
  final int quantityTotal;
  final int quantityRemaining;
  final double probability; // 0-100
  final DateTime? redeemableUntil;

  ScratchPrize({
    required this.id,
    required this.campaignId,
    required this.type,
    required this.title,
    this.description,
    required this.value,
    required this.validityDays,
    required this.quantityTotal,
    required this.quantityRemaining,
    required this.probability,
    this.redeemableUntil,
  });

  factory ScratchPrize.fromJson(Map<String, dynamic> j) => ScratchPrize(
        id: j['id'] as String,
        campaignId: j['campaign_id'] as String,
        type: j['type'] as String,
        title: j['title'] as String,
        description: j['description'] as String?,
        value: (j['value'] as num).toDouble(),
        validityDays: (j['validity_days'] as num).toInt(),
        quantityTotal: (j['quantity_total'] as num).toInt(),
        quantityRemaining: (j['quantity_remaining'] as num).toInt(),
        probability: (j['probability'] as num).toDouble(),
        redeemableUntil: j['redeemable_until'] != null
            ? DateTime.parse(j['redeemable_until'] as String)
            : null,
      );
}

/// Raspadinha distribuída a um usuário (3.8)
class ScratchTicket {
  final String id;
  final String campaignId;
  final String userId;
  final String? prizeId;
  final String result; // WINNER | NON_WINNER
  final String status; // ISSUED | SCRATCHED | REDEEMED | EXPIRED
  final DateTime? scratchedAt;
  final DateTime? redeemedAt;
  final DateTime createdAt;

  ScratchTicket({
    required this.id,
    required this.campaignId,
    required this.userId,
    this.prizeId,
    required this.result,
    required this.status,
    this.scratchedAt,
    this.redeemedAt,
    required this.createdAt,
  });

  factory ScratchTicket.fromJson(Map<String, dynamic> j) => ScratchTicket(
        id: j['id'] as String,
        campaignId: j['campaign_id'] as String,
        userId: j['user_id'] as String,
        prizeId: j['prize_id'] as String?,
        result: j['result'] as String,
        status: j['status'] as String,
        scratchedAt: j['scratched_at'] != null
            ? DateTime.parse(j['scratched_at'] as String)
            : null,
        redeemedAt: j['redeemed_at'] != null
            ? DateTime.parse(j['redeemed_at'] as String)
            : null,
        createdAt: DateTime.parse(j['created_at'] as String),
      );

  bool get isWinner => result == 'WINNER';
  bool get canScratch => status == 'ISSUED';
  bool get canRedeem => prizeId != null && status == 'SCRATCHED';
}

/// Resgate de prêmio (3.8)
class ScratchRedemption {
  final String id;
  final String ticketId;
  final String userId;
  final DateTime redeemedAt;
  final String? benefitApplied;
  final String status;

  ScratchRedemption({
    required this.id,
    required this.ticketId,
    required this.userId,
    required this.redeemedAt,
    this.benefitApplied,
    required this.status,
  });

  factory ScratchRedemption.fromJson(Map<String, dynamic> j) =>
      ScratchRedemption(
        id: j['id'] as String,
        ticketId: j['ticket_id'] as String,
        userId: j['user_id'] as String,
        redeemedAt: DateTime.parse(j['redeemed_at'] as String),
        benefitApplied: j['benefit_applied'] as String?,
        status: j['status'] as String,
      );
}

/// Sugestão de endereço real (proxy geocoding da demo → Nominatim/OSM).
class PlaceResult {
  final String label;
  final double lat, lon;

  /// Número do imóvel/estabelecimento (obrigatório para fechar o pedido).
  /// Vem do geocodificador; quando o usuário informa, `numberFromUser` fica
  /// true e a tela mostra "número informado por você".
  final String? houseNumber;
  final bool numberFromUser;
  final String? road;

  PlaceResult({
    required this.label,
    required this.lat,
    required this.lon,
    this.houseNumber,
    this.numberFromUser = false,
    this.road,
  });

  bool get hasNumber => (houseNumber ?? '').trim().isNotEmpty;

  /// Rótulo curto para o campo: via principal + número.
  String get shortLabel {
    final base = label.split(',').first.trim();
    return hasNumber ? '$base, $houseNumber' : base;
  }

  /// Endereço que vai no pedido: SEMPRE com o número, mesmo quando o
  /// geocodificador devolveu um rótulo sem ele (praça, bairro, POI). O campo
  /// do app mostrava o número, mas o parceiro recebia o rótulo antigo sem
  /// número — o pedido não pode seguir sem essa informação.
  String get requestLabel {
    if (!hasNumber) return label;
    final parts = label.split(',').map((e) => e.trim()).toList();
    if (parts.contains(houseNumber)) return label;
    if (parts.length >= 2) {
      parts.insert(1, houseNumber!);
      return parts.join(', ');
    }
    return '$label, $houseNumber';
  }

  PlaceResult withNumber(String number, {bool fromUser = false}) => PlaceResult(
        label: label,
        lat: lat,
        lon: lon,
        houseNumber: number.trim(),
        numberFromUser: fromUser,
        road: road,
      );

  factory PlaceResult.fromJson(Map<String, dynamic> j) {
    final number = (j['house_number'] as String?)?.trim();
    return PlaceResult(
      label: j['label'] as String,
      lat: (j['lat'] as num).toDouble(),
      lon: (j['lon'] as num).toDouble(),
      houseNumber: (number == null || number.isEmpty) ? null : number,
      road: j['road'] as String?,
    );
  }
}

/// Gravação de segurança (POST /rides/{id}/recordings).
class Recording {
  final String recordingId, kind, mime;
  final int durationMs, sizeBytes;
  final String? camera;

  Recording({
    required this.recordingId,
    required this.kind,
    required this.durationMs,
    required this.sizeBytes,
    required this.mime,
    this.camera,
  });

  factory Recording.fromJson(Map<String, dynamic> j) => Recording(
        recordingId: j['recording_id'] as String,
        kind: j['kind'] as String,
        durationMs: (j['duration_ms'] as num).toInt(),
        sizeBytes: (j['size_bytes'] as num).toInt(),
        mime: j['mime'] as String,
        camera: j['camera'] as String?,
      );
}

/// Motorista disponível próximo (para o radar do passageiro).
/// Posição é aproximada (sem endereço exato — privacidade do parceiro).
class DriverMarker {
  final String driverId;
  final double lat, lon;
  final double distanceKm; // distância estimada até o passageiro
  final bool available; // verdadeiro se apto a receber ofertas
  final String? vehicle;

  DriverMarker({
    required this.driverId,
    required this.lat,
    required this.lon,
    required this.distanceKm,
    required this.available,
    this.vehicle,
  });

  factory DriverMarker.fromJson(Map<String, dynamic> j) => DriverMarker(
        driverId: j['driver_id'] as String,
        lat: (j['lat'] as num).toDouble(),
        lon: (j['lon'] as num).toDouble(),
        distanceKm: (j['distance_km'] as num?)?.toDouble() ?? 0,
        available: (j['available'] as bool?) ?? true,
        vehicle: j['vehicle'] as String?,
      );
}

/// RFC7807 problem+json — decisão de UI por [code].
class ApiProblem implements Exception {
  final int status;
  final String code;
  final String title;
  final String? detail;
  ApiProblem(this.status, this.code, this.title, [this.detail]);

  factory ApiProblem.fromResponse(http.Response r) {
    try {
      final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
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

class Me {
  final String userId;
  final String role;
  final String? phoneE164;
  final String? fullName;
  final DateTime? birthDate;
  final double? weight; // kg — opcional, finalidade operacional
  final double? height; // m  — opcional, finalidade operacional
  final String? photoUrl;
  Me({
    required this.userId,
    required this.role,
    this.phoneE164,
    this.fullName,
    this.birthDate,
    this.weight,
    this.height,
    this.photoUrl,
  });
  factory Me.fromJson(Map<String, dynamic> j) => Me(
        userId: j['user_id'] as String,
        role: j['role'] as String,
        phoneE164: j['phone_e164'] as String?,
        fullName: j['full_name'] as String?,
        birthDate: j['birth_date'] != null
            ? DateTime.tryParse(j['birth_date'] as String)
            : null,
        weight: (j['weight'] as num?)?.toDouble(),
        height: (j['height'] as num?)?.toDouble(),
        photoUrl: j['photo_url'] as String?,
      );
}

/// Convite de motorista (3.8) — código compartilhável e recompensa.
class Invite {
  final String id;
  final String inviteCode;
  final String status; // PENDING | COMPLETED | EXPIRED
  final int? rewardHours;
  final DateTime? createdAt;

  Invite({
    required this.id,
    required this.inviteCode,
    required this.status,
    this.rewardHours,
    this.createdAt,
  });

  factory Invite.fromJson(Map<String, dynamic> j) => Invite(
        id: (j['invite_id'] ?? j['id'] ?? j['invite_code']) as String,
        inviteCode: j['invite_code'] as String,
        status: (j['status'] as String?) ?? 'PENDING',
        rewardHours: (j['reward_hours'] as num?)?.toInt(),
        createdAt: j['created_at'] != null
            ? DateTime.tryParse(j['created_at'] as String)
            : null,
      );
}

// ---------------------------------------------------------------------------
// Client
// ---------------------------------------------------------------------------

typedef IdempotencyKey = String Function();

class ApiClient {
  ApiClient({
    required this.baseUrl,
    required this.accessToken,
    http.Client? inner,
    IdempotencyKey? newIdemKey,
  })  : _http = inner ?? http.Client(),
        _newIdemKey = newIdemKey ?? _uuid;

  /// Ex.: http://127.0.0.1:54321/functions/v1/v1 (local) — sem / no fim.
  final String baseUrl;
  final String Function() accessToken;
  final http.Client _http;
  final IdempotencyKey _newIdemKey;

  static String _uuid() {
    final r = Random.secure();
    List<int> bytes(int n) => List.generate(n, (_) => r.nextInt(256));
    final b = bytes(16);
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    String h(int a, int z) =>
        b.sublist(a, z).map((x) => x.toRadixString(16).padLeft(2, '0')).join();
    return '${h(0, 4)}-${h(4, 6)}-${h(6, 8)}-${h(8, 10)}-${h(10, 16)}';
  }

  Map<String, String> get _headers => {
        'authorization': 'Bearer ${accessToken()}',
        'content-type': 'application/json',
      };

  Future<Map<String, dynamic>> _req(
    String method,
    String path, {
    Object? body,
    bool idempotent = false,
    Map<String, String>? query,
  }) async {
    final uri = Uri.parse('$baseUrl$path').replace(queryParameters: query);
    final headers = {..._headers};
    if (idempotent) headers['Idempotency-Key'] = _newIdemKey();

    final req = http.Request(method, uri)
      ..headers.addAll(headers)
      ..encoding = utf8;
    if (body != null) req.body = jsonEncode(body);

    // Falha de transporte (sem rede, servidor fora, conexão caiu no meio)
    // vira ApiProblem como qualquer outro erro: os controllers só tratam
    // ApiProblem, e uma exceção crua aqui escapava como unhandled.
    final http.Response resp;
    try {
      final streamed = await _http.send(req);
      resp = await http.Response.fromStream(streamed);
    } on ApiProblem {
      rethrow;
    } catch (e) {
      throw ApiProblem(0, 'offline', 'Sem conexão com o servidor', '$e');
    }
    if (resp.statusCode >= 400) throw ApiProblem.fromResponse(resp);
    if (resp.body.isEmpty) return <String, dynamic>{};
    return jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
  }

  // --- contrato -----------------------------------------------------------

  Future<Me> me() async => Me.fromJson(await _req('GET', '/me'));

  /// Atualiza perfil do passageiro (nome, data de nascimento, peso, altura).
  /// 200 com o Me atualizado.
  Future<Me> updateProfile({
    String? fullName,
    DateTime? birthDate,
    double? weight,
    double? height,
  }) async {
    final j = await _req(
      'PUT',
      '/me/profile',
      idempotent: true,
      body: {
        if (fullName != null) 'full_name': fullName,
        if (birthDate != null) 'birth_date': birthDate.toIso8601String(),
        if (weight != null) 'weight': weight,
        if (height != null) 'height': height,
      },
    );
    return Me.fromJson(j);
  }

  /// Atualiza foto de perfil (bytes em base64 na demo; produção usa storage
  /// privado com URL assinada).
  /// 200 com o Me atualizado (incluindo photoUrl).
  Future<Me> updateProfilePhoto(Uint8List bytes, String mime) async {
    final j = await _req(
      'POST',
      '/me/profile/photo',
      idempotent: true,
      body: {
        'photo': base64Encode(bytes),
        'mime': mime,
      },
    );
    return Me.fromJson(j);
  }

  /// Preço do momento (GET /quote) — o passageiro vê este valor antes de
  /// confirmar; o servidor o congela como Ride.fare_total no POST /rides.
  Future<Quote> quote({
    required GeoPoint origin,
    required GeoPoint destination,
  }) async {
    final j = await _req('GET', '/quote', query: {
      'origin_lat': '${origin.lat}',
      'origin_lon': '${origin.lon}',
      'dest_lat': '${destination.lat}',
      'dest_lon': '${destination.lon}',
    });
    return Quote.fromJson(j);
  }

  /// 201 · 409 active_ride_exists · 422 invalid_pricing/below_floor
  Future<void> createRide({
    required GeoPoint origin,
    required GeoPoint destination,
    required PricingMode mode,
    double? proposedAmount,
    String? quoteId,
    double? quotedFare,
    String? originAddress,
    String? destinationAddress,
    String? paymentMethodId,
  }) async {
    await _req(
      'POST',
      '/rides',
      idempotent: true,
      body: {
        'origin': origin.toJson(),
        'destination': destination.toJson(),
        'pricing_mode': mode == PricingMode.tariff ? 'TARIFF' : 'NEGOTIATED',
        if (proposedAmount != null) 'proposed_amount': proposedAmount,
        if (quoteId != null) 'quote_id': quoteId,
        // Só informativo: o servidor valida o valor contra a cotação e nunca
        // aceita este número como preço final.
        if (quotedFare != null) 'quoted_fare': quotedFare,
        if (originAddress != null) 'origin_address': originAddress,
        if (destinationAddress != null)
          'destination_address': destinationAddress,
        if (paymentMethodId != null) 'payment_method_id': paymentMethodId,
      },
    );
  }

  Future<Ride> ride(String id) async =>
      Ride.fromJson(await _req('GET', '/rides/$id'));

  Future<List<Ride>> rideHistory({int limit = 20, DateTime? before}) async {
    final q = <String, String>{'limit': '$limit'};
    if (before != null) q['before'] = before.toUtc().toIso8601String();
    final j = await _req('GET', '/rides', query: q);
    return (j['rides'] as List)
        .map((e) => Ride.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<Ride?> activeRide() async {
    final j = await _req('GET', '/rides', query: {'active': '1'});
    final rides = (j['rides'] as List?) ?? const [];
    return rides.isEmpty
        ? null
        : Ride.fromJson(rides.first as Map<String, dynamic>);
  }

  /// 200 · 409 ride_already_closed
  Future<void> cancelRide(String id, String reason) async {
    await _req('POST', '/rides/$id/cancel',
        idempotent: true, body: {'reason': reason});
  }

  /// 201 · 422 below_floor / above_ceiling / rate_limited
  Future<void> negotiate(String id,
      {required double amount, required String kind}) async {
    await _req('POST', '/rides/$id/negotiation',
        idempotent: true, body: {'amount': amount, 'kind': kind});
  }

  /// Pesquisa endereços reais em tempo real (proxy Nominatim na demo).
  ///
  /// Retorna sugestões com [label] legível e coordenadas ([lat]/[lon]).
  /// Termos muito curtos → 422 do servidor; offline → lista vazia.
  Future<List<PlaceResult>> geocode(String query) async {
    final j = await _req(
      'GET',
      '/geocode',
      query: {'q': query.trim()},
    );
    final results = (j['results'] as List?) ?? const [];
    return results
        .map((e) => PlaceResult.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Upload de gravação de segurança (áudio da corrida; bytes em base64 na
  /// demo — produção usa storage privado com URL assinada).
  Future<Recording> uploadRecording({
    required String rideId,
    required String kind, // AUDIO | VIDEO
    String? camera, // FRONT | REAR (só VIDEO)
    required int durationMs,
    required Uint8List bytes,
    String mime = 'audio/webm',
  }) async {
    final j = await _req(
      'POST',
      '/rides/$rideId/recordings',
      idempotent: true,
      body: {
        'kind': kind,
        if (camera != null) 'camera': camera,
        'duration_ms': durationMs,
        'size_bytes': bytes.length,
        'mime': mime,
        'data_b64': base64Encode(bytes),
      },
    );
    return Recording.fromJson(j);
  }

  Future<Uri> shareRide(String id) async {
    final j = await _req('POST', '/rides/$id/share', idempotent: true);
    return Uri.parse(j['url'] as String);
  }

  /// Motorista disponível próximo (GET /partners/nearby).
  /// Retorna motoristas ONLINE_DISPONIVEL dentro do raio (km) informado.
  /// Posições são aproximadas — privacidade do parceiro.
  Future<List<DriverMarker>> nearbyDrivers({
    required double lat,
    required double lon,
    double radiusKm = 5.0,
  }) async {
    final j = await _req(
      'GET',
      '/partners/nearby',
      query: {
        'lat': lat.toString(),
        'lon': lon.toString(),
        'radius_km': radiusKm.toString(),
      },
    );
    final drivers = (j['drivers'] as List?) ?? const [];
    return drivers
        .map((e) => DriverMarker.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> rateRide(String id,
      {required int stars, String? comment}) async {
    await _req('POST', '/rides/$id/rating', idempotent: true, body: {
      'stars': stars,
      if (comment != null && comment.isNotEmpty) 'comment': comment
    });
  }

  /// 201 → { payment_id, pix: { qr, copia_cola, expires_at } } | { card_url }
  Future<Map<String, dynamic>> startRidePayment(String rideId, String method) =>
      _req('POST', '/payments/ride',
          idempotent: true, body: {'ride_id': rideId, 'method': method});

  /// "Já paguei" do PIX: pergunta ao servidor se o PSP confirmou. O app não
  /// marca pago por conta própria — só reflete o payment_status do backend.
  Future<Ride> confirmRidePayment(String rideId) async => Ride.fromJson(
      await _req('POST', '/rides/$rideId/payment/confirm', idempotent: true));

  Future<void> openTicket({required String priority, String? rideId}) =>
      _req('POST', '/support/tickets',
          idempotent: true,
          body: {'priority': priority, if (rideId != null) 'ride_id': rideId});

  // --- convites de motoristas (3.8) ----------------------------------------

  /// Convites já gerados pela conta (GET /invites/mine).
  Future<List<Invite>> myInvites() async {
    final j = await _req('GET', '/invites/mine');
    return ((j['invites'] as List?) ?? const [])
        .map((e) => Invite.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Gera um novo código de convite (POST /invites).
  Future<Invite> generateInvite() async =>
      Invite.fromJson(await _req('POST', '/invites', idempotent: true));

  // --- raspadinha de prêmios (3.8) ------------------------------------------

  /// Campanhas de raspadinha ativas para o usuário (GET /scratch/campaigns).
  Future<List<ScratchCampaign>> scratchCampaigns() async {
    final j = await _req('GET', '/scratch/campaigns');
    return (j['campaigns'] as List)
        .map((e) => ScratchCampaign.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Solicitar uma raspadinha (POST /scratch/play).
  /// O servidor determina o resultado e retorna apenas o ticket_id.
  /// Não retorna o prêmio antes do usuário raspar.
  Future<ScratchTicket> scratchPlay(String campaignId) async {
    final j = await _req(
      'POST',
      '/scratch/play',
      idempotent: true,
      body: {'campaign_id': campaignId},
    );
    return ScratchTicket.fromJson(j);
  }

  /// Revelar o resultado após raspagem mínima (GET /scratch/tickets/{id}/result).
  /// O servidor já definiu o resultado; esta rota apenas o retorna.
  Future<ScratchTicket> scratchResult(String ticketId) async {
    final j = await _req('GET', '/scratch/tickets/$ticketId/result');
    return ScratchTicket.fromJson(j);
  }

  /// Histórico de raspadinhas do usuário (GET /scratch/history).
  Future<List<ScratchTicket>> scratchHistory() async {
    final j = await _req('GET', '/scratch/history');
    return (j['tickets'] as List)
        .map((e) => ScratchTicket.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Resgatar um prêmio (POST /scratch/redeem).
  Future<ScratchRedemption> scratchRedeem(String ticketId) async {
    final j = await _req(
      'POST',
      '/scratch/redeem',
      idempotent: true,
      body: {'ticket_id': ticketId},
    );
    return ScratchRedemption.fromJson(j);
  }
}
