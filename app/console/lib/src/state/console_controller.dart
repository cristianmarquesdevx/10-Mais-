import 'package:flutter/foundation.dart';

import '../api/console_api.dart';

/// Estado da fila do KYC na tela da operação.
class ConsoleController extends ChangeNotifier {
  ConsoleController(this.api);

  final ConsoleApi api;

  /// Os casos na fila, na ordem do servidor (prazo, entrada, id).
  List<QueueCase> queue = const [];

  bool loading = false;

  /// O código do último erro (`offline`, `forbidden`, …). A tela decide por
  /// ele, nunca pelo texto.
  String? error;

  /// Quantas vezes a leitura da fila falhou.
  ///
  /// A tela usa este contador para avisar UMA vez por falha: sem ele, o
  /// polling repetiria o mesmo aviso a cada 30 s.
  int errorCount = 0;

  /// Quando a fila foi lida pela última vez.
  DateTime? loadedAt;

  /// Carrega (ou recarrega) a fila.
  ///
  /// [silent] = true não troca a tela por um spinner: é o recarregamento de
  /// "puxar para baixo" e o polling — onde a lista continua visível.
  Future<void> load({bool silent = false}) async {
    if (!silent) {
      loading = true;
      notifyListeners();
    }
    error = null;
    try {
      queue = await api.queue();
      loadedAt = DateTime.now();
      error = null;
    } on ApiProblem catch (p) {
      error = p.code;
      errorCount++;
    } catch (_) {
      error = 'offline';
      errorCount++;
    } finally {
      loading = false;
      notifyListeners();
    }
  }
}
