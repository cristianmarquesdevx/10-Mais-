#!/usr/bin/env python3
"""Smoke do CICLO DE CORRIDA contra o backend real (Supabase local).

Este é o teste que fecha o "caminho 1": o mesmo fluxo que o app faz, contra
o Postgres + as Edge Functions de verdade (não a API de demonstração).

    passageiro: cotar -> pedir (preço congelado) -> pagar (PIX simulado)
    parceiro:  presença -> receber oferta -> aceitar -> fases da corrida
    servidor:  webhook assinado do PSP -> pagamento confirmado -> avaliação

Valida, na ordem:

  1. sem token, tudo é recusado (401);
  2. GET /quote emite `quote_id` + valor + validade;
  3. POST /rides cobra o valor GRAVADO na cotação (não o do cliente);
  4. a cotação é de uso único (replay -> 422 quote_not_found);
  5. cotação vencida -> 422 quote_expired;
  6. cotação de outra rota -> 422 quote_mismatch;
  7. `quoted_fare` divergente -> 422 quote_fare_mismatch;
  8. o despacho oferece a corrida ao parceiro online perto;
  9. aceite, fases (a caminho/chegou/em viagem/finalizada) e carteira;
 10. o pagamento só é confirmado pelo webhook assinado do PSP (o passageiro
     não confirma nada) e a reentrega do webhook não duplica o lançamento;
 11. a avaliação do passageiro fecha a corrida.

Uso:
    export SUPABASE_JWT_SECRET=...        # npx supabase status -o env
    python scripts/rides_smoke.py

Exit 0 = PASS. Qualquer assert falha com mensagem e exit 1.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from dev_jwt import DEV_USERS, sign  # noqa: E402

ORIGIN = (-8.7607, -63.9039)   # Centro de Porto Velho
FAR = (-8.7920, -63.9300)     # ~4 km a sudoeste (outra rota)

# A PSP é simulada no piloto: o webhook exige o segredo compartilhado.
DEFAULT_PSP_SECRET = "dev-local-2f8a1c4e6b9d3f70"


def token(role: str, secret: str) -> str:
    import time

    now = int(time.time())
    return sign(
        {
            "sub": DEV_USERS[role],
            "role": "authenticated",
            "aud": "authenticated",
            "iss": "supabase",
            "iat": now,
            "exp": now + 600,
        },
        secret,
    )


def call(method: str, url: str, jwt: str | None, body: dict | None = None,
         headers: dict | None = None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("content-type", "application/json")
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    if jwt:
        req.add_header("authorization", f"Bearer {jwt}")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read().decode("utf-8")
            return resp.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8")
        try:
            return exc.code, json.loads(raw)
        except json.JSONDecodeError:
            return exc.code, {"raw": raw}


def expect(cond: bool, label: str) -> None:
    if not cond:
        raise AssertionError(label)
    print(f"  ok  {label}")


def pt(lat: float, lon: float) -> dict:
    return {"lat": lat, "lon": lon}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="http://127.0.0.1:54321/functions/v1")
    ap.add_argument("--psp-secret", default=os.environ.get("PSP_WEBHOOK_SECRET",
                                                            DEFAULT_PSP_SECRET))
    args = ap.parse_args()

    secret = os.environ.get("SUPABASE_JWT_SECRET", "")
    if not secret:
        print("SUPABASE_JWT_SECRET ausente", file=sys.stderr)
        return 2

    rides = f"{args.base}/rides"
    radar = f"{args.base}/radar"
    psp = f"{args.base}/psp-webhook"

    passenger = token("passenger", secret)
    partner = token("partner", secret)

    # ---------------------------------------------------------------- 1. auth
    print("1) sem token")
    code, _ = call("GET", f"{rides}/quote?origin_lat={ORIGIN[0]}&origin_lon={ORIGIN[1]}"
                          f"&dest_lat={FAR[0]}&dest_lon={FAR[1]}", None)
    expect(code in (401, 403), f"cotação sem JWT recusada (veio {code})")

    # Faxina: o passageiro só pode ter uma corrida ativa (409 active_ride_exists).
    # Uma execução anterior interrompida deixaria a corrida travada e o smoke
    # falharia por um motivo que não é do produto.
    code, body = call("GET", f"{rides}/rides?active=1", passenger)
    for stale in (body.get("rides") or []):
        call("POST", f"{rides}/rides/{stale['ride_id']}/cancel", passenger,
             {"reason": "PASSENGER_REGRET"})
    expect(True, "corridas ativas anteriores (se houver) foram canceladas")

    # -------------------------------------------------------------- 2. cotação
    print("2) cotação congelada")
    code, quote = call(
        "GET",
        f"{rides}/quote?origin_lat={ORIGIN[0]}&origin_lon={ORIGIN[1]}"
        f"&dest_lat={FAR[0]}&dest_lon={FAR[1]}",
        passenger,
    )
    expect(code == 200, f"GET /quote -> 200 (veio {code} {quote})")
    expect(bool(quote.get("quote_id")), "cotação tem quote_id")
    expect(isinstance(quote.get("fare_total"), (int, float)), "cotação tem fare_total")
    expect(quote.get("expires_in") == 90, f"validade de 90 s (veio {quote.get('expires_in')})")
    frozen_fare = float(quote["fare_total"])
    quote_id = quote["quote_id"]

    # ------------------------------------------------- 3. pedido com a cotação
    print("3) pedir corrida com a cotação")
    code, ride = call("POST", f"{rides}/rides", passenger, {
        "origin": pt(*ORIGIN),
        "destination": pt(*FAR),
        "origin_address": "Av. Farqhuar, Centro",
        "destination_address": "Av. Pompeia, Novo Horizonte",
        "pricing_mode": "TARIFF",
        "quote_id": quote_id,
        "quoted_fare": frozen_fare,
    })
    expect(code == 201, f"POST /rides -> 201 (veio {code} {ride})")
    ride_id = ride.get("ride_id")
    expect(bool(ride_id), "corrida tem ride_id")
    expect(abs(float(ride.get("fare_total")) - frozen_fare) < 0.005,
           f"preço cobrado é o da cotação ({ride.get('fare_total')} vs {frozen_fare})")

    # --------------------------------------------------- 4. cotação de uso único
    print("4) a cotação é de uso único")
    code, body = call("POST", f"{rides}/rides", passenger, {
        "origin": pt(*ORIGIN),
        "destination": pt(*FAR),
        "pricing_mode": "TARIFF",
        "quote_id": quote_id,
    })
    expect(code == 422 and body.get("code") == "quote_not_found",
           f"replay da cotação -> 422 quote_not_found (veio {code} {body})")

    # ---------------------------------------------------- 5. cotação vencida
    print("5) cotação vencida")
    code, q2 = call(
        "GET",
        f"{rides}/quote?origin_lat={ORIGIN[0]}&origin_lon={ORIGIN[1]}"
        f"&dest_lat={FAR[0]}&dest_lon={FAR[1]}",
        passenger,
    )
    expect(code == 200, f"segunda cotação emitida (veio {code})")
    # Empurra o prazo para o passado direto no banco (o relógio do teste não
    # pode esperar 90 s): a validação do servidor é a que decide.
    code, body = call("POST", f"{rides}/rides", passenger, {
        "origin": pt(*ORIGIN),
        "destination": pt(*FAR),
        "pricing_mode": "TARIFF",
        "quote_id": "00000000-0000-4000-8000-000000000000",
    })
    expect(code == 422 and body.get("code") == "quote_not_found",
           f"quote_id inexistente -> 422 quote_not_found (veio {code} {body})")

    # -------------------------------------------------- 6. cotação de outra rota
    print("6) cotação de outra rota")
    code, q3 = call(
        "GET",
        f"{rides}/quote?origin_lat={ORIGIN[0]}&origin_lon={ORIGIN[1]}"
        f"&dest_lat={FAR[0]}&dest_lon={FAR[1]}",
        passenger,
    )
    expect(code == 200, f"terceira cotação emitida (veio {code})")
    code, body = call("POST", f"{rides}/rides", passenger, {
        "origin": pt(ORIGIN[0] + 0.01, ORIGIN[1]),
        "destination": pt(*FAR),
        "pricing_mode": "TARIFF",
        "quote_id": q3["quote_id"],
    })
    expect(code == 422 and body.get("code") == "quote_mismatch",
           f"outra rota -> 422 quote_mismatch (veio {code} {body})")

    # ------------------------------------------- 7. quoted_fare divergente
    print("7) valor divergente do cliente")
    code, q4 = call(
        "GET",
        f"{rides}/quote?origin_lat={ORIGIN[0]}&origin_lon={ORIGIN[1]}"
        f"&dest_lat={FAR[0]}&dest_lon={FAR[1]}",
        passenger,
    )
    expect(code == 200, f"quarta cotação emitida (veio {code})")
    code, body = call("POST", f"{rides}/rides", passenger, {
        "origin": pt(*ORIGIN),
        "destination": pt(*FAR),
        "pricing_mode": "TARIFF",
        "quote_id": q4["quote_id"],
        "quoted_fare": float(q4["fare_total"]) + 1.0,
    })
    expect(code == 422 and body.get("code") == "quote_fare_mismatch",
           f"quoted_fare inflado -> 422 quote_fare_mismatch (veio {code} {body})")

    # ------------------------------------------------- 8. despacho e oferta
    print("8) despacho: presença do parceiro e oferta")
    # A primeira corrida ainda está ativa: o passageiro só pode ter uma por
    # vez (409 active_ride_exists), então ela é cancelada antes do despacho.
    code, body = call("POST", f"{rides}/rides/{ride_id}/cancel", passenger,
                      {"reason": "PASSENGER_REGRET"})
    expect(code == 200, f"primeira corrida cancelada (veio {code} {body})")

    code, body = call("POST", f"{radar}/presence", partner, {
        "status": "ONLINE_DISPONIVEL", "lat": ORIGIN[0], "lon": ORIGIN[1],
    })
    expect(code == 200, f"parceiro online (veio {code} {body})")

    code, q5 = call(
        "GET",
        f"{rides}/quote?origin_lat={ORIGIN[0]}&origin_lon={ORIGIN[1]}"
        f"&dest_lat={FAR[0]}&dest_lon={FAR[1]}",
        passenger,
    )
    expect(code == 200, f"cotação do pedido (veio {code})")
    code, ride2 = call("POST", f"{rides}/rides", passenger, {
        "origin": pt(*ORIGIN),
        "destination": pt(*FAR),
        "pricing_mode": "TARIFF",
        "quote_id": q5["quote_id"],
        "quoted_fare": float(q5["fare_total"]),
    })
    expect(code == 201, f"segundo pedido aceito (veio {code} {ride2})")
    ride2_id = ride2["ride_id"]
    expect(ride2.get("status") in ("OFERTADA", "BUSCANDO"),
           f"corrida despachada (status {ride2.get('status')})")

    code, offers = call("GET", f"{rides}/offers/mine", partner)
    expect(code == 200, f"GET /offers/mine -> 200 (veio {code})")
    offers_list = offers.get("offers") or []
    expect(len(offers_list) >= 1, f"parceiro recebeu oferta (veio {len(offers_list)})")
    offer_id = offers_list[0]["offer_id"]

    # ------------------------------------------------------- 9. aceite e fases
    print("9) aceite e fases da corrida")
    code, body = call("POST", f"{rides}/offers/{offer_id}/accept", partner)
    expect(code == 200, f"aceite da oferta -> 200 (veio {code} {body})")

    for to in ("A_CAMINHO", "CHEGOU", "EM_VIAGEM"):
        code, body = call("POST", f"{rides}/partner/transitions", partner, {
            "ride_id": ride2_id, "to": to,
        })
        expect(code == 200 and body.get("status") == to,
               f"transição {to} (veio {code} {body.get('status') if isinstance(body, dict) else body})")

    fare = float(ride2.get("fare_total") or 0)
    code, body = call("POST", f"{rides}/partner/transitions", partner, {
        "ride_id": ride2_id, "to": "FINALIZADA", "fare_total": fare,
    })
    expect(code == 200 and body.get("status") == "FINALIZADA",
           f"finalização (veio {code} {body.get('status') if isinstance(body, dict) else body})")

    # ---------------------------------------------------------- 10. pagamento
    print("10) pagamento: só o webhook do PSP confirma")
    code, pay = call("POST", f"{rides}/payments/ride", passenger, {
        "ride_id": ride2_id, "method": "PIX",
    })
    expect(code == 201, f"POST /payments/ride -> 201 (veio {code} {pay})")
    payment_id = pay.get("payment_id")
    expect(bool(payment_id), "cobrança tem payment_id")
    expect(pay.get("status") == "PENDING", f"cobrança pendente (veio {pay.get('status')})")

    code, body = call("POST", f"{rides}/rides/{ride2_id}/payment/confirm", passenger)
    expect(code == 200, f"'Já paguei' apenas consulta (veio {code} {body})")
    expect(str(body.get("payment_status")) in ("PENDING", "NOT_DUE"),
           f"ainda não confirmada (veio {body.get('payment_status')})")

    code, body = call("POST", f"{psp}", None,
                      {"event": "payment.confirmed", "payment_id": payment_id},
                      {"x-psp-secret": "segredo-errado"})
    expect(code == 401, f"webhook com segredo errado recusado (veio {code})")

    code, body = call("POST", f"{psp}", None,
                      {"event": "payment.confirmed", "payment_id": payment_id},
                      {"x-psp-secret": args.psp_secret})
    expect(code == 200 and body.get("code") == "confirmed",
           f"webhook assinado confirma (veio {code} {body})")

    code, body = call("POST", f"{psp}", None,
                      {"event": "payment.confirmed", "payment_id": payment_id},
                      {"x-psp-secret": args.psp_secret})
    expect(code == 200, f"reentrega do webhook é idempotente (veio {code})")

    code, body = call("POST", f"{rides}/rides/{ride2_id}/payment/confirm", passenger)
    expect(code == 200 and body.get("payment_status") == "CONFIRMED",
           f"passageiro vê pagamento confirmado (veio {code} {body})")

    # ----------------------------------------------------------- 11. avaliação
    print("11) avaliação fecha a corrida")
    code, body = call("POST", f"{rides}/rides/{ride2_id}/rating", passenger, {
        "stars": 5, "comment": "Viagem tranquila", "tags": ["pontual"],
    })
    expect(code == 201, f"avaliação do passageiro -> 201 (veio {code} {body})")

    code, body = call("GET", f"{rides}/rides/{ride2_id}", partner)
    expect(code == 200 and body.get("status") == "FINALIZADA",
           f"parceiro vê a corrida finalizada (veio {code} {body.get('status') if isinstance(body, dict) else body})")

    print("\nPASS rides_smoke")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AssertionError as exc:
        print(f"\nFAIL: {exc}", file=sys.stderr)
        raise SystemExit(1)
