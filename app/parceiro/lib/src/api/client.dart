import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Contrato tipado do app parceiro — espelho de docs/fase2/openapi.yaml.
/// Toda mutação envia `Idempotency-Key` (UUID) e todo erro vira [ApiProblem]
/// (problem+json com `code` estável — as telas decidem por `code`, nunca por
/// mensagem).

// ---------------------------------------------------------------------------
// Modelos (espelho dos schemas do OpenAPI)
// ---------------------------------------------------------------------------

/// Nome pt-BR de um tipo de solicitação (o enum do contrato não vai à tela).
String serviceName(String? service) => switch (service) {
      'MOTO_NEGOCIA' => 'Moto Negocia',
      'MOTO' => 'Moto',
      _ => 'Corrida',
    };

class GeoPoint {
  final double lat, lon;
  const GeoPoint(this.lat, this.lon);
  Map<String, dynamic> toJson() => {'lat': lat, 'lon': lon};
}

/// Zona de calor de chamadas (GET /heatmap) — peso normalizado 0..1.
class HeatZone {
  final double lat, lon, weight;
  final String? label;
  final int callsLastHour;

  HeatZone({
    required this.lat,
    required this.lon,
    required this.weight,
    this.label,
    this.callsLastHour = 0,
  });

  factory HeatZone.fromJson(Map<String, dynamic> j) => HeatZone(
        lat: (j['lat'] as num).toDouble(),
        lon: (j['lon'] as num).toDouble(),
        weight: (j['weight'] as num).toDouble(),
        label: j['label'] as String?,
        callsLastHour: (j['calls_last_hour'] as num?)?.toInt() ?? 0,
      );
}

/// Resposta do calor de chamadas (GET /heatmap).
///
/// [demo] vem do servidor e é a trava de honestidade: dado de demonstração
/// nunca é apresentado como demanda real — o app marca a camada como
/// simulada e um backend de produção simplesmente não devolve o flag.
class HeatSnapshot {
  final List<HeatZone> zones;

  /// Verdadeiro quando os números são de demonstração (não são demanda real).
  final bool demo;

  /// Momento em que o servidor gerou a leitura.
  final DateTime? generatedAt;

  const HeatSnapshot({
    this.zones = const [],
    this.demo = false,
    this.generatedAt,
  });

