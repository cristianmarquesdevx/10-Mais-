#!/usr/bin/env python3
"""Simulador de despacho — 10 é + (Fase 2).

Implementa fielmente a SPECS.md §1 (rodadas, leva de N=3, timeout 15 s,
reoferta) e §4 (recálculo de ETA: a cada 90 s em viagem, por fase, por
virada de rota; alarme ≤ 4 min idempotente) para derivar as contagens
por corrida usadas no CUSTO-CAPACIDADE.md §1.

Uso:
    python3 scripts/dispatch_sim.py [--rides 50000] [--seed 42]

Saída: médias por corrida (Edge invocações, msgs Realtime, ofertas,
rodadas) com desvio-padrão, para confrontar com o modelo manual do
documento de custo. Determinístico via --seed.
"""
from __future__ import annotations

import argparse
import math
import sys
import random
import statistics
from dataclasses import dataclass, field

# --- parâmetros PRM (SPECS §1; defaults documentados) ---------------------
R0_KM = 2.0            # PRM-match.r0
PASSO_KM = 1.0         # PRM-match.passo
RMAX_KM = 8.0          # PRM-match.rmax
ROUND_TIMEOUT_S = 15   # PRM-oferta.timeout
N_OFFERS = 3           # leva simultânea limitada (SPECS §1.2)
MAX_ROUNDS = int((RMAX_KM - R0_KM) / PASSO_KM) + 1  # 7 rodadas até rmax

# --- parâmetros de comportamento (estimativa inicial, calibrar c/ dados) --
P_ACCEPT = 0.70        # taxa de aceite-alvo (Fase 0: aceitação > 70%)
CANDIDATE_DENSITY = 0.30  # parceiros ONLINE_DISPONIVEL/km² (24-30 online de um fundo de 40-60 em ~100 km²)
TRIP_MEAN_MIN = 16.0   # duração média da viagem (cidade de porte médio)
TRIP_SIGMA = 0.45      # lognormal
ETA_RECALC_PERIOD_S = 90    # SPECS §4(b)
ROUTE_CHANGE_P = 0.30        # SPECS §4(a) prob. de virada de rota material
DEVIATION_P = 0.25           # SPECS §4(c) desvio > 200 m do traçado
P_SHARE = 0.20         # share 20% (modelo de custo §1)
P_CANCEL = 0.08        # cancel 8%
P_NEGOTIATE = 0.15     # negociação aberta
P_POLL = 0.60          # usa poll de estado (fallback Realtime)


@dataclass
class Counters:
    edge: dict = field(default_factory=dict)
    rt: dict = field(default_factory=dict)
    route: dict = field(default_factory=dict)

    def add(self, bucket: str, key: str, n: int = 1) -> None:
        d = getattr(self, bucket)
        d[key] = d.get(key, 0) + n

    @staticmethod
    def merge(dst: "Counters", src: "Counters") -> None:
        for bucket in ("edge", "rt", "route"):
            for k, v in getattr(src, bucket).items():
                getattr(dst, bucket)[k] = getattr(dst, bucket).get(k, 0) + v


def candidates_in(radius_km: float, rng: random.Random) -> int:
    """Parceiros elegíveis dentro do raio (Poisson com densidade PRM)."""
    area = math.pi * radius_km ** 2
    lam = CANDIDATE_DENSITY * area
    # Poisson simples sem numpy
    L = math.exp(-lam)
    k, p = 0, 1.0
    while True:
        p *= rng.random()
        if p <= L:
            return k
        k += 1


