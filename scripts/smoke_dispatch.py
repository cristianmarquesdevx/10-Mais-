#!/usr/bin/env python3
"""Smoke do despacho dinâmico contra a API de demonstração.

Prova, por HTTP (o mesmo contrato que os apps usam):

    ranking por distância entre perfis iguais
    → oferta só para o melhor
    → recusa → próximo da lista
    → recusa → próximo
    → valor mínimo e veículo incompatível ficam de fora

Uso (com a demo rodando em estado limpo):

    python scripts/smoke_dispatch.py [--base http://127.0.0.1:8787]
"""
from __future__ import annotations

import argparse
import json
import urllib.error
import urllib.parse
import urllib.request
import uuid

ORIGIN = (-8.7607, -63.9039)


def call(base: str, method: str, path: str, body: dict | None = None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(base + path, data=data, method=method)
    req.add_header("content-type", "application/json")
    if method == "POST":
        req.add_header("Idempotency-Key", str(uuid.uuid4()))
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            raw = resp.read().decode("utf-8")
            return resp.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8")
        return exc.code, (json.loads(raw) if raw else {})


def must(ok: bool, message: str) -> None:
    if not ok:
        raise AssertionError(message)
    print(f"  ok  {message}")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="http://127.0.0.1:8787")
    base = ap.parse_args().base.rstrip("/")
    print(f"despacho contra {base}")

    # Perfis idênticos, só a distância muda: o ranking tem de seguir ETA.
    drivers = {
        "near": (-8.7597, -63.9039),   # ~110 m
        "mid": (-8.7547, -63.9039),    # ~670 m
        "far": (-8.7457, -63.9039),    # ~1,7 km
        "picky": (-8.7597, -63.9039),  # colado, mas exige R$ 50
        "car": (-8.7597, -63.9039),    # colado, mas é carro
    }
    for did, (lat, lon) in drivers.items():
        payload = {"driver_id": did, "lat": lat, "lon": lon,
                   "completed_rides": 0, "rating": 4.9,
                   "rating_count": 300, "acceptance_rate": 1.0}
        if did == "picky":
            payload["min_fare"] = 50.0
        if did == "car":
            payload["vehicle"] = "Carro"
        status, _ = call(base, "POST", "/partner/online", payload)
        must(status == 200, f"parceiro {did} online")

    # Preferências: o piso do app sobrevive a um PUT que só troca os tipos
    # (o switch não pode resetar o valor mínimo).
    status, prefs = call(base, "PUT", "/partner/preferences", {
        "services": ["MOTO", "MOTO_NEGOCIA"], "min_fare": 6.5})
    must(status == 200 and prefs["min_fare"] == 6.5, "piso salvo nas preferências")
    status, prefs = call(base, "PUT", "/partner/preferences", {
        "services": ["MOTO", "MOTO_NEGOCIA"]})
    must(status == 200 and prefs["min_fare"] == 6.5,
         "trocar os tipos não reseta o valor mínimo")

    qs = urllib.parse.urlencode({
        "origin_lat": ORIGIN[0], "origin_lon": ORIGIN[1],
        "dest_lat": -8.7647, "dest_lon": -63.8969,
    })
    status, cotacao = call(base, "GET", f"/quote?{qs}")
    must(status == 200 and cotacao.get("quote_id"),
         "cotação emitida para o pedido (quote_id)")
    status, _ = call(base, "POST", "/rides", {
        "origin": {"lat": ORIGIN[0], "lon": ORIGIN[1]},
        "destination": {"lat": -8.7647, "lon": -63.8969},
        "origin_address": "Centro, 100, Porto Velho - RO",
        "destination_address": "Aeroporto, 248, Porto Velho - RO",
        "pricing_mode": "TARIFF",
        "quote_id": cotacao["quote_id"],
        "quoted_fare": cotacao["fare_total"],
    })
    must(status == 201, "corrida criada")
    rides = call(base, "GET", "/rides?active=1")[1]["rides"]
    ride_id = rides[0]["ride_id"]

    status, snap = call(base, "GET", f"/rides/{ride_id}/dispatch")
    must(status == 200, "GET /rides/{id}/dispatch explica a rodada")
    by_id = {c["driver_id"]: c for c in snap["candidates"]}
    must(by_id["picky"]["reason"] == "below_min_fare",
         "valor mínimo do parceiro exclui a corrida barata")
    must(by_id["car"]["reason"] == "vehicle_mismatch",
         "carro não recebe corrida de moto")
    eligible = [c["driver_id"] for c in snap["candidates"] if c["eligible"]]
    must(eligible[:3] == ["near", "mid", "far"],
         f"ranking por distância: {eligible[:3]}")
    must(snap["radius_km"] >= 2.0, "rodada começa no raio de 2 km")

    status, offers = call(base, "GET", "/offers/mine?driver_id=near")
    must(status == 200 and len(offers["offers"]) == 1,
         "o melhor motorista recebe a oferta")
    must(call(base, "GET", "/offers/mine?driver_id=mid")[1]["offers"] == [],
         "o segundo da lista ainda não recebeu nada")

    first = offers["offers"][0]
    # A oferta leva a explicação do despacho: é isso que a tela P3 mostra
    # ("por que esta oferta é sua"). Sem esses números o card não existe.
    why = first.get("dispatch")
    must(why is not None, "oferta traz o bloco `dispatch` (por que eu?)")
    must(why["rank"] == 1 and why["pool"] >= 3,
         f"posição na fila: 1º de {why['pool']}")
    must(abs(first["pickup_distance_km"] - 0.1) < 0.1,
         "distância até o embarque vem no card")
    must(isinstance(why["online_seconds"], int) and why["online_seconds"] >= 0,
         "tempo online do parceiro vem do relógio do servidor")
    must(why["rating"] == 4.9 and why["rating_count"] == 300,
         "nota e nº de avaliações usados no score")
    must(why["components"]["eta"] > 0.9,
         "componentes do score acompanham a oferta")

    status, dec = call(base, "POST", f"/offers/{first['offer_id']}/decline")
    must(status == 200, "melhor recusa a oferta")
    # A recusa devolve o que ele perdeu — é o que o app mostra na hora.
    loss = dec.get("loss") or {}
    must(loss.get("reason") == "DECLINED"
         and loss.get("lost_amount") == cotacao["fare_total"],
         "recusa devolve valor perdido e motivo")
    must(loss.get("acceptance_rate_before") == 1.0
         and loss["acceptance_rate"] < 1.0,
         f"aceite cai após recusar: {loss.get('acceptance_rate_before')} -> "
         f"{loss.get('acceptance_rate')}")
    must(loss.get("pickup_distance_km") == first["pickup_distance_km"],
         "a perda carrega a coleta que estava na oferta")
    status, closed = call(base, "GET", f"/offers/{first['offer_id']}")
    must(status == 200 and closed["status"] == "DECLINED"
         and closed["loss"]["reason"] == "DECLINED",
         "oferta fechada continua consultável (explica timeout/recusa)")
    status, offers = call(base, "GET", "/offers/mine?driver_id=mid")
    must(status == 200 and len(offers["offers"]) == 1,
         "reoferta vai para o próximo (mid)")
    must(offers["offers"][0]["amount"] == cotacao["fare_total"],
         "valor da reoferta é o congelado no pedido")
    must(offers["offers"][0]["dispatch"]["pool"] == 2,
         "a fila encolhe: quem recusou saiu dela")

    second = offers["offers"][0]
    must(call(base, "POST", f"/offers/{second['offer_id']}/decline")[0] == 200,
         "segundo recusa a oferta")
    status, offers = call(base, "GET", "/offers/mine?driver_id=far")
    must(status == 200 and len(offers["offers"]) == 1,
         "reoferta vai para o terceiro (far)")

    status, snap = call(base, "GET", f"/rides/{ride_id}/dispatch")
    must(snap["excluded"] == ["near", "mid"],
         "quem já recusou fica fora desta rodada")
    live = [o for o in call(base, "GET", "/offers/mine?driver_id=far")[1]["offers"]]
    must(len(live) == 1 and live[0]["offer_id"] == offers["offers"][0]["offer_id"],
         "a oferta viva continua com o terceiro")
    must(call(base, "GET", "/offers/mine?driver_id=near")[1]["offers"] == [],
         "quem recusou não recebe de novo na mesma rodada")

    third = offers["offers"][0]
    must(call(base, "POST", f"/offers/{third['offer_id']}/accept")[0] == 200,
         "terceiro aceita")
    detail = call(base, "GET", f"/rides/{ride_id}")[1]
    must(detail["status"] == "ACEITA", "corrida vai para ACEITA")
    must(detail.get("partner") is not None, "aceite publica o parceiro da corrida")

    # --- desempenho semanal: só o que o servidor viu ----------------------
    status, perf = call(base, "GET", "/partner/performance?driver_id=near")
    must(status == 200 and perf["timezone"] == "America/Porto_Velho",
         "GET /partner/performance devolve a semana do parceiro")
    must(len(perf["days"]) == 7 and perf["days"][-1]["date"] == perf["date"],
         "série cobre 7 dias terminando hoje (fuso da praça)")
    must(perf["acceptance"]["offers"] == 1
         and perf["acceptance"]["declined"] == 1,
         "a chamada recusada entra no dia como recusa")
    must(perf["acceptance"]["week"] == 0.0
         and perf["acceptance"]["current"] < 1.0,
         "taxa de aceite da semana reflete a recusa")
    must(perf["rank"]["avg"] == 1.0 and perf["rank"]["pool"] == 3.0,
         f"posição desta chamada: 1º de {perf['rank']['pool']:.0f}")
    must(perf["days"][-1]["rank_samples"] == 1,
         "a chamada conta uma vez na posição média")
    status, perf_mid = call(base, "GET", "/partner/performance?driver_id=mid")
    must(perf_mid["rank"]["avg"] == 2.0,
         "quem estava atrás tem posição média 2 — não é 1 fixo")

    print("\nPASS — despacho ranqueou, reofertou e respeitou os filtros.")


if __name__ == "__main__":
    main()