  factory HeatSnapshot.fromJson(Map<String, dynamic> j) {
    final zones = (j['zones'] as List?) ?? const [];
    return HeatSnapshot(
      zones: zones
          .map((e) => HeatZone.fromJson(e as Map<String, dynamic>))
          .toList(),
      demo: j['demo'] == true,
      generatedAt: DateTime.tryParse(j['generated_at'] as String? ?? ''),
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

/// `Me.partner` (só existe quando role=PARTNER).
class PartnerInfo {
  final String
      kycStatus; // NOT_STARTED | IN_REVIEW | APPROVED | REJECTED | RESUBMIT
  final String monetizationMode; // PASSE_ATIVO | COMISSAO — ortogonal (§3.3)
  final DateTime? passExpiresAt;
  final double walletBalance;
  final int debtCents; // ADR-003: dívida bloqueia só dinheiro

  PartnerInfo({
    required this.kycStatus,
    required this.monetizationMode,
    required this.walletBalance,
    required this.debtCents,
    this.passExpiresAt,
  });

  bool get canGoOnline => kycStatus == 'APPROVED';

  factory PartnerInfo.fromJson(Map<String, dynamic> j) => PartnerInfo(
        kycStatus: (j['kyc_status'] as String?) ?? 'NOT_STARTED',
        monetizationMode: (j['monetization_mode'] as String?) ?? 'COMISSAO',
        passExpiresAt: j['pass_expires_at'] != null
            ? DateTime.parse(j['pass_expires_at'] as String)
            : null,
        walletBalance: (j['wallet_balance'] as num?)?.toDouble() ?? 0,
        debtCents: (j['debt_cents'] as int?) ?? 0,
      );
}

class Me {
  final String userId;
  final String role;
  final PartnerInfo? partner;
  Me({required this.userId, required this.role, this.partner});

  factory Me.fromJson(Map<String, dynamic> j) => Me(
        userId: j['user_id'] as String,
        role: j['role'] as String,
        partner: j['partner'] != null
            ? PartnerInfo.fromJson(j['partner'] as Map<String, dynamic>)
            : null,
      );
}

/// Preferências de solicitação do parceiro (o que o despacho pode ofertar).
///
/// `minFare` é o piso por corrida: o servidor não envia oferta abaixo dele.
class PartnerPrefs {
  const PartnerPrefs({required this.services, required this.minFare});

  final Set<String> services;
  final double minFare;

  factory PartnerPrefs.fromJson(Map<String, dynamic> j) => PartnerPrefs(
        services: ((j['services'] as List?) ?? const [])
            .map((e) => e as String)
            .toSet(),
        minFare: (j['min_fare'] as num?)?.toDouble() ?? 0,
      );
}

/// Por que ESTA oferta veio para este parceiro — números do despacho, não
/// estimativa da tela. `rank`/`pool` são a posição na fila de elegíveis no
/// instante da oferta; `onlineSeconds` é há quanto tempo ele está online (o
/// mesmo `idle_seconds` que alimenta o score de justiça).
class OfferDispatch {
  final int rank, pool;
  final double? score;
  final int? onlineSeconds;
  final double? rating;
  final int? ratingCount;
  final double? acceptanceRate;
  final String? vehicle;

  OfferDispatch({
    required this.rank,
    required this.pool,
    this.score,
    this.onlineSeconds,
    this.rating,
    this.ratingCount,
    this.acceptanceRate,
    this.vehicle,
  });

  factory OfferDispatch.fromJson(Map<String, dynamic> j) => OfferDispatch(
        rank: (j['rank'] as num?)?.toInt() ?? 1,
        pool: (j['pool'] as num?)?.toInt() ?? 1,
        score: (j['score'] as num?)?.toDouble(),
        onlineSeconds: (j['online_seconds'] as num?)?.toInt(),
        rating: (j['rating'] as num?)?.toDouble(),
        ratingCount: (j['rating_count'] as num?)?.toInt(),
        acceptanceRate: (j['acceptance_rate'] as num?)?.toDouble(),
        vehicle: j['vehicle'] as String?,
      );
}

/// Oferta simultânea (SPECS §1.2) — cronômetro é do servidor; o app só conta.
class Offer {
  final String offerId, rideId;
  final double amount; // bruto ao parceiro
  final double? pickupDistanceKm, tripDistanceKm;
  final String? destinationArea; // privacidade: área, não endereço exato
  /// MOTO (tarifa) ou MOTO_NEGOCIA (preço proposto pelo passageiro).
  final String? service;
  /// Tempo estimado até o embarque e até o destino (min) — o mesmo 30 km/h
  /// que o painel usa no ≈ R$/h, para os números não se contradizerem.
  final int? pickupEtaMin, tripDurationMin;
  /// Multiplicador de demanda/hora aplicado à tarifa; null em oferta negociada.
  final double? priceMultiplier;
  /// Pontos da rota — o mapa da oferta precisa deles antes do aceite.
  final GeoPoint? origin, destination;
  final DateTime timeoutAt; // PRM-oferta.timeout (15 s)
  /// Dados do passageiro — apenas o necessário para decisão de aceite.
  final String? passengerName; // nome do passageiro (sem CPF/docs)
  final double? passengerRating; // avaliação do passageiro (se existir)
  /// Explicação do despacho (null quando o servidor antigo não manda).
  final OfferDispatch? dispatch;

  Offer({
    required this.offerId,
    required this.rideId,
    required this.amount,
    required this.timeoutAt,
    this.pickupDistanceKm,
    this.tripDistanceKm,
    this.destinationArea,
    this.service,
    this.pickupEtaMin,
    this.tripDurationMin,
    this.priceMultiplier,
    this.origin,
    this.destination,
    this.passengerName,
    this.passengerRating,
    this.dispatch,
  });

  /// Tipo da oferta em pt-BR — `MOTO_NEGOCIA` não se lê numa tela.
  String get serviceLabel => serviceName(service);

  factory Offer.fromJson(Map<String, dynamic> j) => Offer(
        offerId: j['offer_id'] as String,
        rideId: j['ride_id'] as String,
        amount: (j['amount'] as num).toDouble(),
        pickupDistanceKm: (j['pickup_distance_km'] as num?)?.toDouble(),
        tripDistanceKm: (j['trip_distance_km'] as num?)?.toDouble(),
        destinationArea: j['destination_area'] as String?,
        service: j['service'] as String?,
        pickupEtaMin: (j['pickup_eta_min'] as num?)?.toInt(),
        tripDurationMin: (j['trip_duration_min'] as num?)?.toInt(),
        priceMultiplier: (j['price_multiplier'] as num?)?.toDouble(),
        origin: Ride._pt(j['origin']),
        destination: Ride._pt(j['destination']),
        passengerName: j['passenger_name'] as String?,
        passengerRating: (j['passenger_rating'] as num?)?.toDouble(),
        dispatch: j['dispatch'] is Map<String, dynamic>
            ? OfferDispatch.fromJson(j['dispatch'] as Map<String, dynamic>)
            : null,
        timeoutAt: DateTime.parse(j['timeout_at'] as String),
      );

  Duration remaining(DateTime now) {
    final r = timeoutAt.difference(now);
    return r.isNegative ? Duration.zero : r;
  }
}

/// O que o parceiro perdeu ao recusar (ou deixar o tempo estourar) — vem do
/// servidor com o valor congelado e a taxa de aceite antes/depois. O app não
/// recalcula nada: a consequência exibida é a que o despacho aplicou de fato.
class OfferLoss {
  final String offerId, rideId;
  /// DECLINED (apertou Recusar) | EXPIRED (estourou o tempo).
  final String reason;
  final double lostAmount;
  final double? pickupDistanceKm, tripDistanceKm;
  final int? pickupEtaMin, tripDurationMin, timeoutS;
  final double? acceptanceRateBefore, acceptanceRate;

  OfferLoss({
    required this.offerId,
    required this.rideId,
    required this.reason,
    required this.lostAmount,
    this.pickupDistanceKm,
    this.tripDistanceKm,
    this.pickupEtaMin,
    this.tripDurationMin,
    this.timeoutS,
    this.acceptanceRateBefore,
    this.acceptanceRate,
  });

  bool get expired => reason == 'EXPIRED';

  factory OfferLoss.fromJson(Map<String, dynamic> j) => OfferLoss(
        offerId: j['offer_id'] as String,
        rideId: j['ride_id'] as String,
        reason: (j['reason'] as String?) ?? 'DECLINED',
        lostAmount: (j['lost_amount'] as num?)?.toDouble() ?? 0,
        pickupDistanceKm: (j['pickup_distance_km'] as num?)?.toDouble(),
        tripDistanceKm: (j['trip_distance_km'] as num?)?.toDouble(),
        pickupEtaMin: (j['pickup_eta_min'] as num?)?.toInt(),
        tripDurationMin: (j['trip_duration_min'] as num?)?.toInt(),
        timeoutS: (j['timeout_s'] as num?)?.toInt(),
        acceptanceRateBefore: (j['acceptance_rate_before'] as num?)?.toDouble(),
        acceptanceRate: (j['acceptance_rate'] as num?)?.toDouble(),
      );
}

/// Um dia da semana de desempenho (GET /partner/performance).
///
/// Os nulos são informação: `acceptanceRate == null` significa "nenhuma
/// chamada neste dia", não "0% de aceite".
class PerfDay {
  final String date; // YYYY-MM-DD no fuso da praça
  final String weekday; // seg..dom
  final int offers, accepted, declined, expired;
  final int onlineSeconds, rankSamples, ratings;
  final double? acceptanceRate, avgRank, pool, ratingAvg;

  PerfDay({
    required this.date,
    required this.weekday,
    required this.offers,
    required this.accepted,
    required this.declined,
    required this.expired,
    required this.onlineSeconds,
    required this.rankSamples,
    required this.ratings,
    this.acceptanceRate,
    this.avgRank,
    this.pool,
    this.ratingAvg,
  });

  /// Houve algum evento observável (chamada ou tempo conectado) neste dia.
  bool get hasActivity => offers > 0 || onlineSeconds > 0;

  factory PerfDay.fromJson(Map<String, dynamic> j) => PerfDay(
        date: (j['date'] as String?) ?? '',
        weekday: (j['weekday'] as String?) ?? '',
        offers: (j['offers'] as num?)?.toInt() ?? 0,
        accepted: (j['accepted'] as num?)?.toInt() ?? 0,
        declined: (j['declined'] as num?)?.toInt() ?? 0,
        expired: (j['expired'] as num?)?.toInt() ?? 0,
        onlineSeconds: (j['online_seconds'] as num?)?.toInt() ?? 0,
        rankSamples: (j['rank_samples'] as num?)?.toInt() ?? 0,
        ratings: (j['ratings'] as num?)?.toInt() ?? 0,
        acceptanceRate: (j['acceptance_rate'] as num?)?.toDouble(),
        avgRank: (j['avg_rank'] as num?)?.toDouble(),
        pool: (j['pool'] as num?)?.toDouble(),
        ratingAvg: (j['rating_avg'] as num?)?.toDouble(),
      );
}

/// Desempenho semanal do parceiro — números observados pelo servidor
/// (chamadas, aceites, recusas, tempo conectado, posição no ranking e notas).
class DriverPerformance {
  final String date, weekStart, timezone;
  final List<PerfDay> days;
  final double? acceptanceCurrent, acceptanceWeek;
  final int offers, accepted, declined, expired;
  final int weekOnlineSeconds, todayOnlineSeconds, sessionSeconds;
  final double? ratingValue, weekRatingAvg;
  final int ratingCount, weekRatings;
  final double? rankAvg, rankPool;
  final int? rankBest, rankWorst;
  final int rankSamples;

  DriverPerformance({
    required this.date,
    required this.weekStart,
    required this.timezone,
    required this.days,
    this.acceptanceCurrent,
    this.acceptanceWeek,
    this.offers = 0,
    this.accepted = 0,
    this.declined = 0,
    this.expired = 0,
    this.weekOnlineSeconds = 0,
    this.todayOnlineSeconds = 0,
    this.sessionSeconds = 0,
    this.ratingValue,
    this.ratingCount = 0,
    this.weekRatings = 0,
    this.weekRatingAvg,
    this.rankAvg,
    this.rankBest,
    this.rankWorst,
    this.rankPool,
    this.rankSamples = 0,
  });

  /// A semana teve algum evento? Sem isso a tela não inventa percentuais.
  bool get hasWeekData =>
      offers > 0 || weekOnlineSeconds > 0 || rankSamples > 0 || weekRatings > 0;

  /// Recusas + timeouts na semana: é o que derruba a taxa de aceite.
  int get missedOffers => declined + expired;

  factory DriverPerformance.fromJson(Map<String, dynamic> j) {
    final acc = (j['acceptance'] as Map<String, dynamic>?) ?? const {};
    final online = (j['online'] as Map<String, dynamic>?) ?? const {};
    final rating = (j['rating'] as Map<String, dynamic>?) ?? const {};
    final rank = (j['rank'] as Map<String, dynamic>?) ?? const {};
    return DriverPerformance(
      date: (j['date'] as String?) ?? '',
      weekStart: (j['week_start'] as String?) ?? '',
      timezone: (j['timezone'] as String?) ?? '',
      days: ((j['days'] as List?) ?? const [])
          .map((e) => PerfDay.fromJson(e as Map<String, dynamic>))
          .toList(),
      acceptanceCurrent: (acc['current'] as num?)?.toDouble(),
      acceptanceWeek: (acc['week'] as num?)?.toDouble(),
      offers: (acc['offers'] as num?)?.toInt() ?? 0,
      accepted: (acc['accepted'] as num?)?.toInt() ?? 0,
      declined: (acc['declined'] as num?)?.toInt() ?? 0,
      expired: (acc['expired'] as num?)?.toInt() ?? 0,
      weekOnlineSeconds: (online['week_seconds'] as num?)?.toInt() ?? 0,
      todayOnlineSeconds: (online['today_seconds'] as num?)?.toInt() ?? 0,
      sessionSeconds: (online['session_seconds'] as num?)?.toInt() ?? 0,
      ratingValue: (rating['value'] as num?)?.toDouble(),
      ratingCount: (rating['count'] as num?)?.toInt() ?? 0,
      weekRatings: (rating['week_count'] as num?)?.toInt() ?? 0,
      weekRatingAvg: (rating['week_avg'] as num?)?.toDouble(),
      rankAvg: (rank['avg'] as num?)?.toDouble(),
      rankBest: (rank['best'] as num?)?.toInt(),
      rankWorst: (rank['worst'] as num?)?.toInt(),
      rankPool: (rank['pool'] as num?)?.toDouble(),
      rankSamples: (rank['samples'] as num?)?.toInt() ?? 0,
    );
  }
}

enum PricingModeSnapshot { passe, comissao }

/// Estado da corrida do parceiro (após aceite) — schema Ride do contrato.
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
      this == RideStatus.aceita ||
      this == RideStatus.aCaminho ||
      this == RideStatus.chegou ||
      this == RideStatus.emViagem;
}

class Ride {
  final String rideId;
  final RideStatus status;
  final String? pricingModeSnapshot; // PASSE | COMISSAO (A4: imutável)
  final double? fareTotal, proposedAmount;
  final int? etaSeconds;
  final GeoPoint? origin, destination;
  final String? originAddress, destinationAddress;
  final String? partnerName; // exibição no histórico
  final DateTime? createdAt;

  Ride({
    required this.rideId,
    required this.status,
    this.pricingModeSnapshot,
    this.fareTotal,
    this.proposedAmount,
    this.etaSeconds,
    this.origin,
    this.destination,
    this.originAddress,
    this.destinationAddress,
    this.partnerName,
    this.createdAt,
  });

  factory Ride.fromJson(Map<String, dynamic> j) => Ride(
        rideId: j['ride_id'] as String,
        status: RideStatus.fromWire(j['status'] as String),
        pricingModeSnapshot: j['pricing_mode'] as String?,
        fareTotal: (j['fare_total'] as num?)?.toDouble(),
        proposedAmount: (j['proposed_amount'] as num?)?.toDouble(),
        etaSeconds: j['eta_seconds'] as int?,
        origin: _pt(j['origin']),
        destination: _pt(j['destination']),
        originAddress: j['origin_address'] as String?,
        destinationAddress: j['destination_address'] as String?,
        partnerName:
            (j['partner'] as Map<String, dynamic>?)?['name'] as String?,
        createdAt: j['created_at'] != null
            ? DateTime.tryParse(j['created_at'] as String)
            : null,
      );

  static GeoPoint? _pt(dynamic v) => v is Map<String, dynamic>
      ? GeoPoint((v['lat'] as num).toDouble(), (v['lon'] as num).toDouble())
      : null;
}

/// ATR-003: saldo, dívida e extrato itemizado (REQ-003: cada componente).
class WalletEntry {
  final String entryGroupId, description;
  final String direction; // D | C
  final double amount;
  final DateTime createdAt;
  final String? rideId, passId;

  WalletEntry({
    required this.entryGroupId,
    required this.description,
    required this.direction,
    required this.amount,
    required this.createdAt,
    this.rideId,
    this.passId,
  });

  factory WalletEntry.fromJson(Map<String, dynamic> j) => WalletEntry(
        entryGroupId: j['entry_group_id'] as String,
        description: j['description'] as String,
        direction: j['direction'] as String,
        amount: (j['amount'] as num).toDouble(),
        createdAt: DateTime.parse(j['created_at'] as String),
        rideId: j['ride_id'] as String?,
        passId: j['pass_id'] as String?,
      );
}

class Wallet {
  final double balance;
  final int debtCents;
  final List<WalletEntry> statement;
  Wallet(
      {required this.balance,
      required this.debtCents,
      required this.statement});

  factory Wallet.fromJson(Map<String, dynamic> j) => Wallet(
        balance: (j['balance'] as num).toDouble(),
        debtCents: (j['debt_cents'] as int?) ?? 0,
        statement: (j['statement'] as List)
            .map((e) => WalletEntry.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

/// Passe atual + fila FIFO (A3) + preço vigente da cidade.
class PassState {
  final String mode; // PASSE_ATIVO | COMISSAO
  final String? activePassId;
  final DateTime? expiresAt; // relógio do SERVIDOR (A7)
  final String? countingStrategy;
  final List<Map<String, dynamic>> queue;
  final double? price;

  PassState({
    required this.mode,
    required this.queue,
    this.activePassId,
    this.expiresAt,
    this.countingStrategy,
    this.price,
  });

  factory PassState.fromJson(Map<String, dynamic> j) => PassState(
        mode: j['mode'] as String,
        activePassId:
            (j['active'] as Map<String, dynamic>?)?['pass_id'] as String?,
        expiresAt: (j['active'] as Map<String, dynamic>?)?['expires_at'] != null
            ? DateTime.parse(
                ((j['active'] as Map<String, dynamic>)['expires_at']) as String)
            : null,
        countingStrategy: (j['active']
            as Map<String, dynamic>?)?['counting_strategy'] as String?,
        queue: ((j['queue'] as List?) ?? const [])
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList(),
        price: (j['price'] as num?)?.toDouble(),
      );
}

/// Resultado do POST /kyc/cases (F9): 3 faixas de decisão.
class KycCase {
  final String caseId;
  final String status; // AUTO_APPROVED | IN_REVIEW | REJECTED | RESUBMIT
  final int? position;
  final DateTime? sla;
  KycCase(
      {required this.caseId, required this.status, this.position, this.sla});

  factory KycCase.fromJson(Map<String, dynamic> j) => KycCase(
        caseId: j['case_id'] as String,
        status: j['status'] as String,
        position: j['position'] as int?,
        sla: j['sla'] != null ? DateTime.parse(j['sla'] as String) : null,
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

/// Token de acesso da sessão.
///
/// Pode ser síncrono (testes de contrato, build de dev com `API_TOKEN`) ou
/// assíncrono (o serviço de auth renova a sessão sozinho quando o token está
/// perto de vencer — a chamada precisa esperar por isso).
typedef TokenProvider = FutureOr<String> Function();

class ApiClient {
  ApiClient({
    required this.baseUrl,
    required this.accessToken,
    this.ridesBase,
    http.Client? inner,
    IdempotencyKey? newIdemKey,
  })  : _http = inner ?? http.Client(),
        _newIdemKey = newIdemKey ?? _uuid;

  /// Base do que ainda roda na API de demonstração (perfil, KYC, passe,
  /// carteira, desempenho, preferências). Ex.: http://10.0.2.2:8787/functions/v1/v1
  final String baseUrl;

  /// Base do backend REAL do ciclo de corrida (Edge Function `rides` do
  /// Supabase): ofertas, aceite/recusa, fases da corrida, histórico e
  /// pagamento.
  ///
  /// Quando vem nulo (testes de contrato, modo demo), tudo continua na base
  /// de demonstração — o app não quebra e o comportamento é o de antes.
  final String? ridesBase;

  /// O ciclo de corrida já fala com o Postgres de verdade?
  bool get usesRidesBackend => ridesBase != null && ridesBase!.isNotEmpty;

  String get _ridesRoot {
    final b = ridesBase ?? '';
    return b.endsWith('/') ? b.substring(0, b.length - 1) : b;
  }

  final TokenProvider accessToken;
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

  Future<Map<String, String>> _headers() async => {
        'authorization': 'Bearer ${await accessToken()}',
        'content-type': 'application/json',
      };

  Future<Map<String, dynamic>> _req(
    String method,
    String path, {
    Object? body,
    bool idempotent = false,
    Map<String, String>? query,
    bool rides = false,
  }) async {
    // `rides: true` manda a chamada para o backend real do ciclo de corrida
    // — quando ele não está configurado, cai na base de demonstração.
    final base = (rides && usesRidesBackend) ? _ridesRoot : baseUrl;
    final uri = Uri.parse('$base$path').replace(queryParameters: query);
    final headers = {...await _headers()};
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

  // --- perfil -------------------------------------------------------------

  /// Perfil do parceiro. No backend real vem do TOKEN (o `sub` do JWT):
  /// o app mostra a conta que autenticou, não um usuário de demonstração.
  Future<Me> me() async => Me.fromJson(await _req('GET', '/me', rides: true));

  // --- presença (P2 painel) ----------------------------------------------

  /// 200 { mode, pass_expires_at } · 403 kyc_not_approved (F9: em análise
  /// não pode ficar online).
  Future<Map<String, dynamic>> goOnline({
    required double lat,
    required double lon,
    double? accuracy,
  }) =>
      _req(
        'POST',
        '/partner/online',
        idempotent: true,
        body: {
          'lat': lat,
          'lon': lon,
          if (accuracy != null) 'accuracy': accuracy,
        },
      );

  Future<void> goOffline() => _req('POST', '/partner/offline');

  /// Inicia pausa. 200 { started_at, expires_at } (relógio do servidor — A7).
  Future<Map<String, dynamic>> startBreak({required int minutes}) => _req(
        'POST',
        '/partner/break/start',
        idempotent: true,
        body: {'minutes': minutes},
      );

  /// Encerra pausa antecipadamente.
  Future<void> endBreak() => _req('POST', '/partner/break/end');

  /// GET /partner/performance — semana do motorista (7 dias até hoje, no
  /// fuso da praça). Campos sem evento no período vêm nulos.
  Future<DriverPerformance> performance() async =>
      DriverPerformance.fromJson(await _req('GET', '/partner/performance'));

  // --- preferências de solicitações (Configurar solicitações) -------------

  /// GET /partner/preferences — tipos que o parceiro quer receber + o valor
  /// mínimo por corrida (piso do despacho).
  Future<PartnerPrefs> partnerPreferences() async {
    final j = await _req('GET', '/partner/preferences');
    return PartnerPrefs.fromJson(j);
  }

  /// PUT /partner/preferences — 422 invalid_services se nenhum tipo sobrar.
  /// `minFare` só vai no corpo quando o parceiro o altera; os switches não
  /// resetam o piso (o servidor preserva o valor ausente).
  Future<PartnerPrefs> savePartnerPreferences(
    Set<String> services, {
    double? minFare,
  }) async {
    final j = await _req('PUT', '/partner/preferences', body: {
      'services': services.toList()..sort(),
      if (minFare != null) 'min_fare': minFare,
    });
    return PartnerPrefs.fromJson(j);
  }

  /// Lote de posições (offline-tolerante; servidor é o relogio — A7).
  Future<void> heartbeat(List<Map<String, dynamic>> points) =>
      _req('POST', '/partner/heartbeat', body: {'points': points});

  // --- ofertas (P3) -------------------------------------------------------

  Future<List<Offer>> myOffers() async {
    final j = await _req('GET', '/offers/mine', rides: true);
    return (j['offers'] as List)
        .map((e) => Offer.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 200 (aceita, snapshot capturado) · 409 offer_unavailable.
  Future<void> acceptOffer(String offerId) =>
      _req('POST', '/offers/$offerId/accept', idempotent: true, rides: true);

  /// 200 → o que foi perdido (valor, coleta e aceite antes/depois);
  /// 409 offer_unavailable → a oferta já não estava mais viva.
  Future<OfferLoss?> declineOffer(String offerId) async {
    final j = await _req('POST', '/offers/$offerId/decline', rides: true);
    final loss = j['loss'];
    return loss is Map<String, dynamic> ? OfferLoss.fromJson(loss) : null;
  }

  /// Oferta que saiu de /offers/mine: motivo (DECLINED/EXPIRED) e perda.
  /// Null quando o servidor não sabe explicar ou a oferta não existe.
  Future<OfferLoss?> offerOutcome(String offerId) async {
    try {
      final j = await _req('GET', '/offers/$offerId', rides: true);
      final loss = j['loss'];
      return loss is Map<String, dynamic> ? OfferLoss.fromJson(loss) : null;
    } on ApiProblem catch (p) {
      if (p.status == 404) return null;
      rethrow;
    }
  }

  // --- transições da corrida (P4/P5) --------------------------------------

  Future<Ride> ride(String id) async =>
      Ride.fromJson(await _req('GET', '/rides/$id', rides: true));

  /// Histórico do parceiro: corridas concluídas/canceladas em que houve
  /// aceite (partner atribuído). A demo filtra as simuladas; o backend real
  /// devolve as corridas do próprio parceiro (escopo pelo token).
  Future<List<Ride>> myRides() async {
    final j = await _req('GET', '/rides', rides: true);
    final list = (j['rides'] as List).cast<Map<String, dynamic>>();
    return list
        .where((r) {
          final name =
              ((r['partner'] as Map<String, dynamic>?)?['name'] as String?) ??
                  '';
          return r['partner'] != null && !name.contains('simulado');
        })
        .map(Ride.fromJson)
        .toList();
  }

  /// 200 · 409 illegal_transition. `fare_total` exigido ao FINALIZAR;
  /// `cash_declared` confirma o recebimento em dinheiro (ADR-003).
  Future<void> transition({
    required String rideId,
    required String to, // A_CAMINHO | CHEGOU | EM_VIAGEM | FINALIZADA
    double? fareTotal,
    bool? cashDeclared,
  }) =>
      _req(
        'POST',
        '/partner/transitions',
        idempotent: true,
        body: {
          'ride_id': rideId,
          'to': to,
          if (fareTotal != null) 'fare_total': fareTotal,
          if (cashDeclared != null) 'cash_declared': cashDeclared,
        },
        rides: true,
      );

  // --- passe (P6) ---------------------------------------------------------

  Future<PassState> passes() async =>
      PassState.fromJson(await _req('GET', '/partner/passes'));

  /// 201 { pass_id, checkout: { pix, card_url } } · 409 purchase_in_flight.
  Future<Map<String, dynamic>> buyPass() =>
      _req('POST', '/partner/passes', idempotent: true);

  // --- carteira (P7) ------------------------------------------------------

  Future<Wallet> wallet() async =>
      Wallet.fromJson(await _req('GET', '/partner/wallet'));

  /// 202 (saque na fila) · 409 insufficient | debt.
  Future<void> withdraw() =>
      _req('POST', '/partner/wallet/withdraw', idempotent: true);

  // --- mapa: calor de chamadas ----------------------------------------

  Future<HeatSnapshot> heatmap() async {
    final j = await _req('GET', '/heatmap');
    return HeatSnapshot.fromJson(j);
  }

  // --- gravações de segurança (vídeo opcional do parceiro) -------------

  Future<Recording> uploadRecording({
    required String rideId,
    required String kind, // AUDIO | VIDEO
    String? camera, // FRONT | REAR (só VIDEO)
    required int durationMs,
    required Uint8List bytes,
    String mime = 'video/webm',
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

  // --- KYC (P1 onboarding) ------------------------------------------------

  /// 201 { case_id, status, position?, sla }.
  Future<KycCase> submitKyc() async =>
      KycCase.fromJson(await _req('POST', '/kyc/cases', idempotent: true));

  /// Reenvio guiado só do documento rejeitado (F9).
  Future<void> resubmitDocument(String caseId) =>
      _req('POST', '/kyc/cases/$caseId/documents', idempotent: true);

  /// Cadastro completo do motorista (3.7).
  Future<PartnerInfo> updatePartnerProfile({
    String? fullName,
    String? phoneE164,
    String? cnhNumber,
    String? cnhCategory,
    DateTime? cnhExpiry,
    String? vehiclePlate,
    String? vehicleModel,
    String? vehicleYear,
  }) async {
    final j = await _req(
      'PUT',
      '/partner/profile',
      idempotent: true,
      body: {
        if (fullName != null) 'full_name': fullName,
        if (phoneE164 != null) 'phone_e164': phoneE164,
        if (cnhNumber != null) 'cnh_number': cnhNumber,
        if (cnhCategory != null) 'cnh_category': cnhCategory,
        if (cnhExpiry != null) 'cnh_expiry': cnhExpiry.toIso8601String(),
        if (vehiclePlate != null) 'vehicle_plate': vehiclePlate,
        if (vehicleModel != null) 'vehicle_model': vehicleModel,
        if (vehicleYear != null) 'vehicle_year': vehicleYear,
      },
    );
    return PartnerInfo.fromJson(j['partner'] as Map<String, dynamic>);
  }

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

// --- raspadinha de prêmios (3.8) ------------------------------------------

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
