#!/usr/bin/env python3
"""Smoke E2E do contrato contra a API de demonstração (scripts/demo_api.py).

Executa o fluxo que os dois apps fazem, sem UI:

    pedido (passageiro) → oferta (parceiro) → aceite → A_CAMINHO → CHEGOU
    → EM_VIAGEM → FINALIZADA (dinheiro) → pagamento → avaliação

Uso (com a demo já rodando):
    python scripts/smoke_demo_api.py [--base http://127.0.0.1:8787]

Sai com código != 0 no primeiro assert que falhar. O estado da demo é em
memória; cada execução cria uma corrida nova.
"""
from __future__ import annotations

import argparse
import json
import time
import urllib.error
import urllib.request
import uuid


def call(base: str, method: str, path: str, body: dict | None = None,
         idem: bool = False) -> tuple[int, dict]:
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(base + path, data=data, method=method)
    req.add_header("content-type", "application/json")
    if idem:
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

    print(f"smoke contra {base}")

    status, me = call(base, "GET", "/me")
    must(status == 200 and "user_id" in me, "GET /me devolve o perfil")

    # A demo guarda estado em memória e recusa um segundo pedido com 409
    # active_ride_exists. Sem esta checagem a falha parecia bug do app.
    status, active = call(base, "GET", "/rides?active=1")
    if status == 200 and active.get("rides"):
        raise SystemExit(
            f"a API em {base} já tem corrida ativa "
            f"({active['rides'][0]['ride_id']}); reinicie a demo para rodar o "
            "smoke a partir de um estado limpo")

    # O despacho só oferta a quem está online com posição fresca.
    status, _ = call(base, "POST", "/partner/online",
                     {"lat": -8.7610, "lon": -63.9040}, idem=True)
    must(status == 200, "POST /partner/online publica presença para o despacho")

    status, _ = call(base, "POST", "/rides", {
        "origin": {"lat": -8.7607, "lon": -63.9039},
        "destination": {"lat": -8.7647, "lon": -63.8969},
        "origin_address": "Centro, Porto Velho - RO",
        "destination_address": "Aeroporto, Porto Velho - RO",
        "pricing_mode": "TARIFF",
        "quoted_fare": 18.5,
    }, idem=True)
    must(status == 201, "POST /rides cria a corrida com Idempotency-Key")

    status, rides = call(base, "GET", "/rides?active=1")
    must(status == 200 and len(rides["rides"]) == 1, "a corrida aparece em /rides?active=1")
    ride = rides["rides"][0]
    ride_id = ride["ride_id"]
    # Com parceiro online o despacho já coloca a corrida em OFERTADA; sem
    # ninguém online ela fica em BUSCANDO. As duas são o nascimento válido.
    must(ride["status"] in ("BUSCANDO", "OFERTADA"),
         "corrida nasce em busca (BUSCANDO/OFERTADA)")

    offer = None
    deadline = time.time() + 10
    while time.time() < deadline and offer is None:
        status, offers = call(base, "GET", "/offers/mine")
        if status == 200 and offers["offers"]:
            offer = offers["offers"][0]
            break
        time.sleep(0.3)
    must(offer is not None, "GET /offers/mine entrega a oferta ao parceiro")
    assert offer is not None
    must(offer["ride_id"] == ride_id, "oferta aponta para a corrida criada")
    must(offer["amount"] == 18.5, "valor da oferta bate com o congelado no pedido")
    must(offer["trip_distance_km"] == ride.get("distance_km"),
         "km da oferta igual ao congelado no pedido (mesma distancia de rota)")

    status, _ = call(base, "POST", f"/offers/{offer['offer_id']}/accept", {}, idem=True)
    must(status == 200, "POST aceite com Idempotency-Key")
    status, current = call(base, "GET", f"/rides/{ride_id}")
    must(current["status"] == "ACEITA", "aceite leva a corrida para ACEITA")
    must(current.get("pricing_mode") in ("PASSE", "COMISSAO"),
         "aceite grava o pricing_mode_snapshot")

    # Percurso do motorista: a posição anda sobre a rota real (não é um pino
    # parado). É o que o mapa do passageiro usa para ver a moto se aproximar.
    first_pos = current.get("partner_position")
    must(first_pos is not None, "aceite publica partner_position no percurso")
    time.sleep(2.5)
    later_pos = call(base, "GET", f"/rides/{ride_id}")[1].get("partner_position")
    must(later_pos is not None and later_pos != first_pos,
         "o percurso simulado move a moto pela rota real")

    for to in ("A_CAMINHO", "CHEGOU", "EM_VIAGEM"):
        status, _ = call(base, "POST", "/partner/transitions",
                         {"ride_id": ride_id, "to": to}, idem=True)
        must(status == 200, f"transição para {to}")

    status, _ = call(base, "POST", "/partner/transitions", {
        "ride_id": ride_id, "to": "FINALIZADA",
        "fare_total": 18.5, "cash_declared": True,
    }, idem=True)
    must(status == 200, "transição para FINALIZADA com fare_total/cash_declared")

    status, done = call(base, "GET", f"/rides/{ride_id}")
    must(done["status"] == "FINALIZADA", "corrida termina FINALIZADA")
    must(done.get("distance_km") == offer["trip_distance_km"],
         "recibo repete o km da oferta (e da cotação)")
    must(done["payment_status"] == "CONFIRMED", "dinheiro declarado confirma o pagamento")
    must(done["fare_total"] == 18.5, "fare_total final é o valor declarado")

    status, payment = call(base, "POST", "/payments/ride",
                           {"ride_id": ride_id, "method": "PIX"}, idem=True)
    must(status == 201 and "pix" in payment, "POST /payments/ride devolve o PIX")

    status, _ = call(base, "POST", f"/rides/{ride_id}/rating",
                     {"stars": 5, "comment": "smoke"}, idem=True)
    must(status == 201, "POST rating registra a avaliação")

    # --- desempenho: aceite e nota do passageiro chegam na semana --------
    status, perf = call(base, "GET", "/partner/performance")
    must(status == 200, "GET /partner/performance responde")
    must(perf["acceptance"]["accepted"] >= 1,
         "o aceite da corrida entra na taxa da semana")
    must(perf["rating"]["week_count"] >= 1 and perf["rating"]["week_avg"] == 5.0,
         "a avaliação do passageiro entra no desempenho do motorista")
    must(perf["days"][-1]["offers"] >= 1,
         "a chamada de hoje aparece na série do dia")

    # --- PIX: quem confirma é o servidor, não a tela -----------------------
    # Corrida terminada SEM dinheiro declarado nasce PENDING; o app mostra
    # "Já paguei" e só avança quando este endpoint (webhook do PSP na demo)
    # devolve CONFIRMED.
    status, _ = call(base, "POST", "/rides", {
        "origin": {"lat": -8.7607, "lon": -63.9039},
        "destination": {"lat": -8.7647, "lon": -63.8969},
        "origin_address": "Centro, 100, Porto Velho - RO",
        "destination_address": "Aeroporto, 248, Porto Velho - RO",
        "pricing_mode": "TARIFF",
        "quoted_fare": 14.6,
    }, idem=True)
    must(status == 201, "segundo pedido (PIX) criado")
    status, rides = call(base, "GET", "/rides?active=1")
    pix_ride_id = rides["rides"][0]["ride_id"]
    offer = None
    deadline = time.time() + 10
    while time.time() < deadline and offer is None:
        offers = call(base, "GET", "/offers/mine")[1].get("offers", [])
        if offers:
            offer = offers[0]
            break
        time.sleep(0.3)
    must(offer is not None and offer["ride_id"] == pix_ride_id,
         "oferta do segundo pedido chega ao parceiro")
    call(base, "POST", f"/offers/{offer['offer_id']}/accept", {}, idem=True)
    for to in ("A_CAMINHO", "CHEGOU", "EM_VIAGEM"):
        call(base, "POST", "/partner/transitions",
             {"ride_id": pix_ride_id, "to": to}, idem=True)
    call(base, "POST", "/partner/transitions", {
        "ride_id": pix_ride_id, "to": "FINALIZADA",
        "fare_total": 14.6, "cash_declared": False,
    }, idem=True)
    status, pending = call(base, "GET", f"/rides/{pix_ride_id}")
    must(pending["payment_status"] == "PENDING",
         "corrida sem dinheiro declarado fica PENDING (não finge pago)")
    status, payment = call(base, "POST", "/payments/ride",
                           {"ride_id": pix_ride_id, "method": "PIX"}, idem=True)
    must(status == 201 and payment.get("pix", {}).get("copia_cola"),
         "PIX devolve QR + copia-e-cola")
    status, confirmed = call(
        base, "POST", f"/rides/{pix_ride_id}/payment/confirm", {}, idem=True)
    must(status == 200 and confirmed.get("payment_status") == "CONFIRMED",
         "confirmação do PSP fecha a corrida com payment_status CONFIRMED")

    status, wallet = call(base, "GET", "/partner/wallet")
    must(status == 200 and "balance" in wallet, "GET /partner/wallet devolve saldo/extrato")

    print("\nPASS — fluxo completo passou.")


if __name__ == "__main__":
    main()
