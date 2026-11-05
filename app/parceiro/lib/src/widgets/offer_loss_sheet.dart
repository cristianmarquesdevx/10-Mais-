import 'package:flutter/material.dart';

import '../api/client.dart' show OfferLoss;
import '../theme/theme.dart';

/// Fecha o ciclo da oferta explicando a consequência: quanto o parceiro deixou
/// passar, qual corrida era e como a taxa de aceite — critério do despacho —
/// ficou depois da recusa/tempo esgotado. Todos os números vêm do servidor;
/// a tela não simula desconto nem "perda" que o despacho não aplicou.
Future<void> showOfferLossSheet(BuildContext context, OfferLoss loss) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => _OfferLossSheet(loss: loss),
  );
}

class _OfferLossSheet extends StatelessWidget {
  _OfferLossSheet({required this.loss});

  final OfferLoss loss;

  @override
  Widget build(BuildContext context) {
    final expired = loss.expired;
    final before = loss.acceptanceRateBefore;
    final after = loss.acceptanceRate;
    return Container(
      decoration: BoxDecoration(
        color: tokensOf(context).surface,
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppSpace.radiusSheet),
        ),
      ),
      padding: EdgeInsets.fromLTRB(
        AppSpace.l,
        AppSpace.s,
        AppSpace.l,
        AppSpace.l,
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: EdgeInsets.only(bottom: AppSpace.m),
                decoration: BoxDecoration(
                  color: tokensOf(context).hairline.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Row(children: [
              Icon(expired ? Icons.timer_off_outlined : Icons.close_rounded,
                  color: AppColors.danger, size: 20),
              const SizedBox(width: AppSpace.s),
              Expanded(
                child: Text(
                  expired ? 'Oferta perdida por tempo' : 'Oferta recusada',
                  style: AppType.title,
                ),
              ),
            ]),
            const SizedBox(height: AppSpace.xs),
            Text(
              expired
                  ? 'Você tinha ${loss.timeoutS ?? 15} s para responder — a '
                      'corrida já foi para o próximo da fila.'
                  : 'A corrida já foi para o próximo da fila.',
              style: TextStyle(color: AppColors.muted, fontSize: 13),
            ),
            const SizedBox(height: AppSpace.l),
            // --- quanto deixou de ganhar ---
            Container(
              padding: EdgeInsets.symmetric(
                horizontal: AppSpace.m,
                vertical: AppSpace.m,
              ),
              decoration: BoxDecoration(
                color: AppColors.danger.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(AppSpace.radiusCard),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Você deixou de ganhar',
                      style: TextStyle(fontSize: 12, color: AppColors.muted)),
                  Text(brl(loss.lostAmount), style: AppType.money),
                ],
              ),
            ),
            const SizedBox(height: AppSpace.m),
            Row(children: [
              if (loss.pickupDistanceKm != null)
                Expanded(
                  child: _fact(
                    Icons.near_me_outlined,
                    'Coleta',
                    loss.pickupEtaMin != null
                        ? '${_km(loss.pickupDistanceKm!)} km · '
                            '${loss.pickupEtaMin} min'
                        : '${_km(loss.pickupDistanceKm!)} km',
                  ),
                ),
              if (loss.tripDistanceKm != null) ...[
                const SizedBox(width: AppSpace.m),
                Expanded(
                  child: _fact(
                    Icons.route_outlined,
                    'Corrida',
                    loss.tripDurationMin != null
                        ? '${_km(loss.tripDistanceKm!)} km · '
                            '${loss.tripDurationMin} min'
                        : '${_km(loss.tripDistanceKm!)} km',
                  ),
                ),
              ],
            ]),
            const SizedBox(height: AppSpace.l),
            Divider(height: 1, color: Color(0xFFE3E9E8)),
            const SizedBox(height: AppSpace.m),
            // --- efeito na prioridade das próximas chamadas ---
            Row(children: [
              Icon(Icons.trending_down_rounded,
                  size: 16, color: AppColors.primary),
              SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Sua prioridade nas próximas chamadas',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                ),
              ),
            ]),
            const SizedBox(height: AppSpace.xs),
            if (before != null && after != null)
              Row(children: [
                Text(
                  'Aceite ${_pct(before)}',
                  style: TextStyle(fontSize: 13, color: AppColors.muted),
                ),
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: 6),
                  child: Icon(Icons.arrow_forward_rounded,
                      size: 14, color: AppColors.muted),
                ),
                Text(
                  _pct(after),
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: AppColors.danger,
                  ),
                ),
                const SizedBox(width: AppSpace.s),
                if (after < before)
                  Text('−3%', style: TextStyle(fontSize: 12)),
              ]),
            const SizedBox(height: AppSpace.xs),
            Text(
              'A taxa de aceite é um dos critérios do despacho: quanto mais '
              'ofertas você aceita, mais cedo a próxima chamada chega. A '
              'penalização é suave e se recupera aceitando as próximas.',
              style: TextStyle(fontSize: 12, height: 1.35, color: AppColors.muted),
            ),
            const SizedBox(height: AppSpace.l),
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: Text('ENTENDI'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _fact(IconData icon, String label, String value) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(children: [
        Icon(icon, size: 13, color: AppColors.muted),
        const SizedBox(width: 4),
        Text(label,
            style: TextStyle(fontSize: 11, color: AppColors.muted)),
      ]),
      const SizedBox(height: 2),
      Text(value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
    ],
  );
}

/// `1,2` — mesmo padrão pt-BR do card da oferta.
String _km(double v) => v.toStringAsFixed(1).replaceAll('.', ',');

/// `95%` — arredonda como o despacho exibe na auditoria.
String _pct(double v) => '${(v * 100).round()}%';