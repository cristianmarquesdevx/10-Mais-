import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:passageiro/src/assets/app_assets.dart';

/// M1 — guarda-corpo contra "Asset not found".
///
/// `rootBundle.load` falha quando o arquivo não foi empacotado — inclusive
/// quando a pasta existe no disco mas não está declarada no `pubspec.yaml`
/// (o Flutter não é recursivo).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('todo asset de AppAssets existe no bundle', () async {
    for (final path in AppAssets.all) {
      final data = await rootBundle.load(path);
      expect(
        data.lengthInBytes,
        greaterThan(0),
        reason: 'Asset vazio: $path',
      );
    }
  });
}
