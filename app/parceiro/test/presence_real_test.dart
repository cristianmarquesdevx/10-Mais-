import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart' show LocationAccuracy;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parceiro/src/api/client.dart';
import 'package:parceiro/src/api/presence_api.dart';
import 'package:parceiro/src/location/location_service.dart';
import 'package:parceiro/src/services/presence_keep_alive.dart';
import 'package:parceiro/src/state/partner_controller.dart';

/// A presença do parceiro é o que o despacho do passageiro lê. Com o radar
/// real (Edge Function `radar`, Postgres) ligado, o online/offline/pausa têm
/// de ir para lá — e **não** depender da API de demonstração, que não existe
/// em produção.
///
/// Estes testes travam esse caminho: com o radar, a presença vai ao radar;
/// sem o radar (modo demo), ela vai para a API de demo; e uma recusa do
/// servidor nunca vira "online" na tela.
void main() {
  // O controller é um observer do ciclo de vida: precisa do binding.
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<http.Request> demoSeen;
  late List<http.Request> radarSeen;
  int radarStatus = 200;
  String radarCode = '';

  http.Response demoAnswer(http.Request req) {
    demoSeen.add(req);
    if (req.url.path.endsWith('/offers/mine')) {
      return http.Response(jsonEncode({'offers': []}), 200);
    }
    if (req.url.path.endsWith('/me')) {
      return http.Response(
        jsonEncode({
          'user_id': '22222222-2222-4222-8222-222222222222',
          'role': 'PARTNER',
          'partner': {
            'kyc_status': 'APPROVED',
            'monetization_mode': 'COMISSAO',
            'wallet_balance': 96.65,
            'debt_cents': 0,
          },
        }),
        200,
      );
    }
    return http.Response('{}', 200);
  }

  http.Response radarAnswer(http.Request req) {
    radarSeen.add(req);
    if (radarStatus != 200) {
      return http.Response(
        jsonEncode({'title': 'Recusado', 'status': radarStatus, 'code': radarCode}),
        radarStatus,
      );
    }
    return http.Response(jsonEncode({'status': 'ONLINE_DISPONIVEL'}), 200);
  }

  ApiClient demoApi() => ApiClient(
        baseUrl: 'http://demo.local/functions/v1/v1',
        accessToken: () => 'jwt-demo',
        inner: MockClient((req) async => demoAnswer(req)),
      );

  PresenceApi radarApi() => PresenceApi(
        baseUrl: 'http://real.local/functions/v1/radar',
        token: 'jwt-da-sessao',
        client: MockClient((req) async => radarAnswer(req)),
      );

  setUp(() {
    demoSeen = [];
    radarSeen = [];
    radarStatus = 200;
    radarCode = '';
  });

  test('com o radar real, ficar online publica no Postgres (e não na demo)',
      () async {
    final controller = PartnerController(
      demoApi(),
      presence: radarApi(),
      location: const _FakeLocation(),
    );

    await controller.goOnline();

    expect(controller.status, PartnerStatus.online);
    expect(controller.lastErrorCode, isNull);
    expect(radarSeen, hasLength(1));
    expect(radarSeen.single.url.path, '/functions/v1/radar/presence');
    expect(radarSeen.single.headers['authorization'], 'Bearer jwt-da-sessao');
    final body = jsonDecode(radarSeen.single.body) as Map<String, dynamic>;
    expect(body['status'], 'ONLINE_DISPONIVEL');
    expect(body['lat'], closeTo(-8.7607, 1e-6));
    // A rota de demonstração não foi chamada: em produção ela não existe.
    expect(
      demoSeen.where((r) => r.url.path.endsWith('/partner/online')),
      isEmpty,
    );
    controller.dispose();
  });

  test('o servidor recusa (KYC pendente): o parceiro NÃO fica online',
      () async {
    radarStatus = 403;
    radarCode = 'kyc_not_approved';
    final controller = PartnerController(
      demoApi(),
      presence: radarApi(),
      location: const _FakeLocation(),
    );

    await controller.goOnline();

    expect(controller.status, PartnerStatus.offline);
    expect(controller.lastErrorCode, 'kyc_not_approved');
    controller.dispose();
  });

  test('falha genérica do radar vira "presence_error" (não crasha a tela)',
      () async {
    radarStatus = 500;
    radarCode = 'radar_error';
    final controller = PartnerController(
      demoApi(),
      presence: radarApi(),
      location: const _FakeLocation(),
    );

    await controller.goOnline();

    expect(controller.status, PartnerStatus.offline);
    expect(controller.lastErrorCode, 'presence_error');
    controller.dispose();
  });

  test('ficar offline publica OFFLINE no radar (some do despacho)', () async {
    final controller = PartnerController(
      demoApi(),
      presence: radarApi(),
      location: const _FakeLocation(),
    );

    await controller.goOnline();
    radarSeen.clear();
    await controller.goOffline();

    expect(controller.status, PartnerStatus.offline);
    expect(radarSeen, hasLength(1));
    final body = jsonDecode(radarSeen.single.body) as Map<String, dynamic>;
    expect(body['status'], 'OFFLINE');
    controller.dispose();
  });

  test('sem radar configurado (modo demo) o online vai para a API de demo',
      () async {
    final controller = PartnerController(
      demoApi(),
      location: const _FakeLocation(),
    );

    await controller.goOnline();

    expect(controller.status, PartnerStatus.online);
    expect(
      demoSeen.where((r) => r.url.path.endsWith('/partner/online')),
      hasLength(1),
    );
    expect(radarSeen, isEmpty);
    controller.dispose();
  });

  test('a pausa publica PAUSA no radar e volta a ONLINE ao encerrar',
      () async {
    final controller = PartnerController(
      demoApi(),
      presence: radarApi(),
      location: const _FakeLocation(),
    );
    await controller.loadMe(); // perfil: KYC aprovado (senão a pausa é negada)

    await controller.goOnline();
    radarSeen.clear();
    await controller.startBreak();

    expect(controller.status, PartnerStatus.paused);
    expect(radarSeen, hasLength(1));
    expect(
      (jsonDecode(radarSeen.single.body) as Map<String, dynamic>)['status'],
      'PAUSA',
    );

    radarSeen.clear();
    await controller.endBreak();

    expect(controller.status, PartnerStatus.online);
    expect(
      (jsonDecode(radarSeen.single.body) as Map<String, dynamic>)['status'],
      'ONLINE_DISPONIVEL',
    );
    controller.dispose();
  });

  test('o heartbeat continua batendo depois de online (presença fica fresca)',
      () async {
    // O bug do "parceiro some do radar": o servidor só mostra quem deu sinal
    // de vida nos últimos 90 s. Se o heartbeat não bate, o passageiro vê
    // "nenhum motorista" mesmo com o parceiro online.
    final controller = PartnerController(
      demoApi(),
      presence: radarApi(),
      location: const _FakeLocation(),
      heartbeatInterval: const Duration(milliseconds: 40),
    );

    await controller.goOnline();
    expect(radarSeen, hasLength(1)); // a publicação do ONLINE

    await Future<void>.delayed(const Duration(milliseconds: 220));
    expect(
      radarSeen.length,
      greaterThanOrEqualTo(3),
      reason: 'o heartbeat tem de continuar publicando a presença',
    );
    controller.dispose();
  });

  test('o heartbeat bate mesmo se a leitura de ofertas falhar', () async {
    // A leitura de ofertas é acessória; se ela derruba, a presença (que é o
    // que importa para o despacho) tem de continuar.
    final api = ApiClient(
      baseUrl: 'http://demo.local/functions/v1/v1',
      accessToken: () => 'jwt-demo',
      inner: MockClient((req) async {
        demoSeen.add(req);
        return http.Response('{"code":"boom"}', 500);
      }),
    );
    final controller = PartnerController(
      api,
      presence: radarApi(),
      location: const _FakeLocation(),
      heartbeatInterval: const Duration(milliseconds: 40),
    );

    await controller.goOnline();
    expect(controller.status, PartnerStatus.online);

    await Future<void>.delayed(const Duration(milliseconds: 220));
    expect(radarSeen.length, greaterThanOrEqualTo(3));
    controller.dispose();
  });

  test('voltar ao primeiro plano republica a presença (pode ter expirado)',
      () async {
    final controller = PartnerController(
      demoApi(),
      presence: radarApi(),
      location: const _FakeLocation(),
    );

    await controller.goOnline();
    radarSeen.clear();

    // O app voltou do segundo plano: a presença pode ter vencido lá atrás.
    controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await Future<void>.delayed(const Duration(milliseconds: 120));

    expect(radarSeen, isNotEmpty);
    expect(
      (jsonDecode(radarSeen.first.body) as Map<String, dynamic>)['status'],
      'ONLINE_DISPONIVEL',
    );
    controller.dispose();
  });

  test('ficar online segura o app vivo; ficar offline solta', () async {
    final keepAlive = _FakeKeepAlive();
    final controller = PartnerController(
      demoApi(),
      presence: radarApi(),
      location: const _FakeLocation(),
      keepAlive: keepAlive,
    );

    await controller.goOnline();
    expect(keepAlive.starts, 1);

    await controller.goOffline();
    expect(keepAlive.stops, 1);
    controller.dispose();
  });
}

/// Serviço de presença (primeiro plano) de mentira: só conta as chamadas.
class _FakeKeepAlive extends PresenceKeepAlive {
  int starts = 0;
  int stops = 0;

  @override
  Future<bool> start() async {
    starts++;
    return true;
  }

  @override
  Future<void> stop() async {
    stops++;
  }
}

/// GPS de mentira: a posição do parceiro é fixa (sem plugin no host de teste).
class _FakeLocation extends LocationService {
  const _FakeLocation();

  @override
  Future<LocationFix?> tryCurrent({
    Duration timeout = const Duration(seconds: 8),
    LocationAccuracy accuracy = LocationAccuracy.high,
  }) async =>
      LocationFix(
        lat: -8.7607,
        lon: -63.9039,
        accuracyM: 12,
        at: DateTime.now(),
      );
}
