import 'dart:async';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../../main.dart';
import '../api/client.dart' show OfferDispatch;
import '../state/partner_controller.dart';
import '../theme/theme.dart';
import '../widgets/offer_loss_sheet.dart';
import '../widgets/route_map.dart';

/// P3 Oferta — hierarquia obrigatória do OfferCard (FASE1-UX §1.5):
/// valor bruto 31 dp > distância de coleta > total > destino aproximado ≈
/// R$/h > cronômetro 15 s (contagem local; o timeout é do servidor — ao
/// expirar o servidor reassigna e some da lista).
///
/// O card responde à pergunta que o parceiro faz antes de aceitar: *o que é*
/// (Moto/Moto Negocia), *quanto paga* (e por que mais que o normal), *quem* é o
/// passageiro e *quanto tempo* custa a coleta e a viagem. A rota no mapa vem
/// das coordenadas da oferta; o endereço exato continua sendo a área — o
/// contrato não manda rua e número antes do aceite (privacidade).
class OfertaScreen extends StatefulWidget {
  const OfertaScreen({super.key});

  @override
  State<OfertaScreen> createState() => _OfertaScreenState();
}

class _OfertaScreenState extends State<OfertaScreen> {
  Timer? _t;

  /// Oferta que está na tela — é por ela que se pergunta ao servidor o que
  /// aconteceu quando a lista esvazia sozinha (timeout).
  String? _shownOfferId;

  /// Fechando a tela (recusa/expiração): impede o cronômetro e o botão de
  /// dispararem o resumo duas vezes.
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  void _tick() {
    if (!mounted || _closing) return;
    final p = AppScope.of(context);
    // Oferta expirou no servidor (lista vazia) → explica a perda e volta.
    if (p.offers.isEmpty && !p.busy) {
      _finish(expired: true);
      return;
    }
    setState(() {}); // reconta o cronômetro
  }

  /// Recusa explícita: mostra o que foi perdido antes de voltar ao painel.
  Future<void> _decline() async {
    if (_closing || _shownOfferId == null) return;
    _closing = true;
    final p = AppScope.of(context);
    final loss = await p.decline(_shownOfferId!);
    if (!mounted) return;
    if (loss != null) await showOfferLossSheet(context, loss);
    if (!mounted) return;
    if (p.offers.isEmpty) {
      Navigator.pop(context);
    } else {
      // Ainda restam ofertas (leva do servidor): segue no card.
      _closing = false;
    }
  }

