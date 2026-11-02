import 'package:flutter/material.dart';

import 'colors.dart';

/// Escala tipográfica. A cor NUNCA vem daqui: use `bodyStyle(context)` &
/// cia., ou `AppType.x.copyWith(color: tokensOf(context).ink)`.
///
/// Não há fonte própria ainda (fontFamily nulo = Roboto/SF do sistema). Quando
/// a fonte da marca entrar, este é o único lugar a mudar.
abstract final class AppType {
  static const body = TextStyle(fontSize: 16, height: 1.4);
  static const onDark = TextStyle(fontSize: 16, height: 1.4);
  static const titleOnDark =
      TextStyle(fontSize: 25, fontWeight: FontWeight.w700);
  static const label = TextStyle(fontSize: 14, height: 1.3);
  static const caption = TextStyle(fontSize: 12, height: 1.3);
  static const title = TextStyle(fontSize: 20, fontWeight: FontWeight.w600);
  static const display = TextStyle(
    fontSize: 31,
    fontWeight: FontWeight.w700,
    fontFeatures: [FontFeature.tabularFigures()],
  );
  static const money = TextStyle(
    fontSize: 25,
    fontWeight: FontWeight.w700,
    fontFeatures: [FontFeature.tabularFigures()],
  );
  static const countdown = TextStyle(
    fontSize: 20,
    fontWeight: FontWeight.w700,
    fontFeatures: [FontFeature.tabularFigures()],
  );
}

TextStyle bodyStyle(BuildContext context) {
  final t = tokensOf(context);
  return AppType.body.copyWith(color: t.ink);
}

TextStyle titleStyle(BuildContext context) {
  final t = tokensOf(context);
  return AppType.title.copyWith(color: t.ink);
}

TextStyle labelStyle(BuildContext context) {
  final t = tokensOf(context);
  return AppType.label.copyWith(color: t.muted);
}
