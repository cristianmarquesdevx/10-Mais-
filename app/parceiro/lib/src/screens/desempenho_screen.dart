import 'package:flutter/material.dart';

import '../../main.dart';
import '../api/client.dart';
import '../theme/theme.dart';

/// Desempenho do parceiro na semana (GET /partner/performance).
///
/// Tudo o que aparece aqui foi observado pelo servidor: chamadas enviadas,
/// aceites, recusas/timeouts, tempo conectado, posição na fila de cada
/// despacho e notas recebidas. Quando não houve evento no período a tela diz
/// "sem dados" em vez de mostrar 0% — número inventado esconderia o problema.
class DesempenhoScreen extends StatefulWidget {
  const DesempenhoScreen({super.key});

  @override
  State<DesempenhoScreen> createState() => _DesempenhoScreenState();
}

class _DesempenhoScreenState extends State<DesempenhoScreen> {
  DriverPerformance? _perf;
  String? _error;
  bool _loaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    _loaded = true;
    _load();
  }

  Future<void> _load() async {
    try {
      final p = await AppScope.apiOf(context).performance();
      if (mounted) {
        setState(() {
          _perf = p;
          _error = null;
        });
      }
    } on ApiProblem catch (p) {
      if (mounted) setState(() => _error = p.code);
    } catch (_) {
      if (mounted) setState(() => _error = 'offline');
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    final perf = _perf;
    return Scaffold(
      backgroundColor: t.background,
      appBar: AppBar(title: const Text('Meu desempenho')),
      body: perf == null && _error == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(AppSpace.l),
                children: [
                  if (perf != null) ...[
                    Text('Últimos 7 dias', style: AppType.title.copyWith(color: t.ink)),
                    const SizedBox(height: AppSpace.xs),
                    Text(
                      '${_range(perf.weekStart, perf.date)} · fuso de Porto Velho',
                      style: AppType.label.copyWith(color: t.muted),
                    ),
                    const SizedBox(height: AppSpace.l),
                    if (!perf.hasWeekData) _SemDados(perf: perf),
                    _MetricGrid(perf: perf),
                    const SizedBox(height: AppSpace.l),
                    const _SectionTitle('Semana'),
                    _WeekCard(perf: perf),
                    const SizedBox(height: AppSpace.l),
                    const _SectionTitle('Como ler esses números'),
                    _ComoLer(perf: perf),
                  ],
                  if (_error != null) ...[
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(AppSpace.l),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _error == 'offline'
                                  ? 'Sem conexão — não consegui carregar seu desempenho.'
                                  : 'O servidor não devolveu o desempenho ($_error).',
                              style: AppType.body.copyWith(color: t.ink),
                            ),
                            const SizedBox(height: AppSpace.m),
                            OutlinedButton(
                              onPressed: _load,
                              child: const Text('Tentar de novo'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
    );
  }

  /// "19 a 25 de out" — e "28 de set a 4 de out" quando vira o mês.
  static String _range(String start, String end) {
    final a = DateTime.tryParse(start);
    final b = DateTime.tryParse(end);
    if (a == null || b == null) return 'Semana atual';
    const months = ['jan', 'fev', 'mar', 'abr', 'mai', 'jun', 'jul', 'ago',
        'set', 'out', 'nov', 'dez'];
    if (a.month == b.month) return '${a.day} a ${b.day} de ${months[b.month - 1]}';
    return '${a.day} de ${months[a.month - 1]} a ${b.day} de ${months[b.month - 1]}';
  }
}

/// Aviso de semana sem eventos: o zero é ausência de dado, não desempenho.
class _SemDados extends StatelessWidget {
  const _SemDados({required this.perf});

  final DriverPerformance perf;

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpace.l),
      padding: const EdgeInsets.all(AppSpace.m),
      decoration: BoxDecoration(
        color: t.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppSpace.radiusCard),
        border: Border.all(color: t.primary.withValues(alpha: 0.25)),
      ),
      child: Row(children: [
        Icon(Icons.insights_outlined, size: 20, color: t.primary),
        const SizedBox(width: AppSpace.s),
        Expanded(
          child: Text(
            perf.sessionSeconds > 0
                ? 'Você está online há ${_dur(perf.sessionSeconds)}. Cada chamada '
                    'recebida, aceite, recusa e minuto conectado aparece aqui.'
                : 'Nenhuma chamada nesta semana. Fique online: cada chamada '
                    'recebida, aceite, recusa e minuto conectado conta aqui.',
            style: AppType.label.copyWith(color: t.ink),
          ),
        ),
      ]),
    );
  }
}