  /// Oferta venceu no servidor: pergunta o motivo e o valor perdido. Antes a
  /// tela simplesmente desaparecia, sem o parceiro saber o que deixou passar.
  Future<void> _finish({required bool expired}) async {
    if (_closing) return;
    _closing = true;
    _t?.cancel();
    final p = AppScope.of(context);
    final id = _shownOfferId;
    final loss = (expired && id != null) ? await p.offerOutcome(id) : null;
    if (!mounted) return;
    if (loss != null) await showOfferLossSheet(context, loss);
    if (!mounted) return;
    Navigator.pop(context);
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = AppScope.of(context);
    final offers = p.offers;
    if (offers.isEmpty) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    final o = offers.first; // leva de 3: mostra uma por vez (mais antiga)
    _shownOfferId = o.offerId;
    final remain = o.remaining(DateTime.now());
    final secs = remain.inSeconds;
    // ≈ R$/h: assume velocidade média urbana 30 km/h (estimativa exibida,
    // nunca usada em cálculo de preço — motor de preço é servidor). É a mesma
    // velocidade de `pickup_eta_min`/`trip_duration_min` do servidor.
    final hours = ((o.pickupDistanceKm ?? 0) + (o.tripDistanceKm ?? 0)) / 30;
    final rph = hours > 0 ? o.amount / hours : null;
    final lat = o.origin, lon = o.destination;
    final hasMap = lat != null && lon != null;

    return PopScope(
      canPop: false, // ADX-UX-2: não sai da oferta por acidente
      child: Scaffold(
        body: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // --- topo: o que é + de quem é a oferta ---
              Padding(
                padding:
                    const EdgeInsets.fromLTRB(AppSpace.l, AppSpace.l, AppSpace.l, 0),
                child: Row(children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: AppSpace.m, vertical: 4),
                    decoration: BoxDecoration(
                      color: AppColors.primary.withValues(alpha: 0.14),
                      borderRadius:
                          BorderRadius.circular(AppSpace.radiusChip),
                    ),
                    child: Text(
                      o.serviceLabel,
                      style: const TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 13),
                    ),
                  ),
                  const Spacer(),
                  Text('Oferta #${o.offerId.substring(0, 8)}',
                      style: AppType.label),
                ]),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(AppSpace.l),
                  children: [
                    // --- preço + por que está acima da base ---
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Flexible(
                          child: Text(brl(o.amount),
                              style: AppType.display,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                        ),
                        if (o.priceMultiplier != null &&
                            (o.priceMultiplier! - 1).abs() >= 0.01)
                          Padding(
                            padding: const EdgeInsets.only(
                                left: AppSpace.s, bottom: AppSpace.s),
                            child: _MultiplierChip(
                                multiplier: o.priceMultiplier!),
                          ),
                      ],
                    ),
                    const SizedBox(height: AppSpace.xs),
                    const Text('bruto — com passe, 100% é seu',
                        style: AppType.label),
                    if (o.passengerName != null ||
                        o.passengerRating != null) ...[
                      const SizedBox(height: AppSpace.m),
                      Row(children: [
                        if (o.passengerRating != null) ...[
                          const Icon(Icons.star_rounded,
                              size: 18, color: Color(0xFFF5A623)),
                          const SizedBox(width: 2),
                          Text(_nota(o.passengerRating!),
                              style: const TextStyle(
                                  fontWeight: FontWeight.w700, fontSize: 14)),
                        ],
                        if (o.passengerName != null) ...[
                          const SizedBox(width: AppSpace.s),
                          Expanded(
                            child: Text(
                              o.passengerName!,
                              overflow: TextOverflow.ellipsis,
                              style: AppType.label,
                            ),
                          ),
                        ],
                      ]),
                    ],
                    const SizedBox(height: AppSpace.l),
                    // --- rota: coleta → destino ---
                    if (hasMap) ...[
                      RouteMap(
                        origin: LatLng(lat.lat, lat.lon),
                        destination: LatLng(lon.lat, lon.lon),
                        height: 180,
                        showHint: false,
                      ),
                      const SizedBox(height: AppSpace.l),
                    ],
                    Card(
                      child: Column(children: [
                        if (o.pickupDistanceKm != null)
                          ListTile(
                            leading: const Icon(Icons.near_me_outlined,
                                color: AppColors.primary),
                            title: Text('Coleta a ${_km(o.pickupDistanceKm!)} km'),
                            subtitle: o.pickupEtaMin != null
                                ? Text('≈ ${o.pickupEtaMin} min até o embarque')
                                : null,
                          ),
                        if (o.tripDistanceKm != null)
                          Divider(
                              height: 1,
                              indent: 16,
                              endIndent: 16,
                              color: Colors.grey.shade200),
                        if (o.tripDistanceKm != null)
                          ListTile(
                            leading: const Icon(Icons.route_outlined,
                                color: AppColors.primary),
                            title: Text(
                                'Corrida de ${_km(o.tripDistanceKm!)} km'),
                            subtitle: o.tripDurationMin != null
                                ? Text('≈ ${o.tripDurationMin} min até o destino')
                                : null,
                            trailing: rph != null
                                ? Text('≈ ${brl(rph)}/h', style: AppType.label)
                                : null,
                          ),
                        if (o.destinationArea != null) ...[
                          Divider(
                              height: 1,
                              indent: 16,
                              endIndent: 16,
                              color: Colors.grey.shade200),
                          ListTile(
                            leading: const Icon(Icons.location_on_outlined,
                                color: AppColors.muted),
                            title: Text('Destino: ${o.destinationArea}'),
                          ),
                        ],
                      ]),
                    ),
                    // --- por que ESTA oferta veio para este parceiro ---
                    // Fecha a lista de propósito: o essencial para decidir
                    // (preço, coleta, destino) continua acima; a explicação do
                    // despacho fica a um dedo de distância, sem empurrar nada.
                    if (o.dispatch != null) ...[
                      const SizedBox(height: AppSpace.l),
                      _WhyCard(
                        dispatch: o.dispatch!,
                        pickupDistanceKm: o.pickupDistanceKm,
                        pickupEtaMin: o.pickupEtaMin,
                      ),
                    ],
                  ],
                ),
              ),
              // --- cronômetro e decisão, sempre visíveis ---
              Padding(
                padding: const EdgeInsets.fromLTRB(
                    AppSpace.l, 0, AppSpace.l, AppSpace.l),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: Text(
                        '$secs s',
                        style: AppType.countdown.copyWith(
                          color:
                              secs <= 5 ? AppColors.danger : AppColors.primary,
                          fontSize: 39,
                        ),
                      ),
                    ),
                    const SizedBox(height: AppSpace.m),
                    FilledButton(
                      style: FilledButton.styleFrom(
                          backgroundColor: AppColors.earn),
                      onPressed: p.busy
                          ? null
                          : () async {
                              await p.accept(o.offerId, rideId: o.rideId);
                              if (p.status == PartnerStatus.emCorrida &&
                                  context.mounted) {
                                Navigator.pushReplacementNamed(
                                    context, '/em-corrida');
                              }
                            },
                      child: const Text('ACEITAR'),
                    ),
                    const SizedBox(height: AppSpace.m),
                    OutlinedButton(
                      onPressed: p.busy || _closing ? null : _decline,
                      child: const Text('Recusar'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Painel discreto do despacho: responde "por que eu?" com os mesmos números
/// que o motor de ranking usou — posição na fila, distância até o embarque,
/// tempo online e nota. Nada aqui é cálculo da tela: vem do payload.
class _WhyCard extends StatelessWidget {
  const _WhyCard({
    required this.dispatch,
    required this.pickupDistanceKm,
    required this.pickupEtaMin,
  });

  final OfferDispatch dispatch;
  final double? pickupDistanceKm;
  final int? pickupEtaMin;

  @override
  Widget build(BuildContext context) {
    final d = dispatch;
    final items = <Widget>[
      _item(Icons.emoji_events_outlined, 'Posição',
          d.pool > 1 ? '1º de ${d.pool} na fila' : 'Único na fila'),
      if (pickupDistanceKm != null)
        _item(
          Icons.near_me_outlined,
          'Até o embarque',
          pickupEtaMin != null
              ? '${_km(pickupDistanceKm!)} km · $pickupEtaMin min'
              : '${_km(pickupDistanceKm!)} km',
        ),
      if (d.onlineSeconds != null)
        _item(Icons.schedule, 'Online há', _dur(d.onlineSeconds!)),
      if (d.rating != null)
        _item(
          Icons.star_rounded,
          'Sua nota',
          (d.ratingCount ?? 0) > 0
              ? '${_nota(d.rating!)} · ${d.ratingCount} aval.'
              : _nota(d.rating!),
        ),
    ];

    // Duas colunas: o motorista lê a explicação de relance, sem perder o botão
    // ACEITAR de vista.
    final rows = <Widget>[];
    for (var i = 0; i < items.length; i += 2) {
      rows.add(Padding(
        padding: EdgeInsets.only(top: i == 0 ? 0 : AppSpace.m),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: items[i]),
            const SizedBox(width: AppSpace.m),
            Expanded(
              child: i + 1 < items.length ? items[i + 1] : const SizedBox(),
            ),
          ],
        ),
      ));
    }

    return Container(
      padding: const EdgeInsets.all(AppSpace.m),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(AppSpace.radiusCard),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.insights_outlined,
                size: 15, color: AppColors.primary),
            const SizedBox(width: 6),
            const Expanded(
              child: Text(
                'Por que esta oferta é sua',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
              ),
            ),
            if (d.acceptanceRate != null)
              Text(
                'aceite ${(d.acceptanceRate! * 100).round()}%',
                style: const TextStyle(fontSize: 11, color: AppColors.muted),
              ),
          ]),
          const SizedBox(height: AppSpace.s),
          ...rows,
        ],
      ),
    );
  }

  Widget _item(IconData icon, String label, String value) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(icon, size: 13, color: AppColors.muted),
            const SizedBox(width: 4),
            Text(label,
                style: const TextStyle(fontSize: 11, color: AppColors.muted)),
          ]),
          const SizedBox(height: 2),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
          ),
        ],
      );
}

