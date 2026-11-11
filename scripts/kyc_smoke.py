#!/usr/bin/env python3
"""Smoke do KYC contra o backend real (Supabase local).

Este é o teste que fecha o "bloco 1" do KYC: o mesmo caminho que o app do
parceiro faz (abrir caso -> fila da operação -> recusa -> reenvio ->
aprovação), contra o Postgres + a Edge Function `kyc` de verdade — não a API
de demonstração, que aprovava tudo na hora.

Valida, na ordem:

   1. sem token, tudo é recusado (401);
   2. o parceiro novo abre o caso -> IN_REVIEW, com POSIÇÃO na fila e SLA;
   3. a mesma `Idempotency-Key` devolve o MESMO caso (replay não duplica);
   4. o parceiro não enxerga o caso de outro nem a fila da operação (403);
   5. a operação (papel AGENT) vê a fila e decide;
   6. recusa sem motivo padronizado é recusada (422);
   7. a recusa libera o reenvio do documento (RESUBMIT) e o caso volta à fila;
   8. a aprovação muda `partners.kyc_status` para APPROVED — o gate do app
      (só parceiro aprovado fica online) passa a valer;
   9. o rastro existe: `audit_log`, notificação e evento `kyc.decided`.

O SLA é conferido no SERVIDOR: o prazo tem de cair dentro da janela humana
de revisão (7h-23h no fuso da praça) e respeitar a antecedência mínima.

Uso:
    export SUPABASE_JWT_SECRET=...        # npx supabase status -o env
    python scripts/kyc_smoke.py

Exit 0 = PASS. Qualquer assert falha com mensagem e exit 1.
"""
from __future__ import annotations

import argparse
import datetime
import json
import os
import sys
import time
import urllib.error
import urllib.request
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from dev_jwt import sign  # noqa: E402

# Fuso da praça piloto. Porto Velho é UTC-4 o ano inteiro (o Brasil acabou
# com o horário de verão em 2019); se o `zoneinfo` estiver disponível no
# host, ele é usado — o fallback fixo é só para o caso de faltar o tzdata.
CITY_TZ = "America/Porto_Velho"
CITY_TZ_FALLBACK_OFFSET_H = -4


def user_token(sub: str, secret: str, ttl: int = 600) -> str:
    now = int(time.time())
    return sign(
        {
            "sub": sub,
            "role": "authenticated",
            "aud": "authenticated",
            "iss": "supabase",
            "iat": now,
            "exp": now + ttl,
        },
        secret,
    )


def service_token(secret: str) -> str:
    """Chave `service_role` do stack LOCAL, derivada do JWT secret.

    É o mesmo valor que a CLI grava no container (HS256 sobre
    {"iss":"supabase-demo","role":"service_role","exp":1983812996}): é
    derivado, não copiado — nenhum segredo de produção entra no repositório.
    Serve só para o setup/teardown do smoke (conta de teste e conferência do
    rastro); o caminho do produto nunca usa service role.
    """
    return sign(
        {"iss": "supabase-demo", "role": "service_role", "exp": 1983812996},
        secret,
    )


