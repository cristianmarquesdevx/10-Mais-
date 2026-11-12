import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parceiro/main.dart';
import 'package:parceiro/src/api/client.dart';
import 'package:parceiro/src/media/document_quality.dart';
import 'package:parceiro/src/media/still_capture.dart';
import 'package:parceiro/src/screens/document_capture_screen.dart';
import 'package:parceiro/src/screens/onboarding_screen.dart';
import 'package:parceiro/src/state/partner_controller.dart';
import 'package:parceiro/src/theme/theme.dart';

/// O FLUXO do F9 no app do parceiro: capturar → subir o arquivo → abrir o
/// caso → registrar o documento.
///
/// A ordem importa e é o que este teste segura:
///   1. o ARQUIVO sobe no bucket antes de o caso existir (o id do caso só
///      existe depois do passo 2);
///   2. o caso é aberto;
///   3. cada documento é registrado com o path do arquivo.
///
/// Assim a operação NUNCA vê um caso sem o documento que ele diz ter.
/// Câmera de mentira: devolve a foto sintética. Ela existe para o TESTE —
/// no aparelho, a captura é a nativa (plugin `camera`).
class _FakeCapture implements StillCapture {
  _FakeCapture(this.bytes);

  final Uint8List bytes;
  bool aberta = false;
  int capturas = 0;

  @override
  bool get supported => true;

  @override
  Future<void> open({CameraLens lens = CameraLens.rear}) async {
    aberta = true;
  }

  @override
  Widget? preview() =>
      aberta ? const ColoredBox(color: Color(0xFF102020)) : null;

  @override
  Future<StillShot?> capture() async {
    capturas++;
    return StillShot(bytes: bytes);
  }

  @override
  Future<void> switchLens() async {}

  @override
  void close() => aberta = false;
}

