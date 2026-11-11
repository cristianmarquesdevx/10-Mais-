import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parceiro/main.dart';
import 'package:parceiro/src/api/client.dart';
import 'package:parceiro/src/screens/onboarding_screen.dart';
import 'package:parceiro/src/screens/screens.dart';
import 'package:parceiro/src/state/partner_controller.dart';
import 'package:parceiro/src/theme/theme.dart';

/// Onboarding/KYC contra o contrato do backend real: a tela mostra a faixa
/// que o servidor devolve (IN_REVIEW com fila e prazo, APPROVED, REJECTED) e
/// o botão "Reenviar documento" reenvia o documento — não abre um caso novo.
http.Response resp(String body, int statusCode) => http.Response(
      body,
      statusCode,
      headers: const {'content-type': 'application/json; charset=utf-8'},
    );

const casoId = 'cafebabe-0000-0000-0000-000000000000';

({Widget widget, PartnerController partner}) buildOnboarding({
  required MockClient mock,
}) {
  final api = ApiClient(
    baseUrl: 'http://test.local/functions/v1/v1',
    accessToken: () => 'jwt-test',
    inner: mock,
  );
  final partner = PartnerController(api);
  return (
    widget: AppScope(
      partner: partner,
      api: api,
      child: MaterialApp(
        theme: buildAppTheme(),
        home: const OnboardingScreen(),
      ),
    ),
    partner: partner,
  );
}

void main() {
  testWidgets('caso em análise mostra fila e prazo, e trava o envio',
      (tester) async {
    final built = buildOnboarding(mock: MockClient((req) async => resp(
          '{"case_id":"$casoId","status":"IN_REVIEW","position":7,'
          '"sla":"2026-11-12T20:00:00Z"}',
          201,
        )));
    addTearDown(built.partner.dispose);

    await tester.pumpWidget(built.widget);
    await tester.tap(find.text('Enviar documentação'));
    await tester.pumpAndSettle();

    expect(find.textContaining('posição na fila: 7'), findsOneWidget);
    expect(find.textContaining('SLA até'), findsOneWidget);
    // Em análise o botão não deixa o parceiro abrir um caso novo.
    expect(find.text('Em análise'), findsOneWidget);
    final botao = tester.widget<FilledButton>(
      find.ancestor(
        of: find.text('Em análise'),
        matching: find.byType(FilledButton),
      ),
    );
    expect(botao.onPressed, isNull);
  });

  testWidgets('aprovado pela operação é reconhecido como aprovado',
      (tester) async {
    final built = buildOnboarding(mock: MockClient((req) async => resp(
          '{"case_id":"$casoId","status":"APPROVED"}',
          201,
        )));
    addTearDown(built.partner.dispose);

    await tester.pumpWidget(built.widget);
    await tester.tap(find.text('Enviar documentação'));
    await tester.pumpAndSettle();

    expect(find.text('Aprovado pela operação.'), findsOneWidget);
  });

  testWidgets('caso recusado: o botão reenvia o documento do caso',
      (tester) async {
    final seen = <http.Request>[];
    var n = 0;
    final built = buildOnboarding(mock: MockClient((req) async {
      seen.add(req);
      n++;
      if (n == 1) {
        return resp('{"case_id":"$casoId","status":"REJECTED"}', 201);
      }
      return resp(
          '{"case_id":"$casoId","status":"RESUBMIT","position":2,'
          '"sla":"2026-11-13T20:00:00Z"}',
          201);
    }));
    addTearDown(built.partner.dispose);

    await tester.pumpWidget(built.widget);
    await tester.tap(find.text('Enviar documentação'));
    await tester.pumpAndSettle();

    expect(find.textContaining('rejeitada'), findsOneWidget);
    expect(find.text('Reenviar documento'), findsOneWidget);

    await tester.tap(find.text('Reenviar documento'));
    await tester.pumpAndSettle();

    // O reenvio vai para /cases/{id}/documents — e não para /cases.
    expect(seen.last.method, 'POST');
    expect(seen.last.url.path, '/functions/v1/v1/kyc/cases/$casoId/documents');
    expect(seen.last.headers['Idempotency-Key'], isNotNull);
    expect(find.textContaining('posição na fila: 2'), findsOneWidget);
  });

  testWidgets('o KYC vai para a base do KYC quando ela está configurada',
      (tester) async {
    final seen = <http.Request>[];
    final api = ApiClient(
      baseUrl: 'http://demo.local/functions/v1/v1',
      kycBase: 'http://real.local/functions/v1/kyc',
      accessToken: () => 'jwt-test',
      inner: MockClient((req) async {
        seen.add(req);
        return resp('{"case_id":"$casoId","status":"IN_REVIEW"}', 201);
      }),
    );
    final partner = PartnerController(api);
    addTearDown(partner.dispose);

    await tester.pumpWidget(AppScope(
      partner: partner,
      api: api,
      child: MaterialApp(
        theme: buildAppTheme(),
        home: const OnboardingScreen(),
      ),
    ));
    await tester.tap(find.text('Enviar documentação'));
    await tester.pumpAndSettle();

    expect(seen.single.url.host, 'real.local');
    expect(seen.single.url.path, '/functions/v1/kyc/cases');
    // A rota do contrato (`/kyc/cases`) não repete o nome da função: a URL
    // real é a canônica do Supabase.
    expect(seen.single.method, 'POST');
    expect(seen.single.bodyBytes, isEmpty);
  });
}
