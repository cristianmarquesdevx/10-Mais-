#!/usr/bin/env python3
"""Memória persistente do projeto 10 é +.

Uso:
    python memory.py show
    python memory.py add "2026-11-01 — o que mudou — como foi verificado"
    python memory.py search termo
    python memory.py prune 40
"""

from __future__ import annotations

import datetime as dt
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]  # raiz do projeto
MEMORY = ROOT / ".opencode" / "memory" / "MEMORY.md"
ARCHIVE = ROOT / ".opencode" / "memory" / "archive"

TEMPLATE = """# Memória do projeto

## Estado atual
- (vazio)

## Decisões
- (vazio)

## Pendências
- [ ] (vazio)

## Histórico
"""


def ensure() -> None:
    if not MEMORY.exists():
        MEMORY.parent.mkdir(parents=True, exist_ok=True)
        MEMORY.write_text(TEMPLATE, encoding="utf-8")


def show() -> None:
    ensure()
    print(MEMORY.read_text(encoding="utf-8"))


def add(text: str) -> None:
    ensure()
    text = text.strip()
    if not text:
        raise SystemExit("texto vazio")
    if dt.date.today().isoformat() not in text:
        text = f"{dt.date.today().isoformat()} — {text}"
    body = MEMORY.read_text(encoding="utf-8").rstrip() + f"\n- {text}\n"
    MEMORY.write_text(body, encoding="utf-8")
    print(f"adicionado: {text}")


def search(term: str) -> None:
    ensure()
    needle = term.lower()
    hits = [ln for ln in MEMORY.read_text(encoding="utf-8").splitlines() if needle in ln.lower()]
    print("\n".join(hits) if hits else f"nada encontrado para: {term}")


def prune(keep: int) -> None:
    ensure()
    lines = MEMORY.read_text(encoding="utf-8").splitlines()
    try:
        start = lines.index("## Histórico")
    except ValueError:
        raise SystemExit("seção '## Histórico' não encontrada")
    head, hist = lines[: start + 1], [ln for ln in lines[start + 1:] if ln.strip()]
    if len(hist) <= keep:
        print(f"nada a podar ({len(hist)} entradas)")
        return
    old, kept = hist[:-keep], hist[-keep:]
    ARCHIVE.mkdir(parents=True, exist_ok=True)
    target = ARCHIVE / f"{dt.date.today().isoformat()}.md"
    target.write_text("\n".join(old) + "\n", encoding="utf-8")
    MEMORY.write_text("\n".join(head + kept) + "\n", encoding="utf-8")
    print(f"podado: {len(old)} entradas -> {target}")


def main() -> None:
    args = sys.argv[1:]
    if not args or args[0] == "show":
        show()
    elif args[0] == "add" and len(args) > 1:
        add(" ".join(args[1:]))
    elif args[0] == "search" and len(args) > 1:
        search(" ".join(args[1:]))
    elif args[0] == "prune":
        prune(int(args[1]) if len(args) > 1 else 40)
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main()
