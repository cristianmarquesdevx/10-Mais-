import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parceiro/src/api/client.dart';

/// Contrato client ↔ openapi.yaml (parceiro): Idempotency-Key em toda
/// mutação que o contrato exige, problem+json → ApiProblem(code), formatos
/// de corpo e enums conforme spec/0001.
///
/// [resp] mocka o servidor com charset UTF-8 — JSON é UTF-8 por padrão
/// (RFC 8259) e o pacote http codifica latin1 quando o header omite charset.
http.Response resp(String body, int statusCode) => http.Response(
      body,
      statusCode,
      headers: const {'content-type': 'application/json; charset=utf-8'},
    );

void main() {
  late List<http.Request> seen;
  int idemCalls = 0;

  ApiClient clientWith(MockClient handler) {
    seen = [];
    idemCalls = 0;
    return ApiClient(
      baseUrl: 'http://test.local/functions/v1/v1',
      accessToken: () => 'jwt-test',
      inner: handler,
      newIdemKey: () => 'idem-${++idemCalls}',
    );
  }

  test('POST /partner/online envia {lat,lon} + Idempotency-Key + JWT e '
      'parseia mode/pass_expires_at', () async {
    final api = clientWith(MockClient((req) async {
      seen.add(req);
      return resp(
          '{"mode":"PASSE_ATIVO","pass_expires_at":"2026-10-11T12:00:00Z"}',
          200);
    }));

    final r =
        await api.goOnline(lat: -8.7607, lon: -63.9039, accuracy: 12.5);

    expect(seen.single.method, 'POST');
    expect(seen.single.url.path, '/functions/v1/v1/partner/online');
    expect(seen.single.headers['Idempotency-Key'], 'idem-1');
    expect(seen.single.headers['authorization'], 'Bearer jwt-test');
    final body = jsonDecode(seen.single.body) as Map<String, dynamic>;
    expect(body, {'lat': -8.7607, 'lon': -63.9039, 'accuracy': 12.5});
    expect(r['mode'], 'PASSE_ATIVO');
    expect(DateTime.parse(r['pass_expires_at'] as String).isUtc, isTrue);
  });

  test('403 kyc_not_approved vira ApiProblem.code (F9: em análise ≠ online)',
      () async {
    final api = clientWith(MockClient((req) async => resp(
        '{"title":"Forbidden","status":403,"code":"kyc_not_approved"}', 403)));

    await expectLater(
      api.goOnline(lat: 0, lon: 0),
      throwsA(isA<ApiProblem>()
          .having((p) => p.code, 'code', 'kyc_not_approved')
          .having((p) => p.status, 'status', 403)),
    );
  });

  test('POST /partner/offline não envia Idempotency-Key (contrato: sem header)',
      () async {
    final api = clientWith(MockClient((req) async {
      seen.add(req);
      return resp('', 200);
    }));

    await api.goOffline();

    expect(seen.single.method, 'POST');
    expect(seen.single.url.path, '/functions/v1/v1/partner/offline');
    expect(seen.single.headers.containsKey('Idempotency-Key'), isFalse);
  });

  test('GET /offers/mine parseia oferta com countdown do servidor', () async {
    final api = clientWith(MockClient((req) async {
      seen.add(req);
      return resp('{"offers":[{'
          '"offer_id":"11111111-2222-3333-4444-555555555555",'
          '"ride_id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",'
          '"amount":18.5,"pickup_distance_km":1.2,"trip_distance_km":4.8,'
          '"destination_area":"B. São Pedro",'
          '"service":"MOTO_NEGOCIA","pickup_eta_min":2,'
          '"trip_duration_min":10,"price_multiplier":null,'
          '"origin":{"lat":-8.7607,"lon":-63.9039},'
          '"destination":{"lat":-8.7647,"lon":-63.8969},'
          '"passenger_name":"Passageira demo","passenger_rating":4.9,'
          '"dispatch":{"rank":1,"pool":3,"score":0.81,'
          '"online_seconds":742,"rating":4.85,"rating_count":44,'
          '"acceptance_rate":0.91,"vehicle":"Moto"},'
          '"timeout_at":"2099-01-01T00:00:15Z"}]}', 200);
    }));

    final offers = await api.myOffers();

    expect(seen.single.method, 'GET');
    expect(seen.single.url.path, '/functions/v1/v1/offers/mine');
    final o = offers.single;
    expect(o.amount, 18.5);
    expect(o.destinationArea, 'B. São Pedro');
    expect(o.remaining(DateTime.utc(2099)).inSeconds, 15);
    // O card da oferta mostra tipo, tempos e passageiro direto do contrato.
    expect(o.serviceLabel, 'Moto Negocia');
    expect(o.pickupEtaMin, 2);
    expect(o.tripDurationMin, 10);
    expect(o.priceMultiplier, isNull); // negociada: sem multiplicador
    expect(o.origin!.lat, closeTo(-8.7607, 1e-9));
    expect(o.destination!.lon, closeTo(-63.8969, 1e-9));
    expect(o.passengerName, 'Passageira demo');
    expect(o.passengerRating, 4.9);
    // O "por que eu?" vem do servidor, com os números do despacho.
    final d = o.dispatch!;
    expect(d.rank, 1);
    expect(d.pool, 3);
    expect(d.onlineSeconds, 742);
    expect(d.rating, 4.85);
    expect(d.ratingCount, 44);
    expect(d.acceptanceRate, 0.91);
    expect(d.vehicle, 'Moto');
  });

  test('oferta de servidor antigo (sem dispatch) não quebra o card', () async {
    final api = clientWith(MockClient((req) async => resp('{"offers":[{'
        '"offer_id":"11111111-2222-3333-4444-555555555555",'
        '"ride_id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",'
        '"amount":18.5,"timeout_at":"2099-01-01T00:00:15Z"}]}', 200)));

    final o = (await api.myOffers()).single;
    expect(o.dispatch, isNull); // a tela esconde o painel de explicação
  });

  test('decline devolve o que foi perdido e o aceite antes/depois', () async {
    final api = clientWith(MockClient((req) async {
      seen.add(req);
      return resp('{"loss":{'
          '"offer_id":"11111111-2222-3333-4444-555555555555",'
          '"ride_id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",'
          '"reason":"DECLINED","lost_amount":18.5,'
          '"pickup_distance_km":1.2,"pickup_eta_min":2,'
          '"trip_distance_km":4.8,"trip_duration_min":10,'
          '"acceptance_rate_before":0.95,"acceptance_rate":0.9215,'
          '"timeout_s":15}}', 200);
    }));

    final loss =
        await api.declineOffer('11111111-2222-3333-4444-555555555555');

    expect(seen.single.method, 'POST');
    expect(
        seen.single.url.path,
        '/functions/v1/v1/offers/'
        '11111111-2222-3333-4444-555555555555/decline');
    expect(loss!.reason, 'DECLINED');
    expect(loss.expired, isFalse);
    expect(loss.lostAmount, 18.5);
    expect(loss.pickupEtaMin, 2);
    expect(loss.acceptanceRateBefore, 0.95);
    expect(loss.acceptanceRate, 0.9215); // a penalização de 3% é do servidor
  });

  test('GET /offers/{id} explica a oferta que venceu por tempo', () async {
    final api = clientWith(MockClient((req) async {
      seen.add(req);
      return resp('{"offer_id":"11111111-2222-3333-4444-555555555555",'
          '"ride_id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",'
          '"status":"EXPIRED","loss":{'
          '"offer_id":"11111111-2222-3333-4444-555555555555",'
          '"ride_id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",'
          '"reason":"EXPIRED","lost_amount":18.5,'
          '"acceptance_rate_before":0.9215,"acceptance_rate":0.8939,'
          '"timeout_s":15}}', 200);
    }));

    final loss =
        await api.offerOutcome('11111111-2222-3333-4444-555555555555');

    expect(seen.single.method, 'GET');
    expect(seen.single.url.path,
        '/functions/v1/v1/offers/11111111-2222-3333-4444-555555555555');
    expect(loss!.expired, isTrue);
    expect(loss.timeoutS, 15);
    expect(loss.acceptanceRate, 0.8939);
  });

  test('GET/PUT /partner/preferences: tipos ligados vão e voltam', () async {
    late http.Request put;
    final api = clientWith(MockClient((req) async {
      seen.add(req);
      if (req.method == 'GET') {
        return resp('{"services":["MOTO","MOTO_NEGOCIA"]}', 200);
      }
      put = req;
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      return resp(jsonEncode({'services': body['services']}), 200);
    }));

    final lidos = await api.partnerPreferences();
    expect(lidos.services, {'MOTO', 'MOTO_NEGOCIA'});
    expect(lidos.minFare, 0);
    expect(seen.single.url.path, '/functions/v1/v1/partner/preferences');

    final salvos = await api.savePartnerPreferences({'MOTO'});
    expect(salvos.services, {'MOTO'});
    expect(put.method, 'PUT');
    expect(put.body, '{"services":["MOTO"]}');
    // PUT substitui a lista inteira: sem Idempotency-Key, como o contrato.
    expect(put.headers.containsKey('Idempotency-Key'), isFalse);
  });

  test('accept envia Idempotency-Key; 409 offer_unavailable → code', () async {
    var n = 0;
    final api = clientWith(MockClient((req) async {
      seen.add(req);
      n++;
      if (n == 1) return resp('', 200);
      return resp(
          '{"title":"Conflict","status":409,"code":"offer_unavailable"}', 409);
    }));

    await api.acceptOffer('11111111-2222-3333-4444-555555555555');
    expect(seen.single.headers['Idempotency-Key'], 'idem-1');
    expect(seen.single.url.path,
        '/functions/v1/v1/offers/11111111-2222-3333-4444-555555555555/accept');

    await expectLater(
      api.acceptOffer('11111111-2222-3333-4444-555555555555'),
      throwsA(isA<ApiProblem>().having((p) => p.code, 'code',
          'offer_unavailable')), // primeiro a aceitar vence (SPECS §1.2)
    );
  });

  test('transição envia {ride_id,to[,fare_total,cash_declared]} — fare_total '
      'só em FINALIZADA', () async {
    final api = clientWith(MockClient((req) async {
      seen.add(req);
      return resp('{}', 200);
    }));

    await api.transition(
        rideId: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee', to: 'EM_VIAGEM');
    expect(jsonDecode(seen.last.body),
        {'ride_id': 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee', 'to': 'EM_VIAGEM'});
    expect(seen.last.headers['Idempotency-Key'], isNotNull);

    await api.transition(
      rideId: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
      to: 'FINALIZADA',
      fareTotal: 22.0,
      cashDeclared: true,
    );
    expect(jsonDecode(seen.last.body), {
      'ride_id': 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
      'to': 'FINALIZADA',
      'fare_total': 22.0,
      'cash_declared': true,
    });
  });

  test('409 illegal_transition → code (transição só por função de domínio)',
      () async {
    final api = clientWith(MockClient((req) async => resp(
        '{"title":"Conflict","status":409,"code":"illegal_transition"}',
        409)));

    await expectLater(
      api.transition(
          rideId: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee', to: 'CHEGOU'),
      throwsA(
          isA<ApiProblem>().having((p) => p.code, 'code', 'illegal_transition')),
    );
  });

  test('GET /partner/wallet parseia saldo, dívida e extrato itemizado',
      () async {
    final api = clientWith(MockClient((req) async {
      seen.add(req);
      return resp('{"balance":134.5,"debt_cents":350,"statement":[{'
          '"entry_group_id":"11111111-2222-3333-4444-555555555555",'
          '"description":"Corrida PASSE (bruto total)",'
          '"direction":"C","amount":18.5,'
          '"created_at":"2026-10-10T12:00:00Z"},{'
          '"entry_group_id":"22222222-2222-3333-4444-555555555555",'
          '"description":"Comissão 12%",'
          '"direction":"D","amount":2.22,'
          '"created_at":"2026-10-10T12:00:01Z"}]}', 200);
    }));

    final w = await api.wallet();

    expect(seen.single.url.path, '/functions/v1/v1/partner/wallet');
    expect(w.balance, 134.5);
    expect(w.debtCents, 350);
    expect(w.statement, hasLength(2));
    expect(w.statement[0].direction, 'C');
    expect(w.statement[1].direction, 'D');
    expect(w.statement[1].amount, 2.22);
  });

  test('withdraw: 409 debt → code (ADR-003: dívida bloqueia saque)', () async {
    final api = clientWith(MockClient((req) async {
      seen.add(req);
      return resp(
          '{"title":"Conflict","status":409,"code":"debt"}', 409);
    }));

    await expectLater(
      api.withdraw(),
      throwsA(isA<ApiProblem>().having((p) => p.code, 'code', 'debt')),
    );
    expect(seen.single.headers['Idempotency-Key'], isNotNull);
  });

  test('GET /partner/passes parseia modo, ativo e fila FIFO', () async {
    final api = clientWith(MockClient((req) async {
      seen.add(req);
      return resp('{"mode":"PASSE_ATIVO",'
          '"active":{"pass_id":"11111111-2222-3333-4444-555555555555",'
          '"expires_at":"2099-01-01T12:00:00Z",'
          '"counting_strategy":"RELOGIO_CORRIDO"},'
          '"queue":[{"pass_id":"22222222-2222-3333-4444-555555555555",'
          '"status":"SCHEDULED"}],'
          '"price":10.0}', 200);
    }));

    final s = await api.passes();

    expect(s.mode, 'PASSE_ATIVO');
    expect(s.activePassId, '11111111-2222-3333-4444-555555555555');
    expect(s.countingStrategy, 'RELOGIO_CORRIDO');
    expect(s.queue.single['status'], 'SCHEDULED'); // A3: FIFO
    expect(s.price, 10.0);
  });

  test('POST /partner/passes envia Idempotency-Key e parseia checkout',
      () async {
    final api = clientWith(MockClient((req) async {
      seen.add(req);
      return resp(
          '{"pass_id":"11111111-2222-3333-4444-555555555555",'
          '"checkout":{"pix":"00020126BR.GOV.BCB.PIX...","card_url":"https://pago.local/x"}}',
          201);
    }));

    final r = await api.buyPass();

    expect(seen.single.headers['Idempotency-Key'], 'idem-1');
    expect(r['pass_id'], '11111111-2222-3333-4444-555555555555');
    expect((r['checkout'] as Map)['pix'], startsWith('0002'));
  });

  test('POST /kyc/cases parseia 3 faixas (AUTO_APPROVED/IN_REVIEW/REJECTED)',
      () async {
    var n = 0;
    final api = clientWith(MockClient((req) async {
      seen.add(req);
      n++;
      return resp(
          n == 1
              ? '{"case_id":"cafebabe-0000-0000-0000-000000000000",'
                  '"status":"IN_REVIEW","position":7,'
                  '"sla":"2026-10-11T20:00:00Z"}'
              : '{"case_id":"cafebabe-0000-0000-0000-000000000000",'
                  '"status":"AUTO_APPROVED"}',
          201);
    }));

    final c1 = await api.submitKyc();
    expect(seen.single.headers['Idempotency-Key'], 'idem-1');
    expect(c1.status, 'IN_REVIEW');
    expect(c1.position, 7);
    expect(c1.sla, isNotNull);

    final c2 = await api.submitKyc();
    expect(c2.status, 'AUTO_APPROVED');
    expect(c2.position, isNull);
  });

  test('GET /partner/performance parseia a semana (aceite, online, nota e '
      'posição no ranking)', () async {
    final api = clientWith(MockClient((req) async {
      seen.add(req);
      return resp('{"date":"2026-10-25","week_start":"2026-10-19",'
          '"timezone":"America/Porto_Velho","days":[{'
          '"date":"2026-10-19","weekday":"seg","offers":4,"accepted":3,'
          '"declined":1,"expired":0,"acceptance_rate":0.75,'
          '"online_seconds":7200,"avg_rank":2.0,"rank_samples":4,'
          '"pool":3.0,"ratings":1,"rating_avg":5.0}],'
          '"acceptance":{"current":0.9123,"week":0.75,"offers":4,'
          '"accepted":3,"declined":1,"expired":0},'
          '"online":{"week_seconds":7200,"today_seconds":3600,'
          '"session_seconds":600},'
          '"rating":{"value":4.87,"count":305,"week_count":1,'
          '"week_avg":5.0},'
          '"rank":{"avg":2.0,"best":1,"worst":3,"pool":3.0,'
          '"samples":4}}', 200);
    }));

    final p = await api.performance();

    expect(seen.single.method, 'GET');
    expect(seen.single.url.path, '/functions/v1/v1/partner/performance');
    expect(p.weekStart, '2026-10-19');
    expect(p.timezone, 'America/Porto_Velho');
    expect(p.days.single.weekday, 'seg');
    expect(p.days.single.acceptanceRate, 0.75);
    expect(p.acceptanceWeek, 0.75);
    expect(p.acceptanceCurrent, 0.9123);
    expect(p.offers, 4);
    expect(p.missedOffers, 1);
    expect(p.weekOnlineSeconds, 7200);
    expect(p.todayOnlineSeconds, 3600);
    expect(p.ratingValue, 4.87);
    expect(p.ratingCount, 305);
    expect(p.weekRatingAvg, 5.0);
    expect(p.rankAvg, 2.0);
    expect(p.rankBest, 1);
    expect(p.rankWorst, 3);
    expect(p.rankPool, 3.0);
    expect(p.rankSamples, 4);
    expect(p.hasWeekData, isTrue);
  });

  test('semana sem eventos vem com nulos (a tela diz "sem dados", não 0%)',
      () async {
    final api = clientWith(MockClient((req) async => resp('{"date":"2026-10-25",'
        '"week_start":"2026-10-19","timezone":"America/Porto_Velho",'
        '"days":[],"acceptance":{"current":null,"week":null,"offers":0,'
        '"accepted":0,"declined":0,"expired":0},'
        '"online":{"week_seconds":0,"today_seconds":0,"session_seconds":0},'
        '"rating":{"value":null,"count":0,"week_count":0,'
        '"week_avg":null},'
        '"rank":{"avg":null,"best":null,"worst":null,"pool":null,'
        '"samples":0}}', 200)));

    final p = await api.performance();

    expect(p.hasWeekData, isFalse);
    expect(p.acceptanceWeek, isNull);
    expect(p.acceptanceCurrent, isNull);
    expect(p.rankAvg, isNull);
    expect(p.rankSamples, 0);
    expect(p.ratingValue, isNull);
    expect(p.days, isEmpty);
  });

  test('Me parseia partner.kyc_status + modo ortogonal (§3.3)', () async {
    final api = clientWith(MockClient((req) async => resp(
        '{"user_id":"u1","role":"PARTNER","partner":{'
        '"kyc_status":"APPROVED","monetization_mode":"COMISSAO",'
        '"wallet_balance":10.0,"debt_cents":0}}', 200)));

    final me = await api.me();

    expect(me.role, 'PARTNER');
    expect(me.partner!.kycStatus, 'APPROVED');
    expect(me.partner!.canGoOnline, isTrue);
    expect(me.partner!.monetizationMode, 'COMISSAO');
  });
}
