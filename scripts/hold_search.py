#!/usr/bin/env python3
"""Segura a tela de busca com motorista no radar e vigia o emulador.

O pino só aparece enquanto a presença do parceiro está fresca (o servidor
considera o parceiro fora do radar depois de 90 s sem heartbeat). Com
`--keep-online` o script reenvia a presença a cada 20 s, para a tela ficar
de fato "com motorista próximo" durante toda a espera.
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
import urllib.request

PKG = "app.dezemais.passageiro"
BASE = "http://127.0.0.1:8790"


def adb(*args: str, timeout: float = 25) -> str:
    try:
        out = subprocess.run(["adb", *args], capture_output=True, text=True,
                             encoding="utf-8", errors="replace", timeout=timeout)
    except subprocess.TimeoutExpired:
        return "timeout"
    return (out.stdout or "").strip()


def frames_stats() -> str:
    """Carga do app: o gfxinfo do Flutter não conta quadro, o top conta CPU."""
    raw = adb("shell", "top", "-b", "-n", "1", "-q", "-o", "PID,%CPU,ARGS")
    for line in raw.splitlines():
        if "passageiro" in line and not line.strip().startswith("PID"):
            return "cpu " + " ".join(line.split()[:2]) + "%"
    raw = adb("shell", "top", "-b", "-n", "1")
    for line in raw.splitlines():
        if "passageiro" in line:
            parts = line.split()
            return f"cpu {parts[2]}%" if len(parts) > 2 else "cpu ?"
    return "cpu ?"


def presence() -> str:
    """Reenvia a presença do parceiro e diz quantos o radar enxerga."""
    body = b'{"lat": -8.7607, "lon": -63.9039}'
    req = urllib.request.Request(BASE + "/partner/online", data=body,
                                 method="POST",
                                 headers={"content-type": "application/json"})
    with urllib.request.urlopen(req, timeout=8) as resp:
        resp.read()
    with urllib.request.urlopen(
        BASE + "/partners/nearby?lat=-8.7607&lon=-63.9039&radius_km=5",
        timeout=8,
    ) as resp:
        data = json.loads(resp.read().decode("utf-8"))
    return str(data.get("eligible_count"))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--hold", type=float, default=210)
    ap.add_argument("--keep-online", action="store_true")
    args = ap.parse_args()
    started = time.monotonic()
    next_presence = 0.0
    while time.monotonic() - started < args.hold:
        elapsed = time.monotonic() - started
        drivers = None
        if args.keep_online and time.monotonic() >= next_presence:
            try:
                drivers = presence()
            except Exception as exc:  # API fora do ar não é queda do AVD
                drivers = f"api? {exc}"
            next_presence = time.monotonic() + 20
        time.sleep(10)
        state = adb("get-state") or "ausente"
        if state != "device":
            print(f"t+{elapsed:4.0f}s  adb={state}  EMULADOR CAIU", flush=True)
            return 1
        extra = f"  radar={drivers}" if drivers is not None else ""
        print(f"t+{elapsed:4.0f}s  adb=device{extra}  {frames_stats()}",
              flush=True)
    print("segurou até o fim", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
