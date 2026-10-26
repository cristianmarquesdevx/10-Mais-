#!/usr/bin/env python3
"""Gera um JWT de DESENVOLVIMENTO para o Supabase local.

O segredo é o mesmo que o `supabase start` imprime (JWT secret). Não use isto
fora da máquina de desenvolvimento: em produção o token vem do fluxo de login
(OTP) e é assinado pelo GoTrue.

Uso:
    export SUPABASE_JWT_SECRET="$(npx supabase status -o env | sed -n 's/^JWT_SECRET="\\(.*\\)"$/\\1/p')"
    python scripts/dev_jwt.py --role partner
    python scripts/dev_jwt.py --role passenger --ttl 7200
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import json
import os
import sys
import time

DEV_USERS = {
    "passenger": "11111111-1111-4111-8111-111111111111",
    "partner": "22222222-2222-4222-8222-222222222222",
}


def b64url(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


def sign(payload: dict, secret: str) -> str:
    header = {"alg": "HS256", "typ": "JWT"}
    h = b64url(json.dumps(header, separators=(",", ":")).encode())
    p = b64url(json.dumps(payload, separators=(",", ":")).encode())
    sig = hmac.new(secret.encode(), f"{h}.{p}".encode(), hashlib.sha256).digest()
    return f"{h}.{p}.{b64url(sig)}"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--role", choices=sorted(DEV_USERS), default="passenger")
    ap.add_argument("--sub", help="sobrepõe o sub do usuário de dev")
    ap.add_argument("--ttl", type=int, default=3600, help="validade em segundos")
    ap.add_argument("--secret", default=os.environ.get("SUPABASE_JWT_SECRET", ""))
    args = ap.parse_args()

    if not args.secret:
        print(
            "SUPABASE_JWT_SECRET vazio. Rode:\n"
            "  export SUPABASE_JWT_SECRET=\"$(npx supabase status -o env "
            "| sed -n 's/^JWT_SECRET=\"\\(.*\\)\"$/\\1/p')\"",
            file=sys.stderr,
        )
        return 2

    now = int(time.time())
    payload = {
        "sub": args.sub or DEV_USERS[args.role],
        "role": "authenticated",
        "aud": "authenticated",
        "iss": "supabase",
        "iat": now,
        "exp": now + args.ttl,
    }
    print(sign(payload, args.secret))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
