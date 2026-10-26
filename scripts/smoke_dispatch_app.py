#!/usr/bin/env python3
"""Despacho pelo caminho real dos apps (sessão única, sem driver_id).

Diferença para `scripts/smoke_dispatch.py`: lá cada candidato é chamado com
`?driver_id=` para inspecionar o ranking com vários motoristas; aqui só existe
o parceiro real ("self"), exatamente como o app do motorista fala com a API —
`/offers/mine` sem id. Cobre oferta, recusa, rodadas sem aceite, reoferta,
aceite, transições até o fim e o piso que bloqueia corrida barata.

Uso (com a demo rodando e sem corrida ativa):
    python scripts/smoke_dispatch_app.py [--base http://127.0.0.1:8787]
"""
from __future__ import annotations

import argparse
import json
import sys
import time
import urllib.error
import urllib.request
import uuid


def call(base, method, path, body=None, idem=False):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(base + path, data=data, method=method)
    req.add_header("content-type", "application/json")
    if idem:
        req.add_header("Idempotency-Key", str(uuid.uuid4()))
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            raw = resp.read().decode()
            return resp.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode()
        return exc.code, (json.loads(raw) if raw else {})


def ok(cond, msg):
    if not cond:
        raise AssertionError(msg)
    print("  ok  " + msg)


def ride_body():
    return {
        "origin": {"lat": -8.7607, "lon": -63.9039},
        "origin_address": "Av. Sete de Setembro, 1234 - Centro",
        "destination": {"lat": -8.7465, "lon": -63.8940},
        "destination_address": "Rua Rogério Weber, 890 - Centro",
        "service": "MOTO",
    }


def main() -> int:
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", line_buffering=True)
        except (AttributeError, OSError):
            pass
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="http://127.0.0.1:8787")
    base = ap.parse_args().base.rstrip("/")
    print(f"despacho pelo caminho do app contra {base}")

    # --- parceiro do app: online + piso zero ------------------------------
    status, _ = call(base, "POST", "/partner/online",
                     {"lat": -8.7610, "lon": -63.9040}, idem=True)
    ok(status == 200, "POST /partner/online (presença do app)")
    status, prefs = call(base, "PUT", "/partner/preferences",
                         {"services": ["MOTO"], "min_fare": 0})
    ok(status == 200 and prefs["min_fare"] == 0, "preferências com piso 0")

    # --- corrida 1: oferta chega no /offers/mine sem driver_id -------------
    status, _ = call(base, "POST", "/rides", ride_body())
    ok(status == 201, "corrida criada pelo passageiro")
    status, active = call(base, "GET", "/rides?active=1")
    ok(status == 200 and len(active["rides"]) == 1,
       "app do passageiro acha a corrida em GET /rides?active=1")
    ride_id = active["rides"][0]["ride_id"]
    status, offers = call(base, "GET", "/offers/mine")
    ok(status == 200 and len(offers["offers"]) == 1,
       "app do parceiro vê a oferta em GET /offers/mine")
    offer = offers["offers"][0]
    ok(offer["ride_id"] == ride_id, "oferta é da corrida pedida")
    ok(offer["timeout_at"], "oferta traz o timeout do servidor")

    status, snap = call(base, "GET", f"/rides/{ride_id}/dispatch")
    ok(status == 200, "GET /rides/{id}/dispatch explica a rodada")
    ok(snap["round"] == 1 and snap["radius_km"] == 2.0, "rodada 1 com raio de 2 km")
    ok(any(c.get("reason") is None for c in snap["candidates"]),
       "candidato elegível aparece sem razão de recusa")
    ok(snap["candidates"][0]["components"]["eta"] is not None,
       "score auditável por componente (eta)")

    # --- recusa: volta a BUSCANDO e o motorista não é reofertado na hora ---
    status, _ = call(base, "POST", f"/offers/{offer['offer_id']}/decline")
    ok(status == 200, "app do parceiro recusa a oferta")
    status, detail = call(base, "GET", f"/rides/{ride_id}")
    ok(detail["status"] == "BUSCANDO", "corrida volta para BUSCANDO após recusa")
    status, offers = call(base, "GET", "/offers/mine")
    ok(offers["offers"] == [], "quem recusou não recebe a mesma oferta de novo na hora")
    status, snap = call(base, "GET", f"/rides/{ride_id}/dispatch")
    ok("self" in snap["excluded"], "recusado entra na lista de excluídos da rodada")

    # --- espera o cooldown: a corrida volta para a fila --------------------
    # Sem outro motorista, o despacho esgota as 3 rodadas (20 s cada) e só
    # então reabre a corrida para quem já recusou.
    print("  ..  aguardando as rodadas sem aceite (até 80 s)")
    deadline = time.time() + 80
    reoffered = None
    while time.time() < deadline:
        status, offers = call(base, "GET", "/offers/mine")
        if offers["offers"]:
            reoffered = offers["offers"][0]
            break
        time.sleep(2)
    ok(reoffered is not None,
       "sem outro motorista, a corrida volta para o mesmo parceiro após as rodadas")
    ok(reoffered["amount"] == offer["amount"],
       "valor da reoferta é o congelado no pedido")

    # --- aceite: corrida ACEITA e presença EM_CORRIDA ----------------------
    status, _ = call(base, "POST", f"/offers/{reoffered['offer_id']}/accept")
    ok(status == 200, "app do parceiro aceita")
    status, detail = call(base, "GET", f"/rides/{ride_id}")
    ok(detail["status"] == "ACEITA", "corrida vai para ACEITA")
    ok((detail.get("partner") or {}).get("name"), "corrida publica o parceiro")
    status, offers = call(base, "GET", "/offers/mine")
    ok(offers["offers"] == [], "parceiro em corrida não recebe oferta nova")

    # --- encerra a corrida 1 --------------------------------------------
    for to in ("A_CAMINHO", "CHEGOU", "EM_VIAGEM", "FINALIZADA"):
        payload = {"ride_id": ride_id, "to": to}
        if to == "FINALIZADA":
            payload.update({"fare_total": reoffered["amount"],
                            "cash_declared": True})
        status, _ = call(base, "POST", "/partner/transitions", payload, idem=True)
        ok(status == 200, f"transição {to}")

    # --- piso do parceiro bloqueia corrida barata -------------------------
    status, _ = call(base, "PUT", "/partner/preferences",
                     {"services": ["MOTO"], "min_fare": 80})
    ok(status == 200, "parceiro sobe o piso para R$ 80")
    status, _ = call(base, "POST", "/rides",
                     dict(ride_body(), service="MOTO_NEGOCIA"))
    ok(status == 201, "segunda corrida criada")
    status, active2 = call(base, "GET", "/rides?active=1")
    ride2_id = active2["rides"][0]["ride_id"]
    status, offers = call(base, "GET", "/offers/mine")
    ok(offers["offers"] == [], "corrida abaixo do piso não chega no app")
    status, snap2 = call(base, "GET", f"/rides/{ride2_id}/dispatch")
    reasons = {c["driver_id"]: c.get("reason") for c in snap2["candidates"]}
    ok(reasons.get("self") == "below_min_fare",
       "GET /rides/{id}/dispatch mostra below_min_fare")

    print("\nPASS — despacho funciona pelo caminho real dos dois apps.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
