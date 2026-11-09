import 'dart:io' show Platform;

/// Backend vetorial disponível nas plataformas móveis.
bool get supportsVectorMap => Platform.isAndroid || Platform.isIOS;