/// Tempo online no formato que se fala: `12 min`, `1 h 20 min`, `3 h`.
String _dur(int seconds) {
  if (seconds < 60) return 'menos de 1 min';
  final m = seconds ~/ 60;
  if (m < 60) return '$m min';
  final h = m ~/ 60, rest = m % 60;
  return rest == 0 ? '$h h' : '$h h $rest min';
}

/// `×1,33` — o preço acima da base não é arbítrio da tela: é a demanda/hora
/// que o servidor aplicou e congelou no pedido.
class _MultiplierChip extends StatelessWidget {
  const _MultiplierChip({required this.multiplier});

  final double multiplier;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpace.s, vertical: 3),
        decoration: BoxDecoration(
          color: const Color(0xFFF5A623).withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(AppSpace.radiusChip),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.bolt, size: 13, color: Color(0xFFB26A00)),
          const SizedBox(width: 2),
          Text(
            'Preço ×${_mult(multiplier)}',
            style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: Color(0xFFB26A00)),
          ),
        ]),
      );
}

/// Quilometragem no padrão pt-BR (`1,2`), igual ao que o passageiro vê:
/// oferta, card e recibo precisam exibir o MESMO número, não só o mesmo valor.
String _km(double v) => v.toStringAsFixed(1).replaceAll('.', ',');

/// Nota com 1 decimal no padrão pt-BR (`4,9`) — `toStringAsFixed` usa ponto.
String _nota(double v) => v.toStringAsFixed(1).replaceAll('.', ',');

/// Multiplicador com 2 decimais (`1,33`); `1,0` vira `1` para não poluir.
String _mult(double v) {
  final s = v.toStringAsFixed(2).replaceAll('.', ',');
  return s.endsWith(',00')
      ? s.substring(0, s.length - 3)
      : s.endsWith('0')
          ? s.substring(0, s.length - 1)
          : s;
}
