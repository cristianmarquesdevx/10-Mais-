#!/usr/bin/env python3
"""Smoke do radar REAL (Supabase local).

Valida, contra a Edge Function `radar`:
  1. parceiro autenticado entra ONLINE_DISPONIVEL com posição real;
  2. passageiro autenticado vê 1 motorista aproximado (id pseudônimo);
  3. fora do raio, não vê ninguém;
  4. parceiro OFFLINE desaparece na hora;
  5. sem token, a função recusa.

Uso:
  export SUPABASE_JWT_SECRET=...        # npx supabase status -o env
  python scripts/radar_smoke.py [--base http://127.0.0.1:54321/functions/v1/radar]

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

ORIGIN = (-8.7607, -63.9039)
FAR = (-8.7920, -63.9300)  # ~4 km a sudoeste do Centro


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


def call(method: str, url: str, jwt: str | None, body: dict | None = None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("content-type", "application/json")
    if jwt:
        req.add_header("authorization", f"Bearer {jwt}")
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
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


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="http://127.0.0.1:54321/functions/v1/radar")
    args = ap.parse_args()

    secret = os.environ.get("SUPABASE_JWT_SECRET", "")
    if not secret:
        print("SUPABASE_JWT_SECRET ausente", file=sys.stderr)
        return 2

    partner = token("partner", secret)
    passenger = token("passenger", secret)

    def presence(status: str, lat: float | None = None, lon: float | None = None) -> None:
        code, payload = call(
            "POST",
            f"{args.base}/presence",
            partner,
            {"status": status, "lat": lat, "lon": lon},
        )
        expect(code == 200, f"presence {status} -> 200 (veio {code} {payload})")

    def nearby(lat: float, lon: float, radius_km: float):
        qs = urllib.parse.urlencode({"lat": lat, "lon": lon, "radius_km": radius_km})
        code, payload = call("GET", f"{args.base}/nearby?{qs}", passenger)
        expect(code == 200, f"nearby -> 200 (veio {code} {payload})")
        return payload

    print("1) sem token")
    code, _ = call("GET", f"{args.base}/nearby?lat=-8.76&lon=-63.90", None)
    expect(code in (401, 403), f"sem JWT recusado (veio {code})")

    print("2) parceiro online no Centro")
    presence("ONLINE_DISPONIVEL", *ORIGIN)
    payload = nearby(*ORIGIN, 5)
    expect(len(payload["drivers"]) == 1, f"1 motorista por perto (veio {len(payload['drivers'])})")
    d = payload["drivers"][0]
    expect(d["driver_id"].startswith("p_"), "id do motorista é pseudônimo")
    expect(len(str(d["lat"]).split(".")[-1]) <= 3, "posição vem snapada (~110 m)")
    expect(d["distance_km"] >= 0, "distância arredondada presente")
    expect(payload["eligible_count"] >= 1, "contador de elegíveis >= 1")

    print("3) fora do raio")
    payload = nearby(*FAR, 1.0)
    expect(payload["drivers"] == [], "a 4 km com raio 1 km não aparece ninguém")

    print("4) offline desaparece")
    presence("OFFLINE")
    payload = nearby(*ORIGIN, 5)
    expect(payload["drivers"] == [], "offline não aparece no radar")

    print("5) posição inválida é recusada")
    code, body = call("POST", f"{args.base}/presence", partner,
                      {"status": "ONLINE_DISPONIVEL", "lat": 999, "lon": 0})
    expect(code == 422 and body.get("code") == "invalid_position",
           f"lat inválida -> 422 invalid_position (veio {code} {body})")

    print("\nPASS radar_smoke")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AssertionError as exc:
        print(f"\nFAIL: {exc}", file=sys.stderr)
        raise SystemExit(1)
