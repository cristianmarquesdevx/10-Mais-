import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:passageiro/src/api/client.dart';
import 'package:passageiro/src/state/ride_controller.dart';

/// Regressão: o poll de fallback morria no primeiro tick (o Timer.periodic se
/// cancelava dentro do próprio callback), então a tela ficava em "Procurando
/// parceiro" mesmo com a corrida ACEITA/FINALIZADA no servidor.
RideController controllerFor(
  MockClient mock, {
  Duration interval = const Duration(milliseconds: 10),
}) =>
    RideController(
      ApiClient(
        baseUrl: 'http://test.local',
        accessToken: () => 'jwt-test',
        inner: mock,
      ),
      pollInterval: interval,
    );

Map<String, dynamic> rideJson(String status) => {
      'ride_id': 'r1',
      'status': status,
      'pricing_mode': 'PASSE',
      'fare_total': 27.4,
      'payment_status': 'NOT_DUE',
      'created_at': '2026-10-20T11:00:00Z',
      'origin': {'lat': -8.7607, 'lon': -63.9039},
      'destination': {'lat': -8.7098, 'lon': -63.9009},
    };

http.Response json(Object body, [int code = 200]) => http.Response(
      jsonEncode(body),
      code,
      headers: {'content-type': 'application/json'},
    );

Future<void> waitFor(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condição não atingida a tempo');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  // O controller observa o ciclo de vida do app (retoma o poll ao voltar do
  // background), então o binding precisa existir também nos testes puros.
  TestWidgetsFlutterBinding.ensureInitialized();

  test('poll vê a corrida passar de BUSCANDO para ACEITA', () async {
    var status = 'BUSCANDO';
    var polls = 0;
    final ride = controllerFor(MockClient((req) async {
      if (req.method == 'POST') return json({}, 201);
      if (req.url.queryParameters['active'] == '1') {
        polls++;
        return json({
          'rides': [rideJson(status)]
        });
      }
      return json(rideJson(status));
    }));
    addTearDown(ride.dispose);

    await ride.requestRide(
      origin: const GeoPoint(-8.7607, -63.9039),
      destination: const GeoPoint(-8.7098, -63.9009),
      mode: PricingMode.tariff,
    );
    expect(ride.ride!.status, RideStatus.buscando);

    // O servidor aceita: sem poll a UI nunca sairia da fila.
    status = 'ACEITA';
    await waitFor(() => ride.ride?.status == RideStatus.aceita);
    expect(polls, greaterThan(1), reason: 'poll deve rodar mais de uma vez');
  });

  test('poll encerra quando a corrida fica terminal (sem timer pendente)',
      () async {
    var status = 'BUSCANDO';
    var calls = 0;
    final ride = controllerFor(MockClient((req) async {
      calls++;
      if (req.method == 'POST') return json({}, 201);
      if (req.url.queryParameters['active'] == '1') {
        // Corrida já saiu do conjunto "ativa" → só o GET por id traz o estado.
        return json({
          'rides': status == 'BUSCANDO' ? [rideJson(status)] : const []
        });
      }
      return json(rideJson(status));
    }));
    addTearDown(ride.dispose);

    await ride.requestRide(
      origin: const GeoPoint(-8.7607, -63.9039),
      destination: const GeoPoint(-8.7098, -63.9009),
      mode: PricingMode.tariff,
    );

    // Deixa o poll rodar alguns ciclos em BUSCANDO antes de fechar a corrida:
    // é nesse encadeamento de timers que a versão antiga se perdia.
    await Future<void>.delayed(const Duration(milliseconds: 60));
    status = 'FINALIZADA';
    await waitFor(() => ride.ride?.status == RideStatus.finalizada);

    // Corrida fechada: o poll tem de parar (antes ele seguia batendo no
    // servidor para sempre e a tela não reagia ao estado terminal).
    await Future<void>.delayed(const Duration(milliseconds: 60));
    final depois = calls;
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(calls, depois, reason: 'poll continuou após o estado terminal');
  });
}
