#!/usr/bin/env python3
"""Roteiro de demonstração: uma semana de desempenho gerada por eventos.

O que este roteiro NÃO faz: escrever números no histórico. Ele opera o relógio
de demonstração da API (``--time-travel``) e executa o MESMO caminho dos apps:

    fica online → recebe chamada → aceita / recusa / deixa vencer
    → finaliza → passageiro avalia

O servidor agrega tudo nas funções reais (``_perf_track``, ``_credit_online``,
``_sample_rank_for_call``). O que é simulado é o TEMPO (um turno por dia em
segundos), não o resultado.

Uso
---
    # terminal 1 — API que o emulador enxerga (10.0.2.2:8787)
    python scripts/demo_api.py --port 8787 --time-travel

    # terminal 2
    python scripts/demo_week.py

Depois: app do motorista → menu (☰) → **Meu desempenho**.

No emulador, o app já aponta para http://10.0.2.2:8787/functions/v1/v1 por
padrão; nenhum build especial é necessário. O estado da demo é em memória:
reiniciar a API zera a semana.
"""
from __future__ import annotations

import argparse
import json
import sys
import time
import urllib.error
import urllib.request
import uuid
from datetime import datetime, timedelta, timezone

# Fuso da praça: os baldes de desempenho do servidor usam UTC-4.
TZ = timezone(timedelta(hours=-4))

ORIGIN = (-8.7607, -63.9039)          # Centro de Porto Velho (embarque)
SELF_HOME = (-8.7607, -63.9039)       # motorista do app colado no embarque

# Colegas simulados: existem para a posição no ranking ter disputa de verdade
# (com um único motorista online a média seria sempre 1º de 1).
RIVALS = {
    "pv-ana": {"lat": -8.7497, "lon": -63.9039, "rating": 4.85,
               "rating_count": 213, "acceptance_rate": 0.94,
               "completed_rides": 640, "vehicle": "Moto"},
    "pv-carlos": {"lat": -8.7707, "lon": -63.9039, "rating": 4.72,
                  "rating_count": 98, "acceptance_rate": 0.91,
                  "completed_rides": 180, "vehicle": "Moto"},
}

# Destinos reais de Porto Velho (centroides do heatmap do servidor).
DESTINATIONS = [
    ("Arigolândia", -8.7563163, -63.9116496),
    ("Caiari", -8.7614459, -63.9063522),
    ("Olaria", -8.7556404, -63.9053544),
    ("São Cristóvão", -8.7585272, -63.8921177),
]

# Roteiro da semana: (dias atrás, minutos online, chamadas, rivais online)
#   A = aceita e finaliza   D = recusa   X = deixa vencer o tempo
#   S = outro motorista estava na frente (o app só ganha a amostra de ranking)
PLAN = [
    (6, 185, "AAAD", ("pv-ana",)),
    (5, 240, "AAAS", ("pv-ana", "pv-carlos")),
    (4, 130, "AD", ("pv-ana",)),
    (3, 265, "AAAX", ()),
    (2, 90, "X", ("pv-carlos",)),
    (1, 300, "AAADA", ("pv-ana", "pv-carlos")),
    (0, 120, "AS", ("pv-ana",)),
]

STARS = [5, 5, 4, 5, 4]   # notas que o passageiro dá, em ciclo


# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------

def call(base: str, method: str, path: str, body: dict | None = None,
         idem: bool = False) -> tuple[int, dict]:
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(base + path, data=data, method=method)
    req.add_header("content-type", "application/json")
    if idem:
        req.add_header("Idempotency-Key", str(uuid.uuid4()))
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            raw = resp.read().decode("utf-8")
            return resp.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8")
        return exc.code, (json.loads(raw) if raw else {})


def must(cond: bool, message: str) -> None:
    """Só interrompe o roteiro no primeiro desvio — a saída fica legível."""
    if not cond:
        raise SystemExit(f"FALHOU — {message}")


def set_clock(base: str, target_ts: float) -> None:
    """Leva o relógio da demo para um instante absoluto."""
    offset = target_ts - time.time()
    status, body = call(base, "POST", "/demo/clock", {"offset_s": round(offset, 3)})
    if status == 403:
        raise SystemExit(
            "A API está com o relógio fixo. Suba com --time-travel:\n"
            "    python scripts/demo_api.py --port 8787 --time-travel")
    must(status == 200, f"relógio em {body.get('now', '?')}")


