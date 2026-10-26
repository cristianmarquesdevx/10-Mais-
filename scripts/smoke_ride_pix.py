#!/usr/bin/env python3
"""Corrida completa pelo mesmo caminho HTTP dos apps, do pedido ao PIX.

O `e2e_emulator.py` prova isso pela interface; este roteiro prova o mesmo
contrato sem depender do emulador — útil quando o AVD está instável e para
conferir o estado final do servidor depois de qualquer execução.

Sequência (idêntica à dos apps):

    parceiro ONLINE (+ heartbeat de presença)
      → passageiro pede corrida (PIX, sem dinheiro declarado)
      → oferta no /offers/mine do parceiro
      → ACEITE
      → A_CAMINHO → CHEGOU → EM_VIAGEM → FINALIZADA
      → payment_status PENDING (ninguém declarou dinheiro)
      → POST /payments/ride (QR do PIX)
      → POST /rides/{id}/payment/confirm  → payment_status CONFIRMED
      → avaliação 5 estrelas (e o reenvio dá 409 already_rated)
      → nenhuma corrida ativa ao final

Uso (na raiz do repositório, com a demo rodando):
    python scripts/smoke_ride_pix.py [--base http://127.0.0.1:8787]
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


def main() -> int:
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", line_buffering=True)
        except (AttributeError, OSError):
            pass
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="http://127.0.0.1:8787")
    base = ap.parse_args().base.rstrip("/")
    print(f"corrida completa (PIX) contra {base}")

    # --- parceiro: online com posição e presença fresca --------------------
    status, _ = call(base, "POST", "/partner/online",
                     {"lat": -8.7610, "lon": -63.9040}, idem=True)
    ok(status == 200, "POST /partner/online (o que o app manda ao FICAR ONLINE)")
    status, _ = call(base, "POST", "/partner/heartbeat",
                     {"points": [{"lat": -8.7610, "lon": -63.9040}]})
    ok(status == 200, "POST /partner/heartbeat (pulso de 30 s do app)")
    status, near = call(base, "GET",
                        "/partners/nearby?lat=-8.7607&lon=-63.9039&radius_km=3")
    ok(status == 200 and near["eligible_count"] >= 1,
       "radar do passageiro enxerga o parceiro online")

    # --- passageiro: preço do momento e pedido com endereço completo ------
    status, quote = call(
        base, "GET",
        "/quote?origin_lat=-8.7607&origin_lon=-63.9039"
        "&dest_lat=-8.7465&dest_lon=-63.8940")
    ok(status == 200 and isinstance(quote.get("fare_total"), (int, float)),
       "GET /quote devolve o valor mostrado antes de confirmar")
    status, created = call(base, "POST", "/rides", {
        "origin": {"lat": -8.7607, "lon": -63.9039},
        "origin_address": "Av. Sete de Setembro, 1234 - Centro",
        "destination": {"lat": -8.7465, "lon": -63.8940},
        "destination_address": "Rua Rogério Weber, 890 - Centro",
        "pricing_mode": "TARIFF",
        "quoted_fare": quote["fare_total"],
        "service": "MOTO",
    }, idem=True)
    ok(status == 201, "POST /rides (toque em Chamar)")
    # O contrato responde 201 sem corpo; o app descobre a corrida pelo
    # GET /rides?active=1 (é o mesmo polling da tela de busca).
    status, active = call(base, "GET", "/rides?active=1")
    ok(status == 200 and len(active["rides"]) == 1,
       "GET /rides?active=1 mostra a corrida em BUSCANDO")
    ride = active["rides"][0]
    ride_id = ride["ride_id"]
    ok(isinstance(ride.get("fare_total"), (int, float)),
       "valor congelado no pedido")

    # --- parceiro: oferta e aceite ---------------------------------------
    status, offers = call(base, "GET", "/offers/mine")
    ok(status == 200 and len(offers["offers"]) == 1,
       "oferta chega em /offers/mine (tela P3)")
    offer = offers["offers"][0]
    ok(offer["ride_id"] == ride_id, "oferta é da corrida pedida")
    ok(bool(offer.get("dispatch")), "oferta explica o despacho (ranking)")
    status, _ = call(base, "POST", f"/offers/{offer['offer_id']}/accept",
                     idem=True)
    ok(status == 200, "POST accept (toque em ACEITAR)")
    status, detail = call(base, "GET", f"/rides/{ride_id}")
    ok(detail["status"] == "ACEITA", "corrida vai para ACEITA")

    # --- parceiro: transições até finalizar (sem dinheiro declarado) ------
    for to in ("A_CAMINHO", "CHEGOU", "EM_VIAGEM"):
        status, _ = call(base, "POST", "/partner/transitions",
                         {"ride_id": ride_id, "to": to}, idem=True)
        ok(status == 200, f"transição {to}")
    status, _ = call(base, "POST", "/partner/transitions",
                     {"ride_id": ride_id, "to": "FINALIZADA",
                      "fare_total": offer["amount"],
                      "cash_declared": False}, idem=True)
    ok(status == 200, "transição FINALIZADA (pagamento por PIX)")
    status, detail = call(base, "GET", f"/rides/{ride_id}")
    ok(detail["status"] == "FINALIZADA", "corrida FINALIZADA interpretada")
    ok(detail["payment_status"] == "PENDING",
       "sem dinheiro declarado o pagamento fica PENDING (nada de sucesso falso)")

    # --- passageiro: PIX e confirmação no backend ------------------------
    status, pay = call(base, "POST", "/payments/ride",
                       {"ride_id": ride_id, "method": "PIX"}, idem=True)
    ok(status == 201 and pay.get("pix", {}).get("copia_cola"),
       "POST /payments/ride devolve o PIX copia-e-cola")
    status, confirmed = call(base, "POST",
                             f"/rides/{ride_id}/payment/confirm", idem=True)
    ok(status == 200, "POST /rides/{id}/payment/confirm (toque em Já paguei)")
    ok(confirmed["payment_status"] == "CONFIRMED",
       "backend devolve payment_status CONFIRMED")
    status, again = call(base, "GET", f"/rides/{ride_id}")
    ok(again["payment_status"] == "CONFIRMED",
       "estado persistido: GET /rides/{id} segue CONFIRMED")

    # --- passageiro: avaliação -------------------------------------------
    status, _ = call(base, "POST", f"/rides/{ride_id}/rating", {"stars": 5},
                     idem=True)
    ok(status == 201, "POST /rides/{id}/rating grava as 5 estrelas")
    status, body = call(base, "POST", f"/rides/{ride_id}/rating", {"stars": 5})
    ok(status == 409 and body.get("code") == "already_rated",
       "reenviar a avaliação dá 409 already_rated (não gravou duas vezes)")

    # --- fila limpa -------------------------------------------------------
    status, active = call(base, "GET", "/rides?active=1")
    ok(status == 200 and active["rides"] == [],
       "nenhuma corrida ativa ao final")

    print(f"\nPASS — corrida {ride_id} finalizada e PIX confirmado "
          f"(R$ {ride['fare_total']:.2f}).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
