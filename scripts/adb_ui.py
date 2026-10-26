#!/usr/bin/env python3
"""Utilitário mínimo de UI Android para o smoke E2E dos apps 10 é +.

Usa `uiautomator dump` (Flutter expõe os rótulos em content-desc) para
listar textos e tocar em elementos por substring. Não é um framework de
teste: serve para conduzir o fluxo no emulador e capturar evidências.

Uso:
    python scripts/adb_ui.py list
    python scripts/adb_ui.py tap "CONTINUAR"
    python scripts/adb_ui.py tap-edit 0
    python scripts/adb_ui.py type "69999999999"
    python scripts/adb_ui.py shot caminho.png
"""
from __future__ import annotations

import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
from pathlib import Path

ADB = "adb"


def adb(*args: str, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(
        [ADB, *args], check=check, capture_output=True, text=True,
        encoding="utf-8", errors="replace",
    )


def dump() -> ET.Element:
    # Remove o arquivo anterior: se o uiautomator falhar em pegar o idle,
    # um XML antigo faria o helper tocar na tela errada silenciosamente.
    adb("shell", "rm", "-f", "/sdcard/ui.xml", check=False)
    out = adb("shell", "uiautomator", "dump", "/sdcard/ui.xml")
    if "dumped" not in (out.stdout + out.stderr).lower():
        raise SystemExit(f"uiautomator dump falhou: {out.stdout} {out.stderr}")
    raw = adb("exec-out", "cat", "/sdcard/ui.xml").stdout
    return ET.fromstring(raw)


def bounds(node: ET.Element) -> tuple[int, int, int, int]:
    x1, y1, x2, y2 = map(int, re.findall(r"-?\d+", node.attrib["bounds"]))
    return x1, y1, x2, y2


def nodes(root: ET.Element):
    for node in root.iter("node"):
        label = (node.attrib.get("content-desc") or node.attrib.get("text") or "").strip()
        if label:
            x1, y1, x2, y2 = bounds(node)
            yield label, (x1 + x2) // 2, (y1 + y2) // 2


def list_nodes() -> None:
    for label, x, y in nodes(dump()):
        print(f"{x:4d},{y:4d}  {label}")


def find(substr: str) -> tuple[int, int] | None:
    needle = substr.lower()
    for label, x, y in nodes(dump()):
        if needle in label.lower():
            return x, y
    return None


def tap(substr: str, timeout: float = 10.0) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        pos = find(substr)
        if pos:
            adb("shell", "input", "tap", str(pos[0]), str(pos[1]))
            print(f"tap {substr!r} @ {pos}")
            return
        time.sleep(0.5)
    raise SystemExit(f"não encontrei {substr!r} na tela")


def tap_edit(index: int = 0) -> None:
    """Toca o N-ésimo campo de texto (EditText) visível — o Flutter não
    expõe o campo como rótulo, então é por classe.
    """
    fields = []
    for node in dump().iter("node"):
        if node.attrib.get("class", "").endswith("EditText"):
            x1, y1, x2, y2 = bounds(node)
            fields.append(((x1 + x2) // 2, (y1 + y2) // 2))
    if index >= len(fields):
        raise SystemExit(f"não encontrei o campo de texto #{index} (achei {len(fields)})")
    x, y = fields[index]
    adb("shell", "input", "tap", str(x), str(y))
    print(f"tap campo de texto #{index} @ {(x, y)}")


def type_text(text: str) -> None:
    adb("shell", "input", "text", text.replace(" ", "%s"))
    print(f"type {text!r}")


def shot(path: str) -> None:
    data = subprocess.run([ADB, "exec-out", "screencap", "-p"],
                          check=True, capture_output=True).stdout
    Path(path).write_bytes(data)
    print(f"screenshot {path}")


if __name__ == "__main__":
    # Console do Windows costuma ser cp1252: não deixe um "≈" ou "★"
    # derrubar o utilitário no meio do fluxo.
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    cmd = sys.argv[1] if len(sys.argv) > 1 else "list"
    if cmd == "list":
        list_nodes()
    elif cmd == "tap":
        tap(sys.argv[2])
    elif cmd == "type":
        type_text(sys.argv[2])
    elif cmd == "tap-edit":
        tap_edit(int(sys.argv[2]) if len(sys.argv) > 2 else 0)
    elif cmd == "shot":
        shot(sys.argv[2])
    elif cmd == "wait":
        tap(sys.argv[2], timeout=float(sys.argv[3]) if len(sys.argv) > 3 else 30)
    else:
        raise SystemExit(__doc__)
