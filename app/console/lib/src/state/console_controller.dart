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

  /// O número da leitura EM CURSO.
  ///
  /// O polling (30 s) e o "puxar para baixo" podem disparar leituras
  /// sobrepostas: a resposta mais ANTIGA pode chegar depois da mais nova e
  /// sobrescrever a fila com um retrato velho. Cada leitura recebe um
  /// número; só a última tem o direito de escrever o estado.
  int _attempt = 0;

  /// Carrega (ou recarrega) a fila.
  ///
  /// [silent] = true não troca a tela por um spinner: é o recarregamento de
  /// "puxar para baixo" e o polling — onde a lista continua visível.
  Future<void> load({bool silent = false}) async {
    final attempt = ++_attempt;
    if (!silent) {
      loading = true;
      notifyListeners();
    }
    error = null;
    try {
      final data = await api.queue();
      // Uma leitura mais recente já respondeu: esta é velha, não escreve.
      if (attempt != _attempt) return;
      queue = data;
      loadedAt = DateTime.now();
      error = null;
    } on ApiProblem catch (p) {
      if (attempt != _attempt) return;
      error = p.code;
      errorCount++;
    } catch (_) {
      if (attempt != _attempt) return;
      error = 'offline';
      errorCount++;
    }
    if (attempt == _attempt) {
      loading = false;
      notifyListeners();
    }
  }
}
