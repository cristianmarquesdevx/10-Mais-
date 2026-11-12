/// Rótulo do prazo (SLA) de um caso do KYC.
///
/// O SLA é uma PROMESSA de atendimento, não um temporizador: o prazo cai na
/// primeira janela em que há gente revisando (ver `fn_kyc_sla_due`). A tela
/// da operação precisa dizer, em uma linha, se o caso está no prazo ou
/// atrasado — e por quanto.
library;

/// "vence em 2 h 10 min" · "atrasado há 1 h" · "sem prazo".
String slaLabel(DateTime? due, DateTime now) {
  if (due == null) return 'sem prazo';
  final diff = due.difference(now);
  final overdue = diff.isNegative;
  final span = overdue ? -diff : diff;
  final text = humanizeDuration(span);
  return overdue ? 'atrasado há $text' : 'vence em $text';
}

/// Duração em português curto: "45 min", "2 h", "2 h 10 min".
String humanizeDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  if (h <= 0) return '$m min';
  if (m == 0) return '$h h';
  return '$h h $m min';
}

/// "entrou há 3 h" — o tempo desde que o caso entrou na fila.
String waitingLabel(DateTime createdAt, DateTime now) {
  final span = now.difference(createdAt);
  if (span.isNegative) return 'entrou agora';
  return 'entrou há ${humanizeDuration(span)}';
}