def call(method: str, url: str, jwt: str | None = None, body: dict | None = None,
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
            return resp.status, (json.loads(raw) if raw else {}), dict(resp.headers)
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8")
        try:
            return exc.code, json.loads(raw), dict(exc.headers)
        except json.JSONDecodeError:
            return exc.code, {"raw": raw}, dict(exc.headers)


def expect(cond: bool, label: str) -> None:
    if not cond:
        raise AssertionError(label)
    print(f"  ok  {label}")


def header(headers: dict, name: str) -> str | None:
    """Cabeçalho sem depender da caixa (o Kong normaliza para minúsculas)."""
    low = name.lower()
    for key, value in headers.items():
        if key.lower() == low:
            return value
    return None


def parse_iso(value: str) -> float:
    """ISO-8601 com offset -> epoch (sem depender de dateutil)."""
    text = value.replace("Z", "+00:00")
    import datetime as dt

    return dt.datetime.fromisoformat(text).timestamp()


def local_hour(epoch: float) -> int:
    """Hora local na praça (0..23)."""
    try:
        from datetime import datetime, timezone
        from zoneinfo import ZoneInfo

        return datetime.fromtimestamp(epoch, tz=ZoneInfo(CITY_TZ)).hour
    except Exception:  # noqa: BLE001 - sem tzdata no host: offset fixo do Brasil
        import datetime as dt

        return (dt.datetime.fromtimestamp(epoch, tz=dt.timezone.utc)
                + dt.timedelta(hours=CITY_TZ_FALLBACK_OFFSET_H)).hour


def reset_partner(base: str, svc: str, user_id: str) -> None:
    """Zera o caso do parceiro de dev (o smoke é repetível).

    A fila do KYC é do BANCO, não do GoTrue: sem esta faxina, uma execução
    anterior deixaria o caso na fila e o smoke falharia por um motivo que não
    é do produto. A auditoria e os eventos ficam: são append-only por
    desenho (é esse o ponto deles).
    """
    call("DELETE", f"{base}/rest/v1/kyc_cases?partner_user_id=eq.{user_id}",
         svc, None, {"apikey": svc})
    call("PATCH", f"{base}/rest/v1/partners?user_id=eq.{user_id}", svc,
         {"kyc_status": "NOT_STARTED"}, {"apikey": svc, "Prefer": "return=minimal"})


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="http://127.0.0.1:54321")
    args = ap.parse_args()

    secret = os.environ.get("SUPABASE_JWT_SECRET", "")
    if not secret:
        print("SUPABASE_JWT_SECRET ausente", file=sys.stderr)
        return 2

    api = f"{args.base}"
    kyc = f"{api}/functions/v1/kyc"
    rides = f"{api}/functions/v1/rides"
    rest = f"{api}/rest/v1"
    svc = service_token(secret)

    # O parceiro de dev que ainda não submetiu o KYC (conta do seed).
    user_id = "77777777-7777-4777-8777-777777777777"
    partner = user_token(user_id, secret)
    # O AGENT de desenvolvimento é a operação: enxerga a fila e decide.
    agent = user_token("66666666-6666-4666-8666-666666666666", secret)
    outro = user_token("22222222-2222-4222-8222-222222222222", secret)

    reset_partner(api, svc, user_id)
    # Sem offset '+00:00' na URL: o '+' vira espaço e o Postgres recusa o
    # timestamp. O 'Z' é o mesmo instante e não precisa de escape.
    run_start = datetime.datetime.now(datetime.timezone.utc).strftime(
        "%Y-%m-%dT%H:%M:%SZ")
    try:
        # ------------------------------------------------------------ 1. auth
        print("1) sem token")
        status, body, _ = call("POST", f"{kyc}/cases", None, {})
        expect(status in (401, 403),
               f"sem token -> recusado na porta (veio {status})")
        # Token bem formado de quem NÃO existe: aí quem recusa é a própria
        # função (ela confere a identidade no GoTrue antes de tocar no banco).
        fantasma = user_token(str(uuid.uuid4()), secret)
        status, body, _ = call("POST", f"{kyc}/cases", fantasma, {})
        expect(status == 401 and body.get("code") == "unauthenticated",
               f"token de usuário inexistente -> 401 da função (veio {status} {body})")

        # ---------------------------------------------------- 2. abrir o caso
        print("2) parceiro novo abre o caso")
        idem = str(uuid.uuid4())
        status, body, headers = call(
            "POST", f"{kyc}/cases", partner, {}, {"idempotency-key": idem})
        expect(status == 201, f"POST /cases -> 201 (veio {status} {body})")
        case_id = body.get("case_id")
        expect(body.get("status") == "IN_REVIEW",
               f"status IN_REVIEW (veio {body.get('status')})")
        expect(isinstance(body.get("position"), int) and body["position"] >= 1,
               f"posição na fila >= 1 (veio {body.get('position')})")
        expect(bool(body.get("sla")), "SLA informado")
        sla_epoch = parse_iso(body["sla"])
        agora = time.time()
        expect(sla_epoch >= agora + 1.9 * 3600,
               "o SLA respeita a antecedência mínima (2 h)")
        hora = local_hour(sla_epoch)
        expect(7 <= hora < 23,
               f"o SLA cai dentro da janela humana 7h-23h (hora local {hora})")

        # -------------------------------------------------------- 3. idempotência
        print("3) replay da Idempotency-Key")
        status, body2, headers2 = call(
            "POST", f"{kyc}/cases", partner, {}, {"idempotency-key": idem})
        expect(status == 201, f"replay -> 201 (veio {status})")
        expect(body2.get("case_id") == case_id,
               "o replay devolve o MESMO caso (não duplica a fila)")
        expect(header(headers2, "Idempotency-Replayed") == "true",
               "o replay é marcado no cabeçalho")

        # ------------------------------------------------- 4. isolamento (403)
        print("4) isolamento entre parceiros e operação")
        status, body, _ = call("GET", f"{kyc}/cases/{case_id}", outro)
        expect(status == 403, f"outro parceiro não vê o caso (veio {status})")
        status, body, _ = call("GET", f"{kyc}/queue", partner)
        expect(status == 403, f"parceiro não vê a fila (veio {status})")
        status, body, _ = call("GET", f"{kyc}/queue", agent)
        expect(status == 200, f"agente vê a fila (veio {status})")
        casos = body.get("cases") or []
        expect(any(c.get("case_id") == case_id for c in casos),
               "o caso novo está na fila da operação")

        # --------------------------------------------- 5. decisão da operação
        print("5) decisão da operação")
        status, body, _ = call("POST", f"{kyc}/cases/{case_id}/review", agent,
                               {"decision": "REJECTED"})
        expect(status == 422 and body.get("code") == "rejection_code_required",
               f"recusa sem motivo é recusada (veio {status} {body})")

        status, body, _ = call("POST", f"{kyc}/cases/{case_id}/review", agent,
                               {"decision": "REJECTED", "rejection_code": "CNH_ILEGIVEL",
                                "note": "documento ilegível"})
        expect(status == 200 and body.get("status") == "REJECTED",
               f"recusa registrada (veio {status} {body})")
        status, body, _ = call("GET", f"{kyc}/cases/{case_id}", partner)
        expect(body.get("rejection_code") == "CNH_ILEGIVEL",
               "o parceiro vê o motivo padronizado da recusa")

        # ------------------------------------------------------- 6. reenvio
        print("6) reenvio da documentação")
        status, body, _ = call("POST", f"{kyc}/cases/{case_id}/documents", partner,
                               {"doc_type": "CNH"})
        expect(status == 201, f"POST /documents -> 201 (veio {status} {body})")
        expect(body.get("status") == "RESUBMIT",
               f"o caso volta para a fila como RESUBMIT (veio {body.get('status')})")
        expect(isinstance(body.get("position"), int),
               "o caso reenviado tem posição na fila")

        # ----------------------------------------------------- 7. aprovação
        print("7) aprovação")
        status, body, _ = call("POST", f"{kyc}/cases/{case_id}/review", agent,
                               {"decision": "APPROVED", "note": "ok"})
        expect(status == 200 and body.get("status") == "APPROVED",
               f"aprovação registrada (veio {status} {body})")
        expect(body.get("partner_kyc_status") == "APPROVED",
               "o status do parceiro passa a APPROVED")

        status, body, _ = call("GET", f"{rides}/me", partner)
        expect(status == 200, f"GET /me do parceiro (veio {status})")
        expect((body.get("partner") or {}).get("kyc_status") == "APPROVED",
               "o gate do app abre: o parceiro aprovado pode ficar online")

        # -------------------------------------------------------- 8. rastro
        print("8) rastro (auditoria, notificação, evento)")
        # O filtro é por instante: sem ele, o rastro da execução ANTERIOR
        # faria a asserção passar mesmo sem notificação nesta.
        status, body, _ = call(
            "GET", f"{rest}/audit_log?entity_id=eq.{case_id}&action=eq.KYC_DECIDED"
                   f"&created_at=gte.{run_start}&select=action",
            svc, None, {"apikey": svc})
        expect(status == 200 and len(body) >= 2,
               f"a auditoria tem a recusa e a aprovação (veio {status} {body})")

        status, body, _ = call(
            "GET", f"{rest}/notifications?user_id=eq.{user_id}&type=eq.KYC_DECIDED"
                   f"&created_at=gte.{run_start}&select=type",
            svc, None, {"apikey": svc})
        expect(status == 200 and len(body) >= 2,
               f"o parceiro foi notificado da decisão (veio {status} {body})")

        status, body, _ = call(
            "GET", f"{rest}/ride_events?event_type=eq.kyc.decided"
                   f"&occurred_at=gte.{run_start}&select=event_type,payload",
            svc, None, {"apikey": svc})
        eventos = [e for e in body if e.get("payload", {}).get("status") in
                   ("REJECTED", "APPROVED")]
        expect(status == 200 and len(eventos) >= 2,
               f"o evento kyc.decided foi emitido (veio {status} {len(eventos)})")
    except AssertionError as exc:
        print(f"FALHOU: {exc}", file=sys.stderr)
        return 1
    finally:
        reset_partner(api, svc, user_id)
        print("caso de teste removido")

    print("PASS — KYC no Postgres: fila, SLA, recusa, reenvio e aprovação")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
