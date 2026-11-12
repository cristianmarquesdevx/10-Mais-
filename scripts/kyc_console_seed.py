#!/usr/bin/env python3
"""Deixa um caso REAL na fila do KYC para a prova no emulador.

O smoke (`scripts/kyc_smoke.py`) termina com o caso APAGADO: ele existe para
provar o caminho inteiro e não pode deixar lixo. Mas a prova VISUAL do
console da operação precisa de uma fila com um caso de verdade — com
documento, com nome e com telefone — para a pessoa ver o que a operação
verá.

Este script faz o oposto do smoke: ele PREPARA a mesa e DEIXA o caso na
fila. Ele faz o mesmo caminho que o app do parceiro faz (abrir caso -> subir
o arquivo no bucket privado -> registrar o documento), com a imagem de um
documento SINTÉTICO (desenhado aqui — não é o documento de ninguém: é um
cartão de teste, para a tela ter o que mostrar).

O que ele NÃO faz: decidir. O caso fica IN_REVIEW, na fila, esperando a
operação.

Uso:
    export SUPABASE_JWT_SECRET=...        # npx supabase status -o env
    python scripts/kyc_console_seed.py

Exit 0 = a fila ficou pronta.
"""
from __future__ import annotations

import argparse
import io
import os
import sys
import time
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import contract  # noqa: E402
from kyc_smoke import call, service_token, user_token  # noqa: E402

# O parceiro de dev que ainda não submetiu o KYC (conta do seed).
PARCEIRO_KYC = "77777777-7777-4777-8777-777777777777"


def imagem_documento() -> bytes:
    """Um JPEG de documento SINTÉTICO (um cartão de teste).

    Não é o documento de ninguém: é um desenho com o formato do que a
    operação vai julgar (foto, número, validade). Serve para a prova
    visual do console — o que importa é o CAMINHO (bucket privado + RLS),
    não o conteúdo da foto.
    """
    try:
        from PIL import Image, ImageDraw
    except ImportError:  # pragma: no cover - host sem Pillow
        # Fallback: um JPEG 1x1. A tela mostra o documento, mas sem o
        # desenho do cartão.
        return bytes.fromhex("ffd8ffe000104a46494600010100000100010000ffd9")

    largura, altura = 1000, 640
    img = Image.new("RGB", (largura, altura), (238, 238, 234))
    draw = ImageDraw.Draw(img)

    # A moldura do cartão.
    draw.rectangle([20, 20, largura - 20, altura - 20],
                   outline=(40, 60, 58), width=4)
    draw.text((60, 50), "CARTAO DE TESTE - KYC", fill=(20, 60, 56))
    draw.text((60, 90), "Documento sintetico para a prova do console.",
              fill=(70, 90, 88))

    # A area da foto.
    draw.rectangle([60, 150, 360, 470], fill=(190, 195, 192),
                   outline=(40, 60, 58), width=3)
    draw.ellipse([150, 210, 270, 330], fill=(150, 156, 153))
    draw.ellipse([120, 330, 300, 470], fill=(150, 156, 153))

    # Os dados (inventados, de novo).
    linhas = [
        "NOME: PARCEIRO KYC DEV",
        "DOCUMENTO: 000.000.000-00",
        "NASCIMENTO: 01/01/1990",
        "VALIDADE: 01/01/2032",
        "CATEGORIA: A - MOTORIZADO",
    ]
    y = 170
    for linha in linhas:
        draw.text((420, y), linha, fill=(25, 45, 43))
        y += 48

    buf = io.BytesIO()
    img.save(buf, format="JPEG", quality=88)
    return buf.getvalue()


def sobe_objeto(base: str, bucket: str, path: str, jwt: str, dados: bytes) -> int:
    """Sobe o arquivo no bucket privado pelo REST do Storage."""
    url = f"{base}/storage/v1/object/{bucket}/{path}"
    req = urllib.request.Request(url, data=dados, method="POST")
    req.add_header("authorization", f"Bearer {jwt}")
    req.add_header("content-type", "image/jpeg")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            resp.read()
            return resp.status
    except urllib.error.HTTPError as exc:
        corpo = exc.read().decode("utf-8", errors="replace")
        print(f"upload recusado ({exc.code}): {corpo}", file=sys.stderr)
        return exc.code


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="http://127.0.0.1:54321")
    args = ap.parse_args()

    secret = os.environ.get("SUPABASE_JWT_SECRET", "")
    if not secret:
        print("SUPABASE_JWT_SECRET ausente", file=sys.stderr)
        return 2

    api = args.base
    kyc = f"{api}/functions/v1/kyc"
    bucket = contract.KYC_STORAGE_BUCKET
    svc = service_token(secret)
    parceiro = user_token(PARCEIRO_KYC, secret)

    # A faxina: um caso anterior desta mesma conta sairia da fila e o
    # console mostraria dois cadastros do MESMO parceiro.
    call("DELETE", f"{api}/rest/v1/kyc_cases?partner_user_id=eq.{PARCEIRO_KYC}",
         svc, None, {"apikey": svc})
    call("PATCH", f"{api}/rest/v1/partners?user_id=eq.{PARCEIRO_KYC}", svc,
         {"kyc_status": "NOT_STARTED"}, {"apikey": svc, "Prefer": "return=minimal"})

    # 1. O parceiro abre o caso (o mesmo caminho do app).
    status, body, _ = call("POST", f"{kyc}/cases", parceiro,
                           {"idempotency_key": f"seed-{int(time.time())}"})
    if status not in (200, 201):
        print(f"o caso nao abriu ({status}): {body}", file=sys.stderr)
        return 1
    case_id = body["case_id"]
    print(f"caso aberto: {case_id} (status {body.get('status')})")

    # 2. O arquivo sobe no bucket privado, na pasta do DONO.
    stamp = int(time.time() * 1000)
    path = (f"{contract.KYC_STORAGE_PATH_PREFIX}/{PARCEIRO_KYC}/{case_id}"
            f"/CNH_{stamp}.jpg")
    dados = imagem_documento()
    status = sobe_objeto(api, bucket, path, parceiro, dados)
    if status not in (200, 201):
        print("o arquivo nao subiu no bucket", file=sys.stderr)
        return 1
    print(f"arquivo no bucket: {path} ({len(dados)} bytes)")

    # 3. O parceiro registra o documento (o servidor confere o objeto).
    status, body, _ = call("POST", f"{kyc}/cases/{case_id}/documents", parceiro,
                           {"doc_type": "CNH", "storage_path": path})
    if status not in (200, 201):
        print(f"o documento nao foi registrado ({status}): {body}",
              file=sys.stderr)
        return 1
    print(f"documento registrado (status {body.get('status')})")

    # 4. A operação enxerga o caso na fila, com nome e telefone.
    agente = user_token("66666666-6666-4666-8666-666666666666", secret)
    status, body, _ = call("GET", f"{kyc}/queue", agente)
    caso = next((c for c in (body.get("cases") or [])
                 if c.get("case_id") == case_id), None)
    if caso is None:
        print("o caso nao apareceu na fila da operacao", file=sys.stderr)
        return 1
    print(f"fila da operacao: posicao {caso.get('position')}, "
          f"{caso.get('partner_name')} ({caso.get('partner_phone')})")

    print("PRONTO — a fila do KYC esta com um caso de verdade, "
          "aguardando a decisao.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