/// Pipeline de mentira: mede e mostra sem decodificar imagem.
///
/// A implementação real ([PhotoPipeline.real]) decodifica os bytes, e a
/// decodificação não completa no ambiente de teste do Flutter. A MEDIDA real
/// tem teste próprio (test/document_quality_test.dart).
PhotoPipeline _pipelineDeMentira({bool nitida = true}) => PhotoPipeline(
      measure: (bytes) async => nitida
          ? const DocumentQuality(blurScore: 900, glareRatio: 0.01)
          : const DocumentQuality(blurScore: 10, glareRatio: 0.01),
      preview: (_, __) => const ColoredBox(color: Color(0xFFEEEEEE)),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const casoId = '11111111-1111-4111-8111-111111111111';
  const uid = '77777777-7777-4777-8777-777777777777';

  /// Uma foto sintética (papel com texto) — só para ter bytes de verdade.
  Uint8List fotoNitida() {
    // Um JPEG mínimo basta: quem mede é o pipeline, e o que sobe para o
    // Storage são os bytes.
    return Uint8List.fromList(List<int>.generate(512, (i) => i % 256));
  }

  http.Response resp(String body, int statusCode) => http.Response(
        body,
        statusCode,
        headers: const {'content-type': 'application/json; charset=utf-8'},
      );

  testWidgets('capturar, subir o arquivo e registrar o documento',
      (tester) async {
    final bytes = fotoNitida();
    final camera = _FakeCapture(bytes);
    final pedidos = <http.Request>[];

    final api = ApiClient(
      baseUrl: 'http://demo.local/functions/v1/v1',
      kycBase: 'http://real.local/functions/v1/kyc',
      storageBase: 'http://real.local',
      userId: () => uid,
      accessToken: () => 'jwt-do-parceiro',
      inner: MockClient((req) async {
        pedidos.add(req);
        if (req.method == 'PUT') {
          return resp(jsonEncode({'Key': 'kyc-docs/x'}), 200);
        }
        if (req.url.path.endsWith('/cases')) {
          return resp(
              jsonEncode({'case_id': casoId, 'status': 'IN_REVIEW'}), 201);
        }
        return resp(
            jsonEncode({'case_id': casoId, 'status': 'IN_REVIEW'}), 201);
      }),
    );
    final partner = PartnerController(api);
    addTearDown(partner.dispose);

    await tester.pumpWidget(AppScope(
      partner: partner,
      api: api,
      child: MaterialApp(
        theme: buildAppTheme(),
        home: OnboardingScreen(
          capture: camera,
          pipeline: _pipelineDeMentira(),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // 1) Tira a foto do primeiro documento.
    await tester.tap(find.byKey(const ValueKey('capture-CNH')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('capture-take')));
    await tester.pumpAndSettle();
    // A tela mostra a MEDIDA antes de a pessoa confirmar: uma foto boa não
    // gera aviso nenhum (borrão/reflexo).
    expect(find.textContaining('reflexo'), findsNothing);
    expect(find.textContaining('borrada'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('capture-use')));
    await tester.pumpAndSettle();
    // E o documento aparece como tirado.
    expect(find.textContaining('nítida'), findsOneWidget);

    // 2) Tira a foto do segundo documento.
    await tester.tap(find.byKey(const ValueKey('capture-SELFIE')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('capture-take')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('capture-use')));
    await tester.pumpAndSettle();

    // 3) Envia a documentação.
    await tester.tap(find.text('Enviar documentação'));
    await tester.pumpAndSettle();

    // A ordem é o contrato do fluxo: arquivos, caso, documentos.
    final metodos = pedidos.map((r) => '${r.method} ${r.url.path}').toList();
    expect(metodos[0], startsWith('PUT /storage/v1/object/kyc-docs/kyc/$uid/'));
    expect(metodos[1], startsWith('PUT /storage/v1/object/kyc-docs/kyc/$uid/'));
    expect(metodos[2], 'POST /functions/v1/kyc/cases');
    expect(metodos[3], 'POST /functions/v1/kyc/cases/$casoId/documents');
    expect(metodos[4], 'POST /functions/v1/kyc/cases/$casoId/documents');

    // O arquivo vai na pasta do DONO, com o nome do documento.
    expect(pedidos[0].url.path, contains('/kyc/$uid/pending/CNH_'));
    expect(pedidos[1].url.path, contains('/kyc/$uid/pending/SELFIE_'));
    expect(pedidos[0].headers['authorization'], 'Bearer jwt-do-parceiro');

    // Cada registro leva o path do arquivo e a medida da qualidade.
    final corpo = jsonDecode(pedidos[3].body) as Map<String, dynamic>;
    expect(corpo['doc_type'], 'CNH');
    // O `storage_path` é o NOME do objeto (sem barra inicial), e é ele que o
    // servidor confere contra o bucket.
    expect(corpo['storage_path'], contains('kyc/$uid/pending/CNH_'));
    final flags = corpo['quality_flags'] as Map<String, dynamic>;
    expect(flags['blur'], isFalse);
    expect(flags.containsKey('blur_score'), isTrue);

    // O caso entrou na fila: a tela mostra a faixa de análise.
    expect(find.textContaining('Em análise — posição na fila'), findsOneWidget);
  });

  testWidgets('sem foto a documentação vai como PENDENTE (registro honesto)',
      (tester) async {
    final pedidos = <http.Request>[];
    final bytes = fotoNitida();
    final api = ApiClient(
      baseUrl: 'http://demo.local/functions/v1/v1',
      kycBase: 'http://real.local/functions/v1/kyc',
      storageBase: 'http://real.local',
      userId: () => uid,
      accessToken: () => 'jwt-do-parceiro',
      inner: MockClient((req) async {
        pedidos.add(req);
        return resp(
            jsonEncode({'case_id': casoId, 'status': 'IN_REVIEW'}), 201);
      }),
    );
    final partner = PartnerController(api);
    addTearDown(partner.dispose);

    await tester.pumpWidget(AppScope(
      partner: partner,
      api: api,
      child: MaterialApp(
        theme: buildAppTheme(),
        home: OnboardingScreen(
          capture: _FakeCapture(bytes),
          pipeline: _pipelineDeMentira(),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Enviar documentação'));
    await tester.pumpAndSettle();

    // Sem foto, não há upload — e não há registro de documento: a operação
    // vê a lista real (sem "PENDENTE" ruidoso).
    expect(pedidos.where((r) => r.method == 'PUT'), isEmpty);
    expect(pedidos.where((r) => r.url.path.endsWith('/documents')), isEmpty);
    expect(pedidos.single.method, 'POST');
  });
}