# ---------------------------------------------------------------------------
# Atores
# ---------------------------------------------------------------------------

def go_online(base: str, *, lat: float, lon: float, driver_id: str | None = None,
              **extra) -> None:
    body = {"lat": lat, "lon": lon, **extra}
    if driver_id:
        body["driver_id"] = driver_id
    status, _ = call(base, "POST", "/partner/online", body, idem=True)
    must(status == 200, f"online: {driver_id or 'motorista do app'}")


def go_offline(base: str, driver_id: str | None = None) -> None:
    body = {"driver_id": driver_id} if driver_id else {}
    status, _ = call(base, "POST", "/partner/offline", body)
    must(status == 200, f"offline: {driver_id or 'motorista do app'}")


def create_ride(base: str, index: int, fare: float) -> str:
    label, lat, lon = DESTINATIONS[index % len(DESTINATIONS)]
    status, _ = call(base, "POST", "/rides", {
        "origin": {"lat": ORIGIN[0], "lon": ORIGIN[1]},
        "destination": {"lat": lat, "lon": lon},
        "origin_address": "Centro, 120 — Porto Velho",
        "destination_address": f"{label}, {140 + index * 37} — Porto Velho",
        "pricing_mode": "TARIFF",
        "quoted_fare": fare,
    }, idem=True)
    if status == 409:
        raise SystemExit("Já existe corrida ativa na API — reinicie a demo "
                         "(estado em memória) e rode o roteiro de novo.")
    must(status == 201, f"chamada criada (R$ {fare:.2f} → {label})")
    status, active = call(base, "GET", "/rides?active=1")
    must(status == 200 and active["rides"], "corrida ativa localizada")
    return active["rides"][0]["ride_id"]


def offer_for(base: str, driver_id: str | None = None,
              tries: int = 12) -> dict | None:
    path = "/offers/mine" + (f"?driver_id={driver_id}" if driver_id else "")
    for _ in range(tries):
        status, body = call(base, "GET", path)
        if status == 200 and body.get("offers"):
            return body["offers"][0]
        time.sleep(0.05)
    return None


def accept_and_finish(base: str, ride_id: str, offer: dict, *,
                      stars: int, pix: bool) -> None:
    status, _ = call(base, "POST", f"/offers/{offer['offer_id']}/accept", {}, idem=True)
    must(status == 200, "aceite")
    for to in ("A_CAMINHO", "CHEGOU", "EM_VIAGEM"):
        status, _ = call(base, "POST", "/partner/transitions",
                         {"ride_id": ride_id, "to": to}, idem=True)
        must(status == 200, f"transição {to}")
    status, _ = call(base, "POST", "/partner/transitions", {
        "ride_id": ride_id, "to": "FINALIZADA",
        "fare_total": offer["amount"], "cash_declared": not pix,
    }, idem=True)
    must(status == 200, "finalizada")
    if pix:
        status, _ = call(base, "POST", "/payments/ride",
                         {"ride_id": ride_id, "method": "PIX"}, idem=True)
        must(status == 201, "PIX cobrado")
        status, done = call(base, "POST", f"/rides/{ride_id}/payment/confirm", {})
        must(status == 200 and done.get("payment_status") == "CONFIRMED",
             "pagamento confirmado pelo servidor")
    status, _ = call(base, "POST", f"/rides/{ride_id}/rating",
                     {"stars": stars, "comment": "Roteiro de demonstração"},
                     idem=True)
    must(status == 201, f"passageiro avaliou com {stars}★")
    print(f"    ok  aceita  R$ {offer['amount']:>5.2f} - "
          f"{'PIX' if pix else 'dinheiro'} - {stars} estrelas")


def cancel(base: str, ride_id: str) -> None:
    status, _ = call(base, "POST", f"/rides/{ride_id}/cancel", {}, idem=True)
    must(status == 200, "chamada encerrada pelo passageiro")


# ---------------------------------------------------------------------------
# Um dia de turno
# ---------------------------------------------------------------------------

