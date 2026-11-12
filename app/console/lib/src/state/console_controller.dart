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

  /// O número da ÚLTIMA leitura que deu CERTO e escreveu a fila.
  ///
  /// O polling (30 s) e o "puxar para baixo" podem disparar leituras
  /// sobrepostas: a resposta mais ANTIGA pode chegar depois da mais nova e
  /// sobrescrever a fila com um retrato velho. Cada leitura recebe um
  /// número; só a última que **deu certo** tem o direito de escrever o
  /// estado.
  ///
  /// A comparação é com o **último sucesso**, não com a última tentativa:
  /// se a leitura NOVA falhou e a VELHA deu certo, a fila antiga (que é o
  /// último retrato verdadeiro que temos) continua na tela — e o erro
  /// aparece junto. Descartar a leitura que deu certo seria trocar uma
  /// informação boa por uma tela vazia com erro.
  int _lastOkAttempt = 0;

  /// O número da ÚLTIMA leitura que deu ERRO.
  ///
  /// O erro é o estado mais CONSERVADOR: se a leitura mais recente
  /// falhou, a fila que está na tela pode estar velha, e a pessoa precisa
  /// saber disso. Por isso um sucesso só apaga o erro se for **mais novo**
  /// que ele.
  int _lastErrAttempt = 0;

  /// O número da leitura EM CURSO (a mais recente disparada).
  int _attempt = 0;

  /// A leitura que DONA do spinner.
  ///
  /// O spinner pertence à leitura mais recente que a pessoa iniciou (não
  /// ao polling silencioso). Só o dono desliga o spinner: uma leitura
  /// ANTIGA que responde não pode apagar o "carregando" de uma leitura
  /// NOVA ainda em curso (seria a tela piscando).
  ///
  /// E o spinner nunca fica preso: o dono sempre termina — a API tem
  /// prazo (`ConsoleApi.requestTimeout`), e o prazo vira o erro `offline`.
  int _loadingOwner = 0;

  /// Carrega (ou recarrega) a fila.
  ///
  /// [silent] = true não troca a tela por um spinner: é o recarregamento de
  /// "puxar para baixo" e o polling — onde a lista continua visível.
  Future<void> load({bool silent = false}) async {
    final attempt = ++_attempt;
    if (!silent) {
      _loadingOwner = attempt;
      loading = true;
      notifyListeners();
    }
    try {
      final data = await api.queue();
      // Uma leitura que deu certo e é mais NOVA que o último sucesso
      // escreve a fila. Uma leitura velha (ou uma que não deu certo) não.
      if (attempt >= _lastOkAttempt) {
        _lastOkAttempt = attempt;
        queue = data;
        loadedAt = DateTime.now();
      }
      // O erro some só se ESTE sucesso for mais novo que o último erro.
      if (attempt >= _lastErrAttempt) {
        _lastErrAttempt = attempt;
        error = null;
      }
    } on ApiProblem catch (p) {
      // O erro é do SERVIDOR agora: mesmo que uma leitura velha tenha dado
      // certo depois, a fila exibida pode estar velha — e a tela precisa
      // dizer isso. O erro NÃO é descartado por haver leituras antigas.
      if (attempt >= _lastErrAttempt) {
        _lastErrAttempt = attempt;
        error = p.code;
        errorCount++;
      }
    } catch (_) {
      if (attempt >= _lastErrAttempt) {
        _lastErrAttempt = attempt;
        error = 'offline';
        errorCount++;
      }
    } finally {
      // Só o DONO do spinner desliga — e ele sempre chega aqui (a API
      // tem prazo: um servidor mudo vira `offline`, não um spinner eterno).
      if (_loadingOwner == attempt) {
        _loadingOwner = 0;
        loading = false;
      }
      notifyListeners();
    }
  }
}