def simulate_ride(rng: random.Random, c: Counters) -> None:
    # --- despacho (SPECS §1.1-1.3) ---------------------------------------
    offered: set[int] = set()
    rounds = 0
    accepted = False
    for n in range(MAX_ROUNDS):
        radius = min(R0_KM + n * PASSO_KM, RMAX_KM)
        rounds += 1
        c.add("edge", "dispatch_round")
        pool = [i for i in range(candidates_in(radius, rng)) if i not in offered]
        rng.shuffle(pool)
        # f(ETA) do score exige ETA do provedor p/ cada candidato elegível (SPECS §1.3)
        c.add("route", "dispatch_matrix_elt", len(pool))
        wave = pool[:N_OFFERS]
        offered.update(wave)
        # leva simultânea: os 3 recebem a oferta ao mesmo tempo (SPECS §1.2);
        # o primeiro a aceitar vence (FOR UPDATE), os demais perdem ou expiram
        c.add("rt", "offer_sent", len(wave))            # -> canal dos parceiros
        accepters = [i for i in wave if rng.random() < P_ACCEPT]
        if accepters:
            accepted = True
            c.add("rt", "offer_accepted")               # 1º vencedor
            c.add("rt", "offer_unavailable", len(accepters) - 1)  # aceitaram tarde
            c.add("rt", "offer_expired", len(wave) - len(accepters))
            break
        c.add("rt", "offer_expired", len(wave))         # timeout da rodada
        if accepted:
            break
        if not wave:                              # sem candidatos: reoferta total
            offered.clear()
    if not accepted:
        # 3 rodadas sem aceite → nova rodada com todos (SPECS §1.3);
        # se mesmo assim falha, a corrida expira — conta como não servida
        c.add("rt", "search_timeout")

    c.add("rt", "ride_state", 1 if not accepted else 1)  # created/buscando
    if not accepted:
        return

    # --- aceite → estados --------------------------------------------------
    for phase in ("ride.aceita", "ride.a_caminho", "ride.chegou",
                  "ride.em_viagem", "ride.finalizada"):
        c.add("rt", "ride_state")

    # --- ETA (SPECS §4) ----------------------------------------------------
    trip_min = rng.lognormvariate(math.log(TRIP_MEAN_MIN), TRIP_SIGMA)
    trip_recalcs = int(trip_min * 60 // ETA_RECALC_PERIOD_S)
    c.add("edge", "eta_recalc", 4)                       # (d) por fase (aceita→em_viagem)
    c.add("rt", "eta_update", 4)
    c.add("edge", "eta_recalc", trip_recalcs)            # (b) 90 s em viagem
    c.add("rt", "eta_update", trip_recalcs)
    if rng.random() < ROUTE_CHANGE_P:                    # (a) virada de rota
        c.add("edge", "eta_recalc")
        c.add("rt", "eta_update")
        c.add("route", "eta_provider", 1)
    if rng.random() < DEVIATION_P:                       # (c) desvio > 200 m
        c.add("edge", "eta_recalc")
        c.add("rt", "eta_update")
        c.add("route", "eta_provider", 1)
    # rota de precificação origem→destino (km do motor de preço) = 1 chamada paga
    c.add("route", "pricing_route", 1)
    # chamadas pagas ao provedor de rotas/corrida:
    #   como especificado (SPECS §4): cada recálculo = chamada paga
    c.add("route", "eta_as_spec", 4 + trip_recalcs)
    #   alavanca (otimização): 90 s em viagem c/ modelo local de velocidade
    #   (GPS próprio, sem conteúdo Google armazenado → conforme política) e
    #   ETA do despacho c/ distância/speed-line p/ ranquear f(ETA)
    c.add("route", "alavanca_eta", 4)
    if trip_min > 4:                                     # alarme ≤4 min: 1 por corrida
        c.add("edge", "alarm_eval", 1)
        c.add("rt", "alarm", 1 if rng.random() < 0.5 else 0)

    # --- ciclo de vida da API ---------------------------------------------
    c.add("edge", "ride_create")
    c.add("edge", "offer_accept")
    c.add("edge", "transitions", 4)
    c.add("edge", "payment_start")
    c.add("edge", "psp_webhook")
    if rng.random() < P_POLL:
        c.add("edge", "ride_poll", 4)                    # ~4 polls de fallback
    if rng.random() < P_CANCEL:
        c.add("edge", "ride_cancel")
        c.add("rt", "ride_cancelled")
    if rng.random() < P_SHARE:
        c.add("edge", "share_link")
    if rng.random() < P_NEGOTIATE:
        c.add("edge", "negotiation", 2)
        c.add("rt", "negotiation", 2)


def google_monthly(events: float, sku: str) -> float:
    """Custo mensal USD com tiers oficiais (preços Google 10/2026):
    free cap Essentials 10k / Pro 5k; depois 0-100k, 100k-500k, 500k-1M,
    1M-5M, 5M+. Mesmo preço por evento de ComputeRoutes e Route Matrix."""
    if sku == "essentials":
        free, t = 10_000, [(100_000, .005), (500_000, .004), (1_000_000, .003),
                           (5_000_000, .0015), (float("inf"), .00038)]
    else:  # Pro = traffic-aware
        free, t = 5_000, [(100_000, .010), (500_000, .008), (1_000_000, .006),
                          (5_000_000, .003), (float("inf"), .00075)]
    billable = max(events - free, 0.0)
    cost, prev = 0.0, free
    for upper, price in t:
        if billable <= 0:
            break
        seg = min(billable, upper - prev)
        if seg > 0:
            cost += seg * price
            billable -= seg
        prev = upper
    return cost


def main() -> None:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    ap = argparse.ArgumentParser()
    ap.add_argument("--rides", type=int, default=50_000)
    ap.add_argument("--seed", type=int, default=42)
    args = ap.parse_args()

    rng = random.Random(args.seed)
    total = Counters()
    per_ride_edge, per_ride_rt = [], []
    for _ in range(args.rides):
        c = Counters()
        simulate_ride(rng, c)
        Counters.merge(total, c)
        per_ride_edge.append(sum(c.edge.values()))
        per_ride_rt.append(sum(c.rt.values()))

    n = args.rides
    print(f"== simulador de despacho SPECS §1/§4 · {n:,} corridas · seed {args.seed} ==")
    print(f"rodadas máx: {MAX_ROUNDS} (r0 {R0_KM} → rmax {RMAX_KM} km, passo {PASSO_KM})")
    print(f"não servidas (timeout de raio): "
          f"{total.rt.get('search_timeout', 0) / n * 100:.2f}%")
    print("\n-- Edge invocações/corrida (por tipo) --")
    for k in sorted(total.edge, key=lambda k: -total.edge[k]):
        print(f"  {k:<16} {total.edge[k] / n:6.2f}")
    print(f"  {'TOTAL':<16} {statistics.mean(per_ride_edge):6.2f} "
          f"(p95 {sorted(per_ride_edge)[int(n * 0.95)]})")
    print("\n-- msgs Realtime/corrida (por tipo) --")
    for k in sorted(total.rt, key=lambda k: -total.rt[k]):
        print(f"  {k:<16} {total.rt[k] / n:6.2f}")
    print(f"  {'TOTAL':<16} {statistics.mean(per_ride_rt):6.2f} "
          f"(p95 {sorted(per_ride_rt)[int(n * 0.95)]})")
    print("\n-- chamadas ao provedor de rotas/corrida (Google Routes) --")
    for k in sorted(total.route, key=lambda k: -total.route[k]):
        print(f"  {k:<26} {total.route[k] / n:6.2f}")
    paid_as_spec = (total.route.get("eta_as_spec", 0)
                    + total.route.get("eta_provider", 0)   # gatilhos (a) virada e (c) desvio
                    + total.route.get("pricing_route", 0)
                    + total.route.get("dispatch_matrix_elt", 0)) / n
    paid_lever = (total.route.get("alavanca_eta", 0)
                  + total.route.get("eta_provider", 0)
                  + total.route.get("pricing_route", 0)) / n   # f(ETA) local p/ despacho
    print(f"  {'TOTAL como SPECS':<26} {paid_as_spec:6.2f} chamadas pagas/ride")
    print(f"  {'TOTAL com alavancas':<26} {paid_lever:6.2f} chamadas pagas/ride")

    # projeção mensal nos cenários do documento (com tiers Google 10/2026:
    # Essentials US$ 0,005/evento no primeiro tier, traffic-aware US$ 0,010;
    # free tier 10k/5k por mês — desprezível nos volumes B/C)
    for label, per_day in (("A", 1_000), ("B", 10_000)):
        rides_m = per_day * 30
        edge_m = statistics.mean(per_ride_edge) * rides_m / 1e6
        rt_m = statistics.mean(per_ride_rt) * rides_m / 1e6
        routes_spec = paid_as_spec * rides_m
        routes_lever = paid_lever * rides_m
        print(f"\nCenário {label} ({per_day}/dia, {rides_m:,}/mês): "
              f"Edge {edge_m:.2f}M inv · Realtime {rt_m:.2f}M msgs")
        print(f"  Google Routes {routes_spec:,.0f} eventos/mês (como SPECS) → "
              f"US$ {google_monthly(routes_spec, 'essentials'):,.0f} (Essentials) – "
              f"US$ {google_monthly(routes_spec, 'pro'):,.0f} (traffic-aware)")
        print(f"  Google Routes {routes_lever:,.0f} eventos/mês (com alavancas) → "
              f"US$ {google_monthly(routes_lever, 'essentials'):,.0f} (Essentials) – "
              f"US$ {google_monthly(routes_lever, 'pro'):,.0f} (traffic-aware)")
        edge_over = max(edge_m - 2.0, 0) * 2.0
        rt_over = max(rt_m - 5.0, 0) * 2.50
        print(f"  Supabase excedente: Edge US$ {edge_over:.2f} + "
              f"Realtime US$ {rt_over:.2f} (incluído: 2M inv / 5M msgs)")


if __name__ == "__main__":
    main()