def gaps(total_min: int, n: int) -> list[int]:
    """Distribui o turno antes de cada chamada (determinístico, sem magia)."""
    if n <= 0:
        return []
    base = max(4, total_min // (n + 2))
    out = [base + (i % 3) * 3 for i in range(n)]
    while sum(out) > total_min - 5:
        out[-1] = max(3, out[-1] - 3)
    return out


def run_day(base: str, days_ago: int, online_min: int, script: str,
            rivals: tuple[str, ...], real_start: datetime) -> dict:
    day = (real_start - timedelta(days=days_ago)).replace(
        minute=0, second=0, microsecond=0)
    # Dia de hoje termina no instante atual (nada no futuro); os anteriores
    # começam às 9h da praça.
    if days_ago == 0:
        start = real_start - timedelta(minutes=online_min)
        midnight = real_start.replace(hour=0, minute=0, second=0, microsecond=0)
        if start < midnight + timedelta(minutes=5):
            start = midnight + timedelta(minutes=5)
            online_min = max(10, int((real_start - start).total_seconds() // 60))
    else:
        start = day.replace(hour=9)
    set_clock(base, start.timestamp())

    for rival in rivals:
        data = RIVALS[rival]
        go_online(base, lat=data["lat"], lon=data["lon"], driver_id=rival,
                  rating=data["rating"], rating_count=data["rating_count"],
                  acceptance_rate=data["acceptance_rate"],
                  completed_rides=data["completed_rides"],
                  vehicle=data["vehicle"])
    go_online(base, lat=SELF_HOME[0], lon=SELF_HOME[1])

    served = {"A": 0, "D": 0, "X": 0, "S": 0}
    ratings: list[int] = []
    cursor = start.timestamp()
    for i, (action, gap_min) in enumerate(zip(script, gaps(online_min, len(script)))):
        cursor += gap_min * 60
        set_clock(base, cursor)
        fare = round(13.9 + 2.3 * (i % 4), 2)

        if action == "S":
            # Outro motorista mais perto: o app não recebe a oferta, mas a
            # chamada entra na posição média dele (é disputa de verdade).
            rival = "pv-ana"
            go_online(base, lat=SELF_HOME[0] - 0.009, lon=SELF_HOME[1])
            go_online(base, lat=ORIGIN[0] + 0.0004, lon=ORIGIN[1],
                      driver_id=rival, **{k: v for k, v in RIVALS[rival].items()
                                          if k not in ("lat", "lon")})
            ride_id = create_ride(base, i, fare)
            stolen = offer_for(base, rival)
            must(stolen is not None, "a chamada foi para quem estava na frente")
            cancel(base, ride_id)
            # Volta ao normal para as próximas chamadas.
            go_online(base, lat=ORIGIN[0] + 0.0004, lon=ORIGIN[1], driver_id=rival,
                      **{k: v for k, v in RIVALS[rival].items()
                         if k not in ("lat", "lon")})
            go_online(base, lat=SELF_HOME[0], lon=SELF_HOME[1])
            served["S"] += 1
            print("    --  disputa perdida (outro motorista era o 1o da fila)")
            continue

        ride_id = create_ride(base, i, fare)
        offer = offer_for(base)
        must(offer is not None, "a oferta chegou no app do motorista")

        if action == "D":
            status, body = call(base, "POST",
                                f"/offers/{offer['offer_id']}/decline", {}, idem=True)
            must(status == 200 and body.get("loss", {}).get("reason") == "DECLINED",
                 "recusa registrada")
            served["D"] += 1
            cancel(base, ride_id)
            lost = body["loss"]
            print(f"    xx  recusa  R$ {lost['lost_amount']:>5.2f} - aceite "
                  f"{lost['acceptance_rate_before']:.0%}->{lost['acceptance_rate']:.0%}")
        elif action == "X":
            # Deixa o tempo vencer: 15 s do contrato, no relógio da demo.
            cursor += 17
            set_clock(base, cursor)
            gone = offer_for(base, tries=1)
            must(gone is None or gone["offer_id"] != offer["offer_id"],
                 "oferta venceu por tempo (o app não respondeu)")
            served["X"] += 1
            cancel(base, ride_id)
            print("    xx  tempo   oferta venceu sem resposta")
        else:  # A
            stars = STARS[len(ratings) % len(STARS)]
            accept_and_finish(base, ride_id, offer, stars=stars,
                              pix=len(ratings) % 2 == 1)
            ratings.append(stars)
            served["A"] += 1

    # Fecha o turno: o resto das horas acontece online e então sai.
    cursor = start.timestamp() + online_min * 60
    set_clock(base, cursor)
    go_offline(base)
    for rival in rivals:
        go_offline(base, rival)

    return {"day": day.strftime("%d/%m"), "online_min": online_min,
            **served, "ratings": ratings}


def main() -> None:
    # Windows usa cp1252 por padrão: o roteiro imprime acentos e setas.
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", line_buffering=True)
        except (AttributeError, OSError):
            pass
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--base", default="http://127.0.0.1:8787")
    args = ap.parse_args()
    base = args.base.rstrip("/")

    print(f"roteiro da semana contra {base}")
    status, me = call(base, "GET", "/me")
    must(status == 200 and me.get("partner", {}).get("kyc_status") == "APPROVED",
         "API de demonstração responde e o parceiro está aprovado")

    real_start = datetime.now(TZ)
    print(f"\nhoje na praça: {real_start.strftime('%d/%m/%Y %H:%M')} (UTC-4)")

    days = []
    for days_ago, online_min, script, rivals in PLAN:
        print(f"\n— {days_ago} dia(s) atrás · turno de {online_min} min · "
              f"{script}")
        days.append(run_day(base, days_ago, online_min, script, rivals,
                            real_start))

    # Volta ao presente e deixa o motorista online, como o app espera.
    call(base, "POST", "/demo/clock", {"offset_s": 0})
    go_online(base, lat=SELF_HOME[0], lon=SELF_HOME[1])

    print("\nresumo gerado pelo servidor (GET /partner/performance):")
    status, perf = call(base, "GET", "/partner/performance")
    must(status == 200, "desempenho da semana disponível")
    acc, online, rank = perf["acceptance"], perf["online"], perf["rank"]

    # Autoconferência: o que o servidor agregou tem de bater com o roteiro
    # (S não é chamada do app: quem recebeu foi outro motorista).
    offers = sum(len(s.replace("S", "")) for _, _, s, _ in PLAN)
    accepted = sum(s.count("A") for _, _, s, _ in PLAN)
    declined = sum(s.count("D") for _, _, s, _ in PLAN)
    expired = sum(s.count("X") for _, _, s, _ in PLAN)
    stolen = sum(s.count("S") for _, _, s, _ in PLAN)
    must(len(perf["days"]) == 7, "a semana tem 7 dias")
    must((acc["offers"], acc["accepted"], acc["declined"], acc["expired"])
         == (offers, accepted, declined, expired),
         f"contadores batem com o roteiro "
         f"({offers}/{accepted}/{declined}/{expired})")
    must(rank["samples"] == offers + stolen,
         f"posição amostrada em toda chamada disputada ({offers + stolen})")
    must(perf["rating"]["week_count"] == accepted,
         "cada corrida concluída recebeu uma nota")
    print(f"  chamadas .... {acc['offers']}  "
          f"(aceitas {acc['accepted']}, recusadas {acc['declined']}, "
          f"por tempo {acc['expired']})")
    print(f"  aceite ...... {acc['week']:.0%} na semana · "
          f"{acc['current']:.0%} agora")
    print(f"  online ...... {online['week_seconds'] // 3600}h"
          f"{(online['week_seconds'] % 3600) // 60:02d} na semana")
    print(f"  posição ..... {rank['avg']}º (melhor {rank['best']}º, "
          f"pior {rank['worst']}º, fila média {rank['pool']})")
    print(f"  notas ....... {perf['rating']['week_count']} na semana · "
          f"média {perf['rating']['week_avg']} · "
          f"geral {perf['rating']['value']} ({perf['rating']['count']} aval.)")

    for d in perf["days"]:
        print(f"    {d['weekday']} {d['date']}  "
              f"chamadas {d['accepted']}/{d['offers']}  |  "
              f"online {d['online_seconds'] // 60:>3}min  |  "
              f"posição {d['avg_rank'] or '-'}  |  "
              f"recusas {d['declined']}, tempo {d['expired']}")

    print("\nNo emulador: abra o app do motorista → menu (☰) → Meu desempenho.")
    print("Reinicie a API para zerar a semana (estado em memória).")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)