class _MetricGrid extends StatelessWidget {
  const _MetricGrid({required this.perf});

  final DriverPerformance perf;

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    final offers = perf.offers;
    final acceptanceValue =
        offers > 0 && perf.acceptanceWeek != null ? _pct(perf.acceptanceWeek) : '—';
    final acceptanceFoot = offers > 0
        ? '${perf.accepted} de $offers chamadas'
        : perf.acceptanceCurrent != null
            ? 'sem chamadas · agora ${_pct(perf.acceptanceCurrent)}'
            : 'sem chamadas nesta semana';

    final rankValue = perf.rankAvg != null ? '${_n1(perf.rankAvg!)}º' : '—';
    final rankFoot = perf.rankAvg != null
        ? (perf.rankPool != null && perf.rankPool! <= 1
            ? 'você era o único online'
            : 'de ${_n1(perf.rankPool ?? 0)} na fila · '
                '${perf.rankSamples} ${perf.rankSamples == 1 ? 'chamada' : 'chamadas'}')
        : 'sem chamadas para ranquear';

    final ratingFoot = perf.ratingValue == null
        ? 'sem avaliações ainda'
        : '${perf.ratingCount} avaliações'
            '${perf.weekRatings > 0 ? ' · ${perf.weekRatings} nesta semana' : ''}';

    return Column(children: [
      Row(children: [
        Expanded(
          child: _MetricCard(
            icon: Icons.task_alt,
            label: 'Taxa de aceite',
            value: acceptanceValue,
            foot: acceptanceFoot,
            accent: t.primary,
          ),
        ),
        const SizedBox(width: AppSpace.m),
        Expanded(
          child: _MetricCard(
            icon: Icons.schedule,
            label: 'Tempo online',
            value: perf.weekOnlineSeconds > 0
                ? _dur(perf.weekOnlineSeconds)
                : '—',
            foot: perf.todayOnlineSeconds > 0
                ? 'hoje ${_dur(perf.todayOnlineSeconds)}'
                : 'hoje ainda sem conexão',
            accent: t.primary,
          ),
        ),
      ]),
      const SizedBox(height: AppSpace.m),
      Row(children: [
        Expanded(
          child: _MetricCard(
            icon: Icons.star_outline,
            label: 'Avaliação',
            value: perf.ratingValue != null ? _n1(perf.ratingValue!) : '—',
            foot: ratingFoot,
            accent: t.warning,
          ),
        ),
        const SizedBox(width: AppSpace.m),
        Expanded(
          child: _MetricCard(
            icon: Icons.leaderboard_outlined,
            label: 'Posição no ranking',
            value: rankValue,
            foot: rankFoot,
            accent: t.earn,
          ),
        ),
      ]),
    ]);
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.icon,
    required this.label,
    required this.value,
    required this.foot,
    required this.accent,
  });

  final IconData icon;
  final String label, value, foot;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    return Container(
      padding: const EdgeInsets.all(AppSpace.l),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(AppSpace.radiusCard),
        border: Border.all(color: t.hairline.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(icon, size: 16, color: accent),
            const SizedBox(width: AppSpace.xs + 2),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppType.label.copyWith(color: t.muted, fontSize: 13),
              ),
            ),
          ]),
          const SizedBox(height: AppSpace.s),
          Text(
            value,
            style: AppType.money.copyWith(fontSize: 24, color: t.ink),
          ),
          const SizedBox(height: 2),
          Text(
            foot,
            maxLines: 2,
            style: AppType.label.copyWith(color: t.muted, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

/// Série dos 7 dias: barra de chamadas (teal = aceitas, âmbar = perdidas) e
/// o tempo conectado do dia. Cada linha é um dia real do calendário.
class _WeekCard extends StatelessWidget {
  const _WeekCard({required this.perf});

  final DriverPerformance perf;

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    final maxOffers = perf.days.fold<int>(
        1, (m, d) => d.offers > m ? d.offers : m);
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpace.m, vertical: AppSpace.s),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(AppSpace.radiusCard),
        border: Border.all(color: t.hairline.withValues(alpha: 0.25)),
      ),
      child: Column(children: [
        for (final d in perf.days)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 7),
            child: Row(children: [
              SizedBox(
                width: 34,
                child: Text(
                  d.weekday,
                  style: AppType.label.copyWith(
                    color: d.date == perf.date ? t.ink : t.muted,
                    fontWeight: d.date == perf.date
                        ? FontWeight.w700
                        : FontWeight.w500,
                  ),
                ),
              ),
              Expanded(child: _Bar(day: d, maxOffers: maxOffers)),
              const SizedBox(width: AppSpace.s),
              SizedBox(
                width: 46,
                child: Text(
                  d.offers > 0 ? '${d.accepted}/${d.offers}' : '—',
                  textAlign: TextAlign.right,
                  style: AppType.label.copyWith(
                    color: t.ink,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              const SizedBox(width: AppSpace.s),
              SizedBox(
                width: 62,
                child: Text(
                  d.onlineSeconds > 0 ? _durShort(d.onlineSeconds) : '—',
                  textAlign: TextAlign.right,
                  style: AppType.label.copyWith(
                    color: t.muted,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ]),
          ),
      ]),
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.day, required this.maxOffers});

  final PerfDay day;
  final int maxOffers;

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    const height = 8.0;
    if (day.offers == 0) {
      return Container(
        height: height,
        decoration: BoxDecoration(
          color: t.hairline.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(height / 2),
        ),
      );
    }
    // A largura da barra é a fração do dia com mais chamadas; dentro dela, a
    // parte teal é o que foi aceito e a âmbar o que se perdeu.
    final width = day.offers / maxOffers;
    final accepted = day.accepted / day.offers;
    return LayoutBuilder(builder: (context, box) {
      final full = box.maxWidth * width;
      return Row(children: [
        SizedBox(
          width: full * accepted,
          child: Container(
            height: height,
            decoration: BoxDecoration(
              color: t.primary,
              borderRadius: BorderRadius.circular(height / 2),
            ),
          ),
        ),
        SizedBox(
          width: full * (1 - accepted),
          child: Container(
            height: height,
            margin: const EdgeInsets.only(left: 2),
            decoration: BoxDecoration(
              color: t.warning.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(height / 2),
            ),
          ),
        ),
      ]);
    });
  }
}

class _ComoLer extends StatelessWidget {
  const _ComoLer({required this.perf});

  final DriverPerformance perf;

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    final lines = <String>[
      'A taxa de aceite pesa no despacho: recusar e deixar o tempo vencer '
          'reduzem sua prioridade nas próximas chamadas.',
      'A posição é onde você ficou na fila de motoristas elegíveis em cada '
          'chamada da semana — ganhando ou não a corrida.',
      'Tempo online é o que o servidor viu de conexão (heartbeat), não o '
          'tempo com o app aberto na galeria.',
    ];
    if (perf.missedOffers > 0) {
      final parts = <String>[
        if (perf.declined > 0)
          '${perf.declined} ${perf.declined == 1 ? 'recusada' : 'recusadas'}',
        if (perf.expired > 0)
          '${perf.expired} ${perf.expired == 1 ? 'perdida' : 'perdidas'} por tempo',
      ];
      lines.add('Nesta semana você perdeu ${perf.missedOffers} '
          '${perf.missedOffers == 1 ? 'chamada' : 'chamadas'}: '
          '${parts.join(' e ')}.');
    }
    return Container(
      padding: const EdgeInsets.all(AppSpace.l),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(AppSpace.radiusCard),
        border: Border.all(color: t.hairline.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final l in lines)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpace.s),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Padding(
                  padding: const EdgeInsets.only(top: 6, right: AppSpace.s),
                  child: Container(
                    width: 5,
                    height: 5,
                    decoration: BoxDecoration(
                      color: t.primary,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
                Expanded(
                  child: Text(l,
                      style: AppType.label.copyWith(color: t.muted)),
                ),
              ]),
            ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.s),
      child: Text(text, style: AppType.title.copyWith(color: t.ink)),
    );
  }
}

// ---------------------------------------------------------------------------
// Formatação (pt-BR, o mesmo padrão do resto do app)
// ---------------------------------------------------------------------------

String _pct(double? v) => v == null ? '—' : '${(v * 100).round()}%';

String _n1(double v) => v.toStringAsFixed(1).replaceAll('.', ',');

/// "3h 12min" / "41min" / "1h" — nunca "0h 0min".
String _dur(int seconds) {
  final total = seconds < 0 ? 0 : seconds;
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  if (h == 0) return '${m}min';
  if (m == 0) return '${h}h';
  return '${h}h ${m}min';
}

/// Versão curta para a série: "3h12".
String _durShort(int seconds) {
  final total = seconds < 0 ? 0 : seconds;
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  if (h == 0) return '${m}min';
  return '${h}h${m.toString().padLeft(2, '0')}';
}
