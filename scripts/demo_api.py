#!/usr/bin/env python3
"""API de DEMONSTRAÇÃO — 10 é + (não é o backend real).

Implementa, em memória e com CORS, os endpoints do docs/fase2/openapi.yaml
usados pelos apps Flutter web (app/passageiro e app/parceiro) para que os
dois rodem juntos localmente e o fluxo completo possa ser VISTO:

  passageiro pede corrida → parceiro ONLINE recebe oferta (poll /offers/mine)
  → aceita → transições A_CAMINHO/CHEGOU/EM_VIAGEM → finaliza (dinheiro)
  → passageiro vê cada fase (poll de fallback) → paga PIX → avalia.

O aceite automático é OPCIONAL: só existe com DEMO_MODE=1 (e a UI de demo
deve rotulá-lo). Em modo normal, ninguém aceita sozinho — a corrida espera um
parceiro real. O radar (/partners/nearby) NÃO é servido aqui: ele vive na Edge
Function `radar` do Supabase, com presença real do app do parceiro.

Uso:
    python3 scripts/demo_api.py [--port 8787]

ATENÇÃO: servidor de demo (estado em memória, sem auth real, sem ledger).
O backend de produção são Supabase Edge Functions conforme o contrato.
"""
from __future__ import annotations

import argparse
import hashlib
import math
import os
import re
import json
import sys
import threading
import time
import uuid
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import urllib.parse
import urllib.request
from urllib.parse import urlparse, parse_qs

try:  # rodando como script (scripts/ no sys.path) ou como pacote
    import dispatch as dispatch_engine
    from dispatch import Candidate
except ImportError:  # pragma: no cover
    from scripts import dispatch as dispatch_engine
    from scripts.dispatch import Candidate

LOCK = threading.Lock()

# Relógio deslocável: DESLIGADO por padrão. Sem esta flag o endpoint
# /demo/clock responde 403 e o servidor se comporta como sempre.
TIME_TRAVEL = os.environ.get("DEMO_TIME_TRAVEL", "0") == "1"
MAX_CLOCK_OFFSET_S = 31 * 86400
# Deslocamento do relógio (segundos). Vive fora do STATE porque o STATE usa
# now() para nascer (pass_expires_at).
CLOCK_OFFSET = 0.0
# Nota do parceiro: no backend real vive na linha do parceiro, não na
# presença. Fica aqui para a nota sobreviver a sair/voltar do online — senão
# cada sessão recomeçava em 4,9/301 e as avaliações da semana se perdiam.
PROFILE_RATING = {"value": 4.9, "count": 301}

def now() -> float:
    # Relógio da demo: 0 em uso normal. O roteiro de demonstração
    # (scripts/demo_week.py) só desloca com --time-travel, para ensaiar dias
    # inteiros sem esperar dias inteiros.
    return time.time() + CLOCK_OFFSET

def iso(ts: float | None = None) -> str:
    return datetime.fromtimestamp(ts or now(), tz=timezone.utc).isoformat().replace("+00:00", "Z")

def new_id() -> str:
    return str(uuid.uuid4())

def scratch_ticket_view(ticket: dict) -> dict:
    """Ticket no formato consumido por ScratchTicket.fromJson (3.8)."""
    return {
        "id": ticket["id"],
        "campaign_id": ticket["campaign_id"],
        "user_id": ticket["user_id"],
        "prize_id": ticket["prize_id"],
        "result": ticket["result"],
        "status": ticket["status"],
        "scratched_at": ticket["scratched_at"],
        "redeemed_at": ticket["redeemed_at"],
        "created_at": ticket["created_at"],
    }

# ---------------------------------------------------------------------------
# Estado em memória (uma praça, um parceiro, N passageiros)
# ---------------------------------------------------------------------------

STATE = {
    "rides": {},          # ride_id -> dict
    "offers": {},         # offer_id -> dict
    "geo_cache": {},      # query normalizada -> resultado (cache do Nominatim)
    "road_cache": {},     # origem/destino -> km rodoviário (cache do OSRM)
    "path_cache": {},     # origem/destino -> geometria da rota (percurso do parceiro)
    # Presença dos parceiros REAIS (POST /partner/online e heartbeat), por
    # driver_id. O app do parceiro é "self"; os testes de despacho registram
    # outros ids. O radar e o despacho leem daqui — nunca de lista inventada.
    "presences": {},
    # Estado do despacho por corrida: rodada, raio, já ofertados, cooldown.
    "dispatch": {},
    # Desempenho do parceiro: driver_id -> "YYYY-MM-DD" -> contadores do dia
    # (chamadas, aceites, recusas, tempo online, posição no ranking, notas).
    # Alimentado pelos eventos reais do despacho, nunca por número inventado.
    "perf": {},
    "recordings": [],     # gravações de segurança (áudio passageiro / vídeo parceiro)
    "heatmap_hits": [],   # timestamps de chamadas (calor de chamadas)
    "wallet_balance": 134.50,
    "debt_cents": 0,
    "statement": [],      # mais recente primeiro
    "mode": "PASSE_ATIVO",
    "pass_expires_at": iso(now() + 11 * 3600),
    "kyc_status": "APPROVED",
    # Tipos de solicitação que o parceiro quer receber (Configurar solicitações).
    "service_prefs": ["MOTO", "MOTO_NEGOCIA"],
    # Piso que o parceiro aceita por corrida (Configurar solicitações).
    "min_fare": 0.0,
    "rated": set(),
    # --- raspadinha de prêmios (3.8) ---
    "scratch_campaigns": [
        {
            "id": "scratch-001",
            "name": "Raspadinha da Sorte",
            "description": "Raspe e ganhe prêmios incríveis!",
            "status": "ACTIVE",
            "started_at": iso(now() - 86400),
            "ended_at": iso(now() + 86400 * 30),
            "max_participations_per_user": 3,
            "participation_type": "FREE",
        },
        {
            "id": "scratch-002",
            "name": "Passe Grátis",
            "description": "Ganhe horas grátis na plataforma",
            "status": "ACTIVE",
            "started_at": iso(now() - 86400),
            "ended_at": iso(now() + 86400 * 30),
            "max_participations_per_user": 1,
            "participation_type": "FREE",
        },
    ],
    "scratch_prizes": [
        {
            "id": "prize-001",
            "campaign_id": "scratch-001",
            "type": "PROMO_CREDIT",
            "title": "Crédito R$ 5,00",
            "description": "Crédito promocional para sua próxima corrida",
            "value": 5.00,
            "validity_days": 30,
            "quantity_total": 100,
            "quantity_remaining": 100,
            "probability": 30.0,
        },
        {
            "id": "prize-002",
            "campaign_id": "scratch-001",
            "type": "FREE_HOURS",
            "title": "2 Horas Grátis",
            "description": "2 horas grátis para dirigir na plataforma",
            "value": 2.0,
            "validity_days": 7,
            "quantity_total": 50,
            "quantity_remaining": 50,
            "probability": 20.0,
        },
        {
            "id": "prize-003",
            "campaign_id": "scratch-001",
            "type": "DISCOUNT_COUPON",
            "title": "Desconto 10%",
            "description": "Desconto de 10% na próxima corrida",
            "value": 10.0,
            "validity_days": 7,
            "quantity_total": 200,
            "quantity_remaining": 200,
            "probability": 50.0,
        },
    ],
    "scratch_tickets": {},
    "scratch_redemptions": {},
    "invites": [],
}

# Zonas de calor (fonte única do preço por demanda e do mapa).
# Bairros REAIS de Porto Velho/RO, com o centroide retornado pelo Nominatim
# (OpenStreetMap) — nada de nome inventado. Levantado em 24/10/2026.
#
# IMPORTANTE: estes números NÃO são demanda real. São cenário de ensaio.
# A rota /heatmap marca a resposta com "demo": true e o app desenha a marca
# d'água DEMO. Para ensaiar o estado honesto "sem dados de demanda", suba o
# servidor com DEMO_HEAT=0 e a rota devolve zones: [].
HEAT_ZONES = [
    {"lat": -8.7647463, "lon": -63.9040643, "weight": 0.95, "label": "Centro",
     "calls_last_hour": 38},
    {"lat": -8.7563163, "lon": -63.9116496, "weight": 0.74, "label": "Arigolândia",
     "calls_last_hour": 29},
    {"lat": -8.7614459, "lon": -63.9063522, "weight": 0.66, "label": "Caiari",
     "calls_last_hour": 24},
    {"lat": -8.7556404, "lon": -63.9053544, "weight": 0.58, "label": "Olaria",
     "calls_last_hour": 20},
    {"lat": -8.7585272, "lon": -63.8921177, "weight": 0.50, "label": "São Cristóvão",
     "calls_last_hour": 16},
    {"lat": -8.7643327, "lon": -63.8888991, "weight": 0.42,
     "label": "Nossa Senhora das Graças", "calls_last_hour": 13},
    {"lat": -8.7735392, "lon": -63.8973132, "weight": 0.34, "label": "Areal",
     "calls_last_hour": 10},
    {"lat": -8.7509826, "lon": -63.8818556, "weight": 0.26, "label": "Embratel",
     "calls_last_hour": 7},
    {"lat": -8.7475814, "lon": -63.8694450, "weight": 0.20,
     "label": "Flodoaldo Pontes Pinto", "calls_last_hour": 5},
]

# Flag de ensaio: DEMO_HEAT=0 devolve o calor vazio (estado honesto
# "sem dados de demanda no momento"). Padrão: 1 (cenário DEMO marcado).
DEMO_HEAT = os.environ.get("DEMO_HEAT", "1") != "0"

# Aceite automático só em modo demo explícito. Em produção/uso normal,
# ninguém aceita sozinho — dado inventado não é sucesso.
DEMO_MODE = os.environ.get("DEMO_MODE", "0") == "1"
# Longar a janela em testes manuais (E2E no emulador, onde alternar entre os
# dois apps leva mais de 12 s) é permitido só dentro do modo demo.
AUTO_ACCEPT_AFTER_S = (
    float(os.environ.get("DEMO_AUTO_ACCEPT_S", "12")) if DEMO_MODE else None
)
AUTO_PHASES = [  # (segundos após aceite, status, eta_seconds)
    (0, "ACEITA", 300),
    (6, "A_CAMINHO", 240),
    (12, "CHEGOU", 60),
    (16, "EM_VIAGEM", None),
    (30, "FINALIZADA", None),
]

def ride_view(r: dict) -> dict:
    """Snapshot no schema Ride do contrato (camel keys não: snake, como a spec)."""
    view = {
        "ride_id": r["id"],
        "status": r["status"],
        "pricing_mode": r.get("pricing_mode"),
        "fare_total": r.get("fare_total"),
        "proposed_amount": r.get("proposed_amount"),
        "eta_seconds": r.get("eta_seconds"),
        "distance_km": r.get("distance_km"),
        "origin": r["origin"],
        "destination": r["destination"],
        "origin_address": r.get("origin_address"),
        "destination_address": r.get("destination_address"),
        "partner": r.get("partner"),
        "payment_status": r.get("payment_status", "NOT_DUE"),
        "created_at": r["created_at"],
    }
    # Posição do parceiro ao longo da rota real (simulada nesta demo, mas
    # seguindo as ruas que o mapa desenha). O passageiro usa para ver a moto
    # se aproximando; sem parceiro na corrida, não há posição.
    pos = _driver_position(r)
    if pos is not None:
        view["partner_position"] = pos
    return view

def advance(r: dict) -> None:
    """Auto-avance corridas conduzidas pelo simulador (lazily, a cada leitura)."""
    if r["driver"] != "sim" or r["status"] in (
        "FINALIZADA", "FALHA_PAGAMENTO", "EXPIRADA",
        "CANCELADA_CLIENTE", "CANCELADA_PARCEIRO", "CANCELADA_SISTEMA", "CANCELADA_SUPORTE"):
        return
    t = r["last_phase_at"]
    for dt, status, eta in AUTO_PHASES:
        if now() - t >= dt and _phase_index(status) > _phase_index(r["status"]):
            r["status"] = status
            r["eta_seconds"] = eta
            r["last_phase_at"] = now()
            if status == "FINALIZADA":
                r["fare_total"] = (r.get("proposed_amount")
                                   or r.get("fare_total") or 22.50)
                r["partner"] = {"name": "Seu Raimundo (simulado)", "rating": 4.9,
                                "vehicle": "Honda Biz 125"}
                _ledger_for_ride(r)

_PHASE_ORDER = ["CRIADA", "BUSCANDO", "OFERTADA", "ACEITA", "A_CAMINHO",
                "CHEGOU", "EM_VIAGEM", "FINALIZADA"]

def _phase_index(status: str) -> int:
    return _PHASE_ORDER.index(status) if status in _PHASE_ORDER else -1

def maybe_auto_accept() -> None:
    """Corrida BUSCANDO > 12 s sem parceiro real → simulador aceita.

    Desligado por padrão: só roda com DEMO_MODE=1 (ver AUTO_ACCEPT_AFTER_S).
    """
    if AUTO_ACCEPT_AFTER_S is None:
        return
    for r in STATE["rides"].values():
        if r["status"] == "BUSCANDO" and r["driver"] is None \
                and now() - r["requested_at"] > AUTO_ACCEPT_AFTER_S:
            r["driver"] = "sim"
            r["status"] = "ACEITA"
            r["eta_seconds"] = 300
            r["accepted_at"] = now()
            r["last_phase_at"] = now()
            r["pricing_mode_snapshot"] = _ride_pricing_mode()
            r["pricing_mode"] = r["pricing_mode_snapshot"]
            r["partner"] = {"name": "Seu Raimundo (simulado)", "rating": 4.9,
                            "vehicle": "Honda Biz 125"}

def _ride_pricing_mode() -> str:
    """Modo do parceiro (PASSE_ATIVO/COMISSAO) → enum de corrida do contrato.

    O contrato (openapi.yaml / 0001_schema.sql) define pricing_mode em
    ('PASSE','COMISSAO'); PASSE_ATIVO é só o nome do modo no /partner/*.
    """
    return "PASSE" if STATE["mode"] == "PASSE_ATIVO" else "COMISSAO"

def _ledger_for_ride(r: dict) -> None:
    """Lança a corrida na carteira do parceiro (demonstração; ver ADR-003).

    Espelha fn_payment_confirm_ride (0002_rls_states_events.sql):
    - PASSE ativo: comissão 0% — em dinheiro não há perna de ledger (o
      parceiro fica com o bruto em mãos); PIX/cartão credita o bruto integral.
    - COMISSAO (sem passe): dinheiro debita a comissão (débito imediato,
      ADR-003); PIX/cartão credita o bruto líquido da comissão.
    """
    fare = r.get("fare_total") or 0
    if fare <= 0:
        return
    # Snapshot imutável na aceitação (A4); fallback ao modo atual só para
    # corridas antigas sem snapshot.
    mode = (r.get("pricing_mode_snapshot") or r.get("pricing_mode")
            or _ride_pricing_mode())
    # Aceita PASSE_ATIVO (estado antigo) além do enum do contrato.
    passe_ativo = mode in ("PASSE", "PASSE_ATIVO")
    if r.get("cash_declared"):
        if passe_ativo:
            # PASSE + cash: parceiro já recebeu o bruto em mãos — nada debita.
            return
        # COMISSÃO em dinheiro: débito imediato da comissão (ADR-003)
        commission = round(fare * 0.12, 2)
        STATE["wallet_balance"] = round(STATE["wallet_balance"] - commission, 2)
        if STATE["wallet_balance"] < 0:
            STATE["debt_cents"] += int(round(-STATE["wallet_balance"] * 100))
            STATE["wallet_balance"] = 0.0
        STATE["statement"].insert(0, {
            "entry_group_id": new_id(), "ride_id": r["id"],
            "description": f"Corrida (dinheiro) {r.get('destination_address') or ''} — comissão 12%".strip(),
            "direction": "D", "amount": commission, "created_at": iso()})
    else:
        # Digital: PASSE credita o bruto; COMISSÃO credita o bruto líquido.
        credit = fare if passe_ativo else round(fare - fare * 0.12, 2)
        STATE["wallet_balance"] = round(STATE["wallet_balance"] + credit, 2)
        STATE["statement"].insert(0, {
            "entry_group_id": new_id(), "ride_id": r["id"],
            "description": (f"Corrida {r.get('destination_address') or ''}".strip()
                            + ("" if passe_ativo else " — líquido (comissão 12%)")),
            "direction": "C", "amount": credit, "created_at": iso()})

# ---------------------------------------------------------------------------
# Roteamento (contrato openapi.yaml — só o que os apps usam)
# ---------------------------------------------------------------------------

def _haversine_km(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    r = 6371.0
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp, dl = p2 - p1, math.radians(lon2 - lon1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(math.sqrt(a))


ROAD_FACTOR = 1.35        # Haversine -> ruas (mesmo fator do fallback do app)
ROAD_CACHE_TTL_S = 600    # mesma origem/destino por 10 min não reconsulta o OSRM


def _road_km(olat: float, olon: float, dlat: float, dlon: float) -> float:
    """Distância rodoviária que o mapa desenha (OSRM), com cache.

    A tarifa tem de usar a MESMA distância da rota exibida: se o preço sai de
    uma linha reta e o mapa mostra a rota por ruas, o "R$ por km" não fecha e
    o valor parece arbitrário. Sem rede (ou OSRM fora), cai em Haversine ×
    1,35 — exatamente o fallback aproximado do RouteService no app, então os
    dois continuam contando a mesma história.

    Roda FORA do LOCK (é rede): por isso `route` resolve a distância antes de
    entrar na seção crítica.
    """
    key = (round(olat, 5), round(olon, 5), round(dlat, 5), round(dlon, 5))
    hit = STATE["road_cache"].get(key)
    if hit and now() - hit[0] < ROAD_CACHE_TTL_S:
        return hit[1]
    url = ("https://router.project-osrm.org/route/v1/driving/"
           f"{olon:.5f},{olat:.5f};{dlon:.5f},{dlat:.5f}?overview=false")
    km = None
    try:
        req = urllib.request.Request(
            url, headers={"User-Agent": "10emais-demo/1.0 (contato@dezemais.app)"})
        with urllib.request.urlopen(req, timeout=3) as resp:
            data = json.loads(resp.read().decode("utf-8"))
        routes = data.get("routes") or []
        if routes:
            km = float(routes[0]["distance"]) / 1000.0
    except Exception:
        km = None
    if not km or km <= 0:
        km = _haversine_km(olat, olon, dlat, dlon) * ROAD_FACTOR
    STATE["road_cache"][key] = (now(), km)
    return km


def _quote(km: float, olat: float, olon: float) -> dict:
    """Preço do momento (GET /quote): tarifa dinâmica do servidor.

    base = fixo + por km x distância da rota × multiplicador de demanda (zona
    da origem + calor ao vivo) × rush da hora — o valor muda a cada hora e
    por origem. expires_in diz por quanto tempo o servidor honra o valor
    mostrado ao passageiro.
    """
    # Preça o km que o card exibe (1 casa) e não a fração invisível: assim
    # "Base R$ 7,70 · 1,2 km" fecha na conta de quem lê a tela.
    km = max(0.1, round(km, 1))
    base = round(5.0 + 2.2 * km, 2)
    recent = [h for h in STATE["heatmap_hits"] if now() - h["ts"] < 900]
    near = sum(1 for h in recent
               if abs(h["lat"] - olat) < 0.01 and abs(h["lon"] - olon) < 0.01)
    z = min(HEAT_ZONES,
            key=lambda c: abs(c["lat"] - olat) + abs(c["lon"] - olon))
    weight = min(1.0, z["weight"] + 0.07 * near)
    demand = round(1.0 + 0.35 * weight, 2)
    hour = datetime.now().hour
    rush = 1.18 if hour in (7, 8, 9, 17, 18, 19) else (0.88 if hour <= 5 else 1.0)
    return {
        "fare_total": round(base * demand * rush, 2),
        "expires_in": 90,
        "currency": "BRL",
        "breakdown": {"distance_km": km, "base": base,
                      "demand_multiplier": demand, "rush_multiplier": rush},
    }


def _path_km(path: list[list[float]]) -> float:
    total = 0.0
    for i in range(len(path) - 1):
        total += _haversine_km(path[i][0], path[i][1],
                               path[i + 1][0], path[i + 1][1])
    return total


def _route_path(a: tuple[float, float], b: tuple[float, float]) -> list[list[float]]:
    """Geometria da rota por ruas (OSRM) com cache — o percurso que o
    passageiro vê a moto seguir. Sem rede, cai numa reta entre os dois pontos."""
    key = (round(a[0], 5), round(a[1], 5), round(b[0], 5), round(b[1], 5))
    hit = STATE["path_cache"].get(key)
    if hit:
        return hit
    url = ("https://router.project-osrm.org/route/v1/driving/"
           f"{a[1]:.5f},{a[0]:.5f};{b[1]:.5f},{b[0]:.5f}"
           "?overview=full&geometries=geojson")
    coords: list = []
    try:
        req = urllib.request.Request(
            url, headers={"User-Agent": "10emais-demo/1.0 (contato@dezemais.app)"})
        with urllib.request.urlopen(req, timeout=2.5) as resp:
            data = json.loads(resp.read().decode("utf-8"))
        routes = data.get("routes") or []
        if routes:
            coords = ((routes[0].get("geometry") or {}).get("coordinates")) or []
    except Exception:
        coords = []
    path = [[float(c[1]), float(c[0])] for c in coords]
    if len(path) < 2:
        path = [[a[0], a[1]], [b[0], b[1]]]
    if len(STATE["path_cache"]) >= 64:
        STATE["path_cache"].pop(next(iter(STATE["path_cache"])))
    STATE["path_cache"][key] = path
    return path


def _point_along(path: list[list[float]], fraction: float) -> list[float] | None:
    """Ponto a [fraction] do comprimento da polilinha (0 = início, 1 = fim)."""
    if not path:
        return None
    if len(path) == 1:
        return path[0]
    fractions = max(0.0, min(1.0, fraction))
    segs = [
        _haversine_km(path[i][0], path[i][1], path[i + 1][0], path[i + 1][1])
        for i in range(len(path) - 1)
    ]
    total = sum(segs)
    if total <= 0:
        return path[0]
    target = total * fractions
    acc = 0.0
    for i, d in enumerate(segs):
        if acc + d >= target:
            t = 0.0 if d == 0 else (target - acc) / d
            return [
                round(path[i][0] + (path[i + 1][0] - path[i][0]) * t, 6),
                round(path[i][1] + (path[i + 1][1] - path[i][1]) * t, 6),
            ]
        acc += d
    return path[-1]


PICKUP_SPEED_KMH = 22.0
TRIP_SPEED_KMH = 26.0


def _driver_position(r: dict) -> dict | None:
    """Percurso simulado do parceiro sobre a rota real, na demo.

    Em produção a posição vem do GPS do aparelho (heartbeat); aqui a demo
    move a moto ao longo da MESMA geometria que o mapa desenha, para que o
    passageiro acompanhe a aproximação sem que o motorista precise rodar.
    """
    start = r.get("driver_start")
    o = r.get("origin") or {}
    d = r.get("destination") or {}
    if not start or "lat" not in o or "lat" not in d:
        return None
    status = r["status"]
    if status in ("FINALIZADA", "FALHA_PAGAMENTO"):
        return {"lat": d["lat"], "lon": d["lon"], "remaining_km": 0.0}
    if status in ("ACEITA", "A_CAMINHO", "CHEGOU"):
        if status == "CHEGOU":
            return {"lat": o["lat"], "lon": o["lon"], "remaining_km": 0.0}
        leg = _route_path((start["lat"], start["lon"]),
                          (o["lat"], o["lon"]))
        km = _path_km(leg)
        duration = max(45.0, km / PICKUP_SPEED_KMH * 3600)
        frac = (now() - r.get("accepted_at", now())) / duration
        p = _point_along(leg, frac)
        if p is None:
            return None
        return {"lat": p[0], "lon": p[1],
                "remaining_km": round(km * (1 - min(1.0, frac)), 1)}
    if status == "EM_VIAGEM":
        leg = _route_path((o["lat"], o["lon"]), (d["lat"], d["lon"]))
        km = _path_km(leg)
        duration = max(60.0, km / TRIP_SPEED_KMH * 3600)
        frac = (now() - r.get("em_viagem_at", now())) / duration
        p = _point_along(leg, frac)
        if p is None:
            return None
        return {"lat": p[0], "lon": p[1],
                "remaining_km": round(km * (1 - min(1.0, frac)), 1)}
    return None


def _partner_start(origin_lat: float, origin_lon: float,
                   driver_id: str = "self") -> dict:
    """De onde a moto sai: presença real do parceiro, ou ~1,2 km do embarque."""
    pres = STATE["presences"].get(driver_id) or STATE["presences"].get("self")
    if pres and now() - pres["at"] < 120:
        return {"lat": pres["lat"], "lon": pres["lon"]}
    return {"lat": round(origin_lat + 0.0075, 6),
            "lon": round(origin_lon - 0.0045, 6)}


# ---------------------------------------------------------------------------
# Despacho dinâmico: presença -> ranking -> oferta -> recusa/timeout -> próximo
# ---------------------------------------------------------------------------

DRIVER_DEFAULT = "self"
PRESENCE_FRESH_S = 90      # heartbeat 30 s + tolerância (igual ao radar)
OFFER_TIMEOUT_S = 15       # PRM-oferta.timeout
# Desempenho: a semana é contada no fuso da praça (Porto Velho, UTC-4 e sem
# horário de verão). "Hoje" no painel do motorista tem de ser o dia dele, não
# o dia UTC — senão a noite cai no dia seguinte.
DAY_TZ_OFFSET_S = -4 * 3600
PERF_DAYS = 7
PERF_WEEKDAYS = ("seg", "ter", "qua", "qui", "sex", "sáb", "dom")
RETRY_COOLDOWN_S = 20      # após esgotar a rodada, espera antes de reofertar
DISPATCH_MAX_ROUNDS = 3
R0_KM, R_STEP_KM, RMAX_KM = 2.0, 1.0, 8.0


def _driver_id(value=None) -> str:
    """Identidade do parceiro na demo; ausente = o app real ("self")."""
    if isinstance(value, str) and value.strip():
        return value.strip()[:64]
    return DRIVER_DEFAULT


def _pseudonym(driver_id: str) -> str:
    """Id pseudônimo do radar: nunca expõe o id real do parceiro."""
    return "parceiro-" + hashlib.sha1(driver_id.encode()).hexdigest()[:6]


def _presence_services(body_services, fallback) -> list[str]:
    if isinstance(body_services, list) and body_services:
        return sorted({str(s) for s in body_services})
    return list(fallback)


def _set_presence_status(driver_id: str, status: str) -> None:
    pres = STATE["presences"].get(driver_id)
    if pres is not None:
        pres["status"] = status


# ---------------------------------------------------------------------------
# Desempenho semanal: o que aconteceu de verdade com este parceiro
# ---------------------------------------------------------------------------

def _day_key(ts: float | None = None) -> str:
    """Dia da praça (UTC-4) de um instante — chave do balde de desempenho."""
    local = datetime.fromtimestamp((ts if ts is not None else now())
                                   + DAY_TZ_OFFSET_S, tz=timezone.utc)
    return local.strftime("%Y-%m-%d")


def _perf_bucket(driver_id: str, day: str | None = None) -> dict:
    """Balde do dia (criado zerado quando o parceiro ainda não teve evento)."""
    per_driver = STATE["perf"].setdefault(driver_id, {})
    return per_driver.setdefault(day or _day_key(), {
        "offers": 0, "accepted": 0, "declined": 0, "expired": 0,
        "rank_sum": 0.0, "rank_samples": 0, "pool_sum": 0,
        "rank_best": 0, "rank_worst": 0,
        "online_seconds": 0.0, "ratings": 0, "rating_sum": 0.0,
    })


def _perf_track(driver_id: str, field: str) -> None:
    """+1 num contador do dia (chamada recebida, aceite, recusa...)."""
    bucket = _perf_bucket(driver_id)
    bucket[field] = int(bucket.get(field, 0)) + 1


def _credit_online(driver_id: str, upto: float | None = None) -> None:
    """Soma ao dia o tempo conectado desde o último crédito.

    Só conta o que o servidor sabia: se a presença ficou velha (sem
    heartbeat além da tolerância), o crédito para no fim da janela fresca —
    tempo que ninguém observou não vira "tempo online".
    """
    pres = STATE["presences"].get(driver_id)
    if pres is None:
        return
    start = float(pres.get("online_credit_at") or pres.get("online_since")
                  or pres.get("at") or now())
    end = float(upto if upto is not None else now())
    end = min(end, float(pres.get("at", end)) + PRESENCE_FRESH_S)
    if end <= start:
        pres["online_credit_at"] = max(end, start)
        return
    # Pode atravessar a meia-noite da praça: cada trecho vai para o seu dia.
    cursor = start
    while cursor < end:
        next_midnight = (math.floor((cursor + DAY_TZ_OFFSET_S) / 86400) + 1) * 86400
        chunk_end = min(end, next_midnight - DAY_TZ_OFFSET_S)
        _perf_bucket(driver_id, _day_key(cursor))["online_seconds"] += \
            chunk_end - cursor
        cursor = chunk_end
    pres["online_credit_at"] = end


def _shift_clock(offset_s: float) -> float:
    global CLOCK_OFFSET
    """Move o relógio da demo e credita o intervalo a quem está online.

    É o que permite ensaiar uma semana em minutos: os eventos continuam
    passando pelo mesmo pipeline (presença, despacho, transições, avaliação);
    só o relógio anda. O trecho entre os dois instantes conta como turno de
    quem estava conectado — uma simulação de tempo, declarada como tal, nunca
    um número escrito à mão no histórico.
    """
    old = now()
    new = time.time() + float(offset_s)
    delta = new - old
    for did, pres in STATE["presences"].items():
        for key in ("at", "online_since", "online_credit_at"):
            if pres.get(key):
                pres[key] = float(pres[key]) + delta
        if delta > 0:
            # O trecho percorrido é um turno contínuo: credita antes de seguir.
            pres["online_credit_at"] = old
            _credit_online(did, upto=new)
    CLOCK_OFFSET = float(offset_s)
    return new


def _sample_rank_for_call(r: dict) -> None:
    """Posição de cada parceiro online no ranking desta chamada.

    A oferta vai para o 1º da fila, então medir a posição só nas ofertas
    recebidas daria sempre "1º" e não diria nada. Aqui cada chamada é uma
    amostra para todo mundo que estava disputando, ganhando ou não — é isso
    que a média da semana mostra (e cai quando outro parceiro passa na frente).
    """
    st = _dispatch_state(r)
    sampled = st.setdefault("rank_sampled", [])
    candidates = _online_candidates()
    if not candidates or all(c.partner_id in sampled for c in candidates):
        return  # rodada já amostrada: não reavalia a fila a cada tick
    ranked = dispatch_engine.rank_candidates(
        candidates, origin=_ride_origin(r),
        fare=_ride_offer_amount(r), service=_ride_service(r),
        max_distance_km=RMAX_KM)
    for position, ev in enumerate(ranked, start=1):
        did = ev.candidate.partner_id
        if did in sampled:
            continue
        sampled.append(did)
        bucket = _perf_bucket(did)
        bucket["rank_sum"] += position
        bucket["rank_samples"] += 1
        bucket["pool_sum"] += len(ranked)
        best, worst = int(bucket.get("rank_best", 0)), int(bucket.get("rank_worst", 0))
        bucket["rank_best"] = position if not best else min(best, position)
        bucket["rank_worst"] = max(worst, position)


def _perf_view(driver_id: str) -> dict:
    """Desempenho da semana corrente (7 dias, terminando hoje).

    Taxa de aceite e posição vêm das chamadas registradas; sem chamada no
    período o valor é None (o app mostra "sem dados", não um 0% inventado).
    """
    pres = STATE["presences"].get(driver_id) or {}
    # Offline não pode apagar a nota: ela é do parceiro, não da sessão.
    if pres:
        rating_value = pres.get("rating")
        rating_count = int(pres.get("rating_count", 0))
    elif driver_id == DRIVER_DEFAULT:
        rating_value = PROFILE_RATING["value"]
        rating_count = PROFILE_RATING["count"]
    else:
        rating_value, rating_count = None, 0
    session_s = int(max(0.0, now() - float(pres["online_since"]))) \
        if pres.get("online_since") else 0
    _credit_online(driver_id)  # fecha o trecho em aberto antes de ler

    today = datetime.fromtimestamp(now() + DAY_TZ_OFFSET_S, tz=timezone.utc)
    days: list[dict] = []
    totals = {"offers": 0, "accepted": 0, "declined": 0, "expired": 0,
              "online_seconds": 0, "rank_samples": 0, "rank_sum": 0.0,
              "pool_sum": 0, "ratings": 0, "rating_sum": 0.0}
    best, worst = 0, 0
    for back in range(PERF_DAYS - 1, -1, -1):
        day = today - timedelta(days=back)
        key = day.strftime("%Y-%m-%d")
        b = (STATE["perf"].get(driver_id) or {}).get(key) or {}
        offers = int(b.get("offers", 0))
        accepted = int(b.get("accepted", 0))
        samples = int(b.get("rank_samples", 0))
        ratings = int(b.get("ratings", 0))
        online_s = int(round(b.get("online_seconds", 0.0)))
        days.append({
            "date": key,
            "weekday": PERF_WEEKDAYS[day.weekday()],
            "offers": offers,
            "accepted": accepted,
            "declined": int(b.get("declined", 0)),
            "expired": int(b.get("expired", 0)),
            "acceptance_rate": round(accepted / offers, 4) if offers else None,
            "online_seconds": online_s,
            "avg_rank": round(b["rank_sum"] / samples, 2) if samples else None,
            "rank_samples": samples,
            "pool": round(b["pool_sum"] / samples, 1) if samples else None,
            "ratings": ratings,
            "rating_avg": round(b["rating_sum"] / ratings, 2) if ratings else None,
        })
        for field in ("offers", "accepted", "declined", "expired", "ratings"):
            totals[field] += int(b.get(field, 0))
        totals["online_seconds"] += online_s
        totals["rank_samples"] += samples
        totals["rank_sum"] += float(b.get("rank_sum", 0.0))
        totals["pool_sum"] += int(b.get("pool_sum", 0))
        totals["rating_sum"] += float(b.get("rating_sum", 0.0))
        if samples:
            day_best = int(b.get("rank_best", 0))
            best = day_best if not best else min(best, day_best)
            worst = max(worst, int(b.get("rank_worst", 0)))

    samples = totals["rank_samples"]
    offers = totals["offers"]
    return {
        "date": today.strftime("%Y-%m-%d"),
        "week_start": days[0]["date"],
        "timezone": "America/Porto_Velho",
        "days": days,
        "acceptance": {
            "current": round(float(pres.get("acceptance_rate", 0.0)), 4)
            if pres else None,
            "week": round(totals["accepted"] / offers, 4) if offers else None,
            "offers": offers,
            "accepted": totals["accepted"],
            "declined": totals["declined"],
            "expired": totals["expired"],
        },
        "online": {
            "week_seconds": int(totals["online_seconds"]),
            "today_seconds": int(days[-1]["online_seconds"]),
            "session_seconds": session_s,
        },
        "rating": {
            "value": round(float(rating_value), 2) if rating_value else None,
            "count": int(rating_count),
            "week_count": totals["ratings"],
            "week_avg": (round(totals["rating_sum"] / totals["ratings"], 2)
                         if totals["ratings"] else None),
        },
        "rank": {
            "avg": round(totals["rank_sum"] / samples, 2) if samples else None,
            "best": best or None,
            "worst": worst or None,
            "pool": round(totals["pool_sum"] / samples, 1) if samples else None,
            "samples": samples,
        },
    }


def _online_candidates() -> list[Candidate]:
    """Foto dos parceiros elegíveis a receber oferta agora."""
    out: list[Candidate] = []
    for did, p in STATE["presences"].items():
        if p.get("status") not in ("ONLINE_DISPONIVEL", "OFERTA_PENDENTE"):
            continue
        if now() - p.get("at", 0) > PRESENCE_FRESH_S:
            continue
        out.append(Candidate(
            partner_id=did,
            lat=p["lat"], lon=p["lon"],
            rating=float(p.get("rating", 4.9)),
            rating_count=int(p.get("rating_count", 0)),
            acceptance_rate=float(p.get("acceptance_rate", 0.95)),
            idle_seconds=max(0.0, now() - p.get("online_since", now())),
            completed_rides=int(p.get("completed_rides", 0)),
            vehicle=p.get("vehicle", "Moto"),
            services=tuple(p.get("services") or STATE["service_prefs"]),
            min_fare=float(p.get("min_fare", 0.0)),
            route_deviation_m=float(p.get("route_deviation_m", 0.0)),
        ))
    return out


def _ride_service(r: dict) -> str:
    return "MOTO_NEGOCIA" if r.get("proposed_amount") else "MOTO"


def _ride_offer_amount(r: dict) -> float:
    return float(r.get("proposed_amount") or r.get("fare_total") or 18.50)


def _ride_origin(r: dict) -> tuple[float, float]:
    o = r.get("origin") or {}
    return (float(o.get("lat", -8.7607)), float(o.get("lon", -63.9039)))


def _dispatch_state(r: dict) -> dict:
    return STATE["dispatch"].setdefault(r["id"], {
        "round": 1, "radius_km": R0_KM, "excluded": [], "retry_at": 0.0,
    })


def _ranked_for_ride(r: dict, radius_km: float, exclude=None,
                     origin=None) -> list:
    return dispatch_engine.rank_candidates(
        _online_candidates(),
        origin=origin or _ride_origin(r),
        fare=_ride_offer_amount(r),
        service=_ride_service(r),
        max_distance_km=radius_km,
        exclude=exclude if exclude is not None else set(_dispatch_state(r)["excluded"]),
    )


def _offer_view(o: dict) -> dict:
    """Oferta como o parceiro a recebe, incluindo POR QUE veio para ele.

    `dispatch` não é enfeite: são os números que o motor deixou elegível antes
    de qualquer julgamento do app — posição na fila, tamanho da fila, tempo
    online (não parado), nota/motoboy e os componentes do score.
    """
    pres = STATE["presences"].get(o.get("driver_id", "")) or {}
    online_s = o.get("driver_online_seconds")
    if pres and pres.get("online_since"):
        # Tempo online é relógio: envelhece enquanto a oferta está na tela.
        online_s = round(max(0.0, now() - float(pres["online_since"])))
    dispatch = None
    if o.get("dispatch_rank"):
        dispatch = {
            "rank": o["dispatch_rank"],
            "pool": o.get("dispatch_pool", o["dispatch_rank"]),
            "score": o.get("dispatch_score"),
            "components": o.get("score_parts") or {},
            "online_seconds": online_s,
            "rating": o.get("driver_rating"),
            "rating_count": o.get("driver_rating_count"),
            "acceptance_rate": o.get("driver_acceptance_rate"),
            "vehicle": o.get("driver_vehicle"),
        }
    return {
        "offer_id": o["id"], "ride_id": o["ride_id"], "amount": o["amount"],
        "pickup_distance_km": o["pickup_distance_km"],
        "trip_distance_km": o["trip_distance_km"],
        "destination_area": o["destination_area"],
        "service": o.get("service"),
        "pickup_eta_min": o.get("pickup_eta_min"),
        "trip_duration_min": o.get("trip_duration_min"),
        "price_multiplier": o.get("price_multiplier"),
        "origin": o.get("origin"), "destination": o.get("destination"),
        "passenger_name": o.get("passenger_name"),
        "passenger_rating": o.get("passenger_rating"),
        "dispatch": dispatch,
        "timeout_at": iso(o["timeout_at"]),
    }


def _penalize_acceptance(driver_id: str) -> None:
    """Recusa reduz a taxa de aceite (penalização suave, nunca exclusão)."""
    pres = STATE["presences"].get(driver_id)
    if pres is None:
        return
    pres["acceptance_rate"] = round(
        max(0.0, float(pres.get("acceptance_rate", 0.95)) * 0.97), 4)


def _loss_of(o: dict) -> dict:
    """O que o parceiro perdeu com esta oferta — o app só exibe, não calcula."""
    pres = STATE["presences"].get(o.get("driver_id", DRIVER_DEFAULT)) or {}
    return {
        "offer_id": o["id"],
        "ride_id": o["ride_id"],
        "reason": o.get("close_reason", "DECLINED"),  # DECLINED | EXPIRED
        "lost_amount": o["amount"],
        "pickup_distance_km": o.get("pickup_distance_km"),
        "pickup_eta_min": o.get("pickup_eta_min"),
        "trip_distance_km": o.get("trip_distance_km"),
        "trip_duration_min": o.get("trip_duration_min"),
        "acceptance_rate_before": o.get("acceptance_before"),
        "acceptance_rate": pres.get("acceptance_rate"),
        "rating": o.get("driver_rating"),
        "timeout_s": OFFER_TIMEOUT_S,
    }


def _close_offer(o: dict, status: str, *, penalize: bool) -> dict:
    """Fecha a oferta registrando a perda e devolve o bloco `loss`.

    `acceptance_before` é capturado ANTES da penalização: é a diferença que a
    tela mostra (95% → 92%), não um número inventado pelo app.
    """
    did = o.get("driver_id", DRIVER_DEFAULT)
    pres = STATE["presences"].get(did) or {}
    o["acceptance_before"] = (
        float(pres["acceptance_rate"]) if "acceptance_rate" in pres else None)
    # Desempenho: recusa e timeout entram no dia do fechamento.
    _perf_track(did, "declined" if status == "DECLINED" else "expired")
    if penalize:
        _penalize_acceptance(did)
    o["status"] = status
    o["close_reason"] = status
    o["responded_at"] = now()
    o["loss"] = _loss_of(o)
    return o["loss"]


def _live_offer_for(ride_id: str) -> dict | None:
    for o in STATE["offers"].values():
        if o["ride_id"] == ride_id and o["status"] == "SENT":
            return o
    return None


def _expire_offers() -> None:
    """Timeout de 15 s é autoritativo: expira, libera o motorista e reoferta.

    Deixar estourar o tempo conta como recusa (mesma penalização suave): senão
    ignorar a oferta sairia mais barato do que apertar "Recusar".
    """
    for o in list(STATE["offers"].values()):
        if o["status"] != "SENT" or now() <= o["timeout_at"]:
            continue
        did = o.get("driver_id", DRIVER_DEFAULT)
        if (STATE["presences"].get(did) or {}).get("status") == "OFERTA_PENDENTE":
            _set_presence_status(did, "ONLINE_DISPONIVEL")
        _close_offer(o, "EXPIRED", penalize=True)
        r = STATE["rides"].get(o["ride_id"])
        if r is None:
            continue
        if r["status"] == "OFERTADA":
            r["status"] = "BUSCANDO"
        st = _dispatch_state(r)
        if did not in st["excluded"]:
            st["excluded"].append(did)


def _dispatch_next(r: dict) -> dict | None:
    """Oferta ao melhor candidato agora; devolve a oferta criada (ou None)."""
    if r.get("status") != "BUSCANDO" or _live_offer_for(r["id"]):
        return None
    st = _dispatch_state(r)
    if now() < st.get("retry_at", 0.0):
        return None

    # Amostra do ranking desta chamada (uma por parceiro por corrida).
    _sample_rank_for_call(r)

    ranked = _ranked_for_ride(r, st["radius_km"])
    # Rodadas de raio: 2 km -> 3 -> ... até 8 km (SPECS §1.1).
    while not ranked and st["radius_km"] < RMAX_KM:
        st["radius_km"] = min(RMAX_KM, st["radius_km"] + R_STEP_KM)
        ranked = _ranked_for_ride(r, st["radius_km"])

    if not ranked:
        # Ninguém sobrou nesta rodada: espera um pouco e tenta de novo. Após
        # 3 rodadas sem aceite, todos voltam (a taxa de aceite já caiu).
        st["round"] = int(st.get("round", 1)) + 1
        st["radius_km"] = R0_KM
        if st["round"] > DISPATCH_MAX_ROUNDS:
            st["round"] = 1
            st["excluded"] = []
        st["retry_at"] = now() + RETRY_COOLDOWN_S
        return None

    best = ranked[0]
    did = best.candidate.partner_id
    amount = _ride_offer_amount(r)
    o = _ride_origin(r)
    d = r.get("destination") or {}
    trip_km = r.get("distance_km")
    if trip_km is None:
        trip_km = 4.8
        if d and all(k in d for k in ("lat", "lon")):
            trip_km = round(_haversine_km(o[0], o[1], d["lat"], d["lon"]) * 1.35, 1)
    negotiated = bool(r.get("proposed_amount"))
    base_km = max(0.1, round(trip_km, 1))
    multiplier = (None if negotiated else round(
        amount / round(5.0 + 2.2 * base_km, 2), 2))
    dest = (r.get("destination_address") or "").split(",")[0]
    oid = new_id()
    STATE["offers"][oid] = {
        "id": oid, "ride_id": r["id"], "status": "SENT",
        "driver_id": did,
        "sequence_no": sum(1 for x in STATE["offers"].values()
                           if x["ride_id"] == r["id"]) + 1,
        "amount": amount,
        "pickup_distance_km": round(best.distance_km, 1),
        "pickup_eta_min": max(1, math.ceil(best.eta_min)),
        "trip_distance_km": trip_km,
        "trip_duration_min": max(1, round(trip_km / 30 * 60)),
        "destination_area": dest or "Centro",
        "service": _ride_service(r),
        "price_multiplier": multiplier,
        "dispatch_round": st["round"],
        # O melhor é sempre o 1º: a oferta é sequencial. O tamanho da fila
        # muda conforme os outros recusam, e é isso que a tela mostra.
        "dispatch_rank": 1,
        "dispatch_pool": len(ranked),
        "dispatch_score": round(best.score, 4),
        "score_parts": {k: round(v, 4) for k, v in best.components.items()},
        "driver_rating": best.candidate.rating,
        "driver_rating_count": best.candidate.rating_count,
        "driver_online_seconds": round(best.candidate.idle_seconds),
        "driver_acceptance_rate": best.candidate.acceptance_rate,
        "driver_vehicle": best.candidate.vehicle,
        "origin": r.get("origin"), "destination": r.get("destination"),
        "passenger_name": "Passageira demo",
        "passenger_rating": 4.9,
        "sent_at": now(), "timeout_at": now() + OFFER_TIMEOUT_S,
    }
    # Não marca como "já ofertado" enquanto a oferta está viva: se ele
    # recusar/expirar, aí sim entra na exclusão da rodada.
    r["status"] = "OFERTADA"
    r["offered_at"] = now()
    _perf_track(did, "offers")
    _set_presence_status(did, "OFERTA_PENDENTE")
    return STATE["offers"][oid]


def _dispatch_tick() -> None:
    """Roda a cada request: expira ofertas vencidas e oferta corridas órfãs."""
    _expire_offers()
    for r in STATE["rides"].values():
        if r.get("status") == "BUSCANDO":
            _dispatch_next(r)


def route(method: str, path: str, query: dict, body: dict) -> tuple[int, dict]:
    maybe_auto_accept()
    if method == "GET" and path == "/quote":
        # Distância é rede (OSRM): resolve antes do LOCK para uma cotação
        # lenta não travar o poll de corrida/oferta dos dois apps.
        def _f(name: str, default: float) -> float:
            try:
                return float(query.get(name, [default])[0])
            except (TypeError, ValueError):
                return default
        olat, olon = _f("origin_lat", -8.7607), _f("origin_lon", -63.9039)
        dlat, dlon = _f("dest_lat", -8.7647), _f("dest_lon", -63.8969)
        km = _road_km(olat, olon, dlat, dlon)
        with LOCK:
            return 200, _quote(km, olat, olon)
    if method == "POST" and path == "/rides":
        # A corrida congela a distância da rota no pedido: cotação, oferta e
        # recibo passam a contar o MESMO km. Resolve antes do LOCK pelo mesmo
        # motivo da cotação (é rede).
        o = body.get("origin") or {"lat": -8.7607, "lon": -63.9039}
        d = body.get("destination") or {"lat": -8.7647, "lon": -63.8969}
        distance_km = None
        if all(k in o for k in ("lat", "lon")) and all(k in d for k in ("lat", "lon")):
            distance_km = max(0.1, round(
                _road_km(o["lat"], o["lon"], d["lat"], d["lon"]), 1))
        with LOCK:
            return _route(method, path, query, body, distance_km)
    with LOCK:
        return _route(method, path, query, body)

def _route(method: str, path: str, query: dict, body: dict,
           distance_km: float | None = None) -> tuple[int, dict]:
    # Despacho é dirigido por relógio: qualquer request avança ofertas e
    # reofertas, não só o poll de ofertas do parceiro.
    _dispatch_tick()
    # --- perfil ---
    if method == "GET" and path == "/me":
        return 200, {
            "user_id": "demo-user", "role": "PARTNER",
            "partner": {
                "kyc_status": STATE["kyc_status"],
                "monetization_mode": STATE["mode"],
                "pass_expires_at": STATE["pass_expires_at"],
                "wallet_balance": STATE["wallet_balance"],
                "debt_cents": STATE["debt_cents"],
            }}

    # --- perfil: atualização de cadastro (3.6) ---
    if method == "PUT" and path == "/me/profile":
        payload = {
            "user_id": "demo-user", "role": "PARTNER",
            "full_name": body.get("full_name"),
            "birth_date": body.get("birth_date"),
            "weight": body.get("weight"),
            "height": body.get("height"),
        }
        if STATE.get("partner_info"):
            payload["partner"] = STATE["partner_info"]
        return 200, payload

    if method == "POST" and path == "/me/profile/photo":
        payload = {"user_id": "demo-user", "role": "PARTNER",
                   "photo_url": "https://dezemais.app/demo/avatar.png"}
        if STATE.get("partner_info"):
            payload["partner"] = STATE["partner_info"]
        return 200, payload

    # --- passageiro: preço do momento (tarifa dinâmica) ---
    # --- passageiro: corridas ---
    if method == "POST" and path == "/rides":
        pricing = body.get("pricing_mode", "TARIFF")
        proposed = body.get("proposed_amount")
        if pricing == "NEGOTIATED" and (proposed is None or proposed <= 0):
            return 422, {"title": "Preço inválido", "status": 422, "code": "invalid_pricing"}
        if any(r["status"] in ("CRIADA", "BUSCANDO", "OFERTADA", "ACEITA",
                               "A_CAMINHO", "CHEGOU", "EM_VIAGEM")
               for r in STATE["rides"].values()):
            return 409, {"title": "Corrida ativa", "status": 409, "code": "active_ride_exists"}
        rid = new_id()
        quoted = body.get("quoted_fare")
        fare_snapshot = (quoted if pricing == "TARIFF"
                         and isinstance(quoted, (int, float)) and quoted > 0
                         else None)
        STATE["heatmap_hits"].append({"ts": now(),
                                     "lat": body.get("origin", {}).get("lat", -8.7607),
                                     "lon": body.get("origin", {}).get("lon", -63.9039)})
        STATE["rides"][rid] = {
            "id": rid, "status": "BUSCANDO", "driver": None,
            "pricing_mode": None, "proposed_amount": proposed,
            "fare_total": fare_snapshot, "eta_seconds": None,
            "distance_km": distance_km,
            "origin": body.get("origin", {"lat": -8.7607, "lon": -63.9039}),
            "destination": body.get("destination", {"lat": -8.7647, "lon": -63.8969}),
            "origin_address": body.get("origin_address"),
            "destination_address": body.get("destination_address"),
            "partner": None, "payment_status": "NOT_DUE",
            "created_at": iso(), "requested_at": now(),
            "accepted_at": None, "last_phase_at": now(),
            "cash_declared": False,
        }
        return 201, {}

    if method == "GET" and path == "/rides":
        rides = sorted(STATE["rides"].values(), key=lambda r: r["created_at"], reverse=True)
        for r in rides:
            advance(r)
        if query.get("active") == ["1"]:
            open_statuses = ("CRIADA", "BUSCANDO", "OFERTADA", "ACEITA",
                             "A_CAMINHO", "CHEGOU", "EM_VIAGEM")
            rides = [r for r in rides if r["status"] in open_statuses]
        return 200, {"rides": [ride_view(r) for r in rides]}

    if path.startswith("/rides/") and path.endswith("/cancel") and method == "POST":
        r = _ride_by_path(path)
        if r is None:
            return 404, {"title": "Não encontrada", "status": 404, "code": "not_found"}
        if r["status"] not in ("CRIADA", "BUSCANDO", "OFERTADA"):
            return 409, {"title": "Encerrada", "status": 409, "code": "ride_already_closed"}
        r["status"] = "CANCELADA_CLIENTE"
        for o in STATE["offers"].values():
            if o["ride_id"] == r["id"] and o["status"] == "SENT":
                o["status"] = "EXPIRED"
        return 200, {}

    if path.startswith("/rides/") and path.endswith("/negotiation") and method == "POST":
        r = _ride_by_path(path)
        if r is None:
            return 404, {"title": "Não encontrada", "status": 404, "code": "not_found"}
        amount = body.get("amount") or 0
        if amount < 15:  # piso da cidade (demo: R$ 15)
            return 422, {"title": "Abaixo do piso", "status": 422, "code": "below_floor"}
        r["proposed_amount"] = amount
        return 201, {}

    if path.startswith("/rides/") and path.endswith("/share") and method == "POST":
        r = _ride_by_path(path)
        if r is None:
            return 404, {"title": "Não encontrada", "status": 404, "code": "not_found"}
        return 201, {"url": f"https://dezemais.app/t/{r['id'][:8]}", "expires_at": iso(now() + 3600)}

    if path.startswith("/rides/") and path.endswith("/rating") and method == "POST":
        r = _ride_by_path(path)
        if r is None:
            return 404, {"title": "Não encontrada", "status": 404, "code": "not_found"}
        if r["id"] in STATE["rated"]:
            return 409, {"title": "Já avaliada", "status": 409, "code": "already_rated"}
        STATE["rated"].add(r["id"])
        # Avaliação do passageiro entra no desempenho do parceiro da corrida
        # e move a nota que o despacho usa (não é número de tela).
        stars = body.get("stars")
        did = r.get("partner_driver_id")
        if did and isinstance(stars, (int, float)) and 1 <= float(stars) <= 5:
            bucket = _perf_bucket(did)
            bucket["ratings"] = int(bucket.get("ratings", 0)) + 1
            bucket["rating_sum"] = float(bucket.get("rating_sum", 0.0)) + float(stars)
            pres = STATE["presences"].get(did)
            count = int(pres.get("rating_count", PROFILE_RATING["count"])) \
                if pres is not None else PROFILE_RATING["count"]
            avg = float(pres.get("rating", PROFILE_RATING["value"])) \
                if pres is not None else PROFILE_RATING["value"]
            PROFILE_RATING["value"] = round(
                (avg * count + float(stars)) / (count + 1), 3)
            PROFILE_RATING["count"] = count + 1
            if pres is not None:
                pres["rating"] = PROFILE_RATING["value"]
                pres["rating_count"] = PROFILE_RATING["count"]
        return 201, {}

    # --- gravações de segurança (áudio passageiro / vídeo parceiro) ---
    # Precisa vir ANTES do detalhe de corrida (GET /rides/{id}), senão
    # /rides/{id}/recordings cairia no detalhe por startswith("/rides/").
    if path.startswith("/rides/") and path.endswith("/recordings"):
        r = _ride_by_path(path)
        if r is None:
            return 404, {"title": "Corrida não encontrada", "status": 404, "code": "not_found"}
        if method == "GET":
            recs = [x for x in STATE["recordings"] if x["ride_id"] == r["id"]]
            return 200, {"recordings": recs}
        if method == "POST":
            kind = body.get("kind")
            if kind not in ("AUDIO", "VIDEO"):
                return 422, {"title": "Tipo inválido", "status": 422, "code": "invalid_recording"}
            if kind == "VIDEO" and body.get("camera") not in ("FRONT", "REAR"):
                return 422, {"title": "Câmera obrigatória em vídeo",
                             "status": 422, "code": "invalid_recording"}
            duration = body.get("duration_ms") or 0
            size = body.get("size_bytes") or 0
            if duration < 1 or size < 1 or size > 15 * 1024 * 1024:
                return 422, {"title": "Duração/tamanho inválidos",
                             "status": 422, "code": "invalid_recording"}
            rec = {"recording_id": new_id(), "ride_id": r["id"], "kind": kind,
                   "camera": body.get("camera"), "duration_ms": duration,
                   "size_bytes": size, "mime": body.get("mime", "application/octet-stream"),
                   "created_at": iso()}
            STATE["recordings"].insert(0, rec)
            # demonstração: grava os bytes (base64) em disco, se enviados
            data_b64 = body.get("data_b64")
            if data_b64:
                import base64 as b64mod
                import pathlib
                d = pathlib.Path(__file__).resolve().parent / "demo_recordings"
                d.mkdir(exist_ok=True)
                (d / f"{rec['recording_id']}.{kind.lower()}").write_bytes(
                    b64mod.b64decode(data_b64))
            return 201, rec

    # --- pagamento PIX: confirmação do provedor (webhook na demo) ----------
    # O app NUNCA declara pago por conta própria: mostra "aguardando" e só
    # segue quando o servidor responde CONFIRMED. Este endpoint é o webhook
    # do PSP simulado (em produção é o PSP que chama o backend).
    if path.startswith("/rides/") and path.endswith("/payment/confirm"):
        r = _ride_by_path(path)
        if r is None:
            return 404, {"title": "Não encontrada", "status": 404, "code": "not_found"}
        if r["status"] != "FINALIZADA":
            return 409, {"title": "Corrida não finalizada", "status": 409,
                         "code": "ride_not_finished"}
        r["payment_status"] = "CONFIRMED"
        return 200, ride_view(r)

    # QA/console: por que esta corrida foi para A e não para B? Devolve a
    # rodada, o raio, os já ofertados e o score de cada candidato.
    if method == "GET" and path.startswith("/rides/") and path.endswith("/dispatch"):
        r = _ride_by_path(path)
        if r is None:
            return 404, {"title": "Não encontrada", "status": 404,
                         "code": "not_found"}
        st = _dispatch_state(r)
        evals = dispatch_engine.evaluate_candidates(
            _online_candidates(), origin=_ride_origin(r),
            fare=_ride_offer_amount(r), service=_ride_service(r),
            max_distance_km=st["radius_km"], exclude=set(st["excluded"]))
        return 200, {
            "ride_id": r["id"], "status": r["status"],
            "round": st["round"], "radius_km": st["radius_km"],
            "excluded": list(st["excluded"]),
            "retry_in_s": max(0, round(st.get("retry_at", 0) - now(), 1)),
            "fare": _ride_offer_amount(r), "service": _ride_service(r),
            "candidates": [{
                "driver_id": e.candidate.partner_id,
                "eligible": e.eligible,
                "reason": e.reason,
                "score": e.score,
                "distance_km": round(e.distance_km, 2),
                "eta_min": round(e.eta_min, 1),
                "min_fare": e.candidate.min_fare,
                "vehicle": e.candidate.vehicle,
                "idle_seconds": round(e.candidate.idle_seconds, 0),
                "components": {k: round(v, 4)
                               for k, v in e.components.items()},
            } for e in evals],
        }

    if path.startswith("/rides/") and method == "GET":
        r = _ride_by_path(path)
        if r is None:
            return 404, {"title": "Não encontrada", "status": 404, "code": "not_found"}
        advance(r)
        return 200, ride_view(r)

    # --- geocoding: pesquisa de endereços reais (passageiro) ---
    if method == "GET" and path == "/geocode":
        q = (query.get("q") or [""])[0]
        return _geocode(q)

    # --- convites de motoristas (3.8) ---
    if method == "GET" and path == "/invites/mine":
        return 200, {"invites": STATE["invites"]}

    if method == "POST" and path == "/invites":
        code = "10MAIS-" + uuid.uuid4().hex[:6].upper()
        invite = {
            "invite_id": new_id(),
            "invite_code": code,
            "status": "PENDING",
            "reward_hours": 12,
            "created_at": iso(),
        }
        STATE["invites"].insert(0, invite)
        return 201, invite

    # --- raspadinha de prêmios (3.8) ---
    if method == "GET" and path == "/scratch/campaigns":
        return 200, {"campaigns": STATE["scratch_campaigns"]}

    if method == "POST" and path == "/scratch/play":
        campaign_id = body.get("campaign_id")
        campaign = next((c for c in STATE["scratch_campaigns"] if c["id"] == campaign_id), None)
        if not campaign:
            return 404, {"title": "Campanha não encontrada", "status": 404, "code": "not_found"}
        
        # Verifica se o usuário já tem ticket para esta campanha
        existing = [t for t in STATE["scratch_tickets"].values() 
                   if t["campaign_id"] == campaign_id and t["user_id"] == "demo-user"]
        if len(existing) >= campaign["max_participations_per_user"]:
            return 409, {"title": "Limite de participações excedido", "status": 409, "code": "max_participations"}

        # Sorteia prêmio baseado nas probabilidades
        import random as _random
        prizes = [p for p in STATE["scratch_prizes"] if p["campaign_id"] == campaign_id and p["quantity_remaining"] > 0]
        if not prizes:
            ticket = {
                "id": new_id(),
                "campaign_id": campaign_id,
                "user_id": "demo-user",
                "prize_id": None,
                "result": "NON_WINNER",
                "status": "ISSUED",
                "scratched_at": None,
                "redeemed_at": None,
                "created_at": iso(),
            }
            STATE["scratch_tickets"][ticket["id"]] = ticket
            return 200, scratch_ticket_view(ticket)
        
        total_prob = sum(p["probability"] for p in prizes)
        rand = _random.random() * total_prob
        current = 0
        selected_prize = None
        for p in prizes:
            current += p["probability"]
            if rand <= current:
                selected_prize = p
                break
        
        if not selected_prize:
            selected_prize = prizes[-1]
        
        ticket = {
            "id": new_id(),
            "campaign_id": campaign_id,
            "user_id": "demo-user",
            "prize_id": selected_prize["id"] if selected_prize else None,
            "result": "WINNER" if selected_prize else "NON_WINNER",
            "status": "ISSUED",
            "scratched_at": None,
            "redeemed_at": None,
            "created_at": iso(),
        }
        STATE["scratch_tickets"][ticket["id"]] = ticket
        if selected_prize:
            selected_prize["quantity_remaining"] -= 1
        
        return 200, scratch_ticket_view(ticket)

    if method == "GET" and path.startswith("/scratch/tickets/") and path.endswith("/result"):
        ticket_id = path.split("/")[-2]
        ticket = STATE["scratch_tickets"].get(ticket_id)
        if not ticket:
            return 404, {"title": "Raspadinha não encontrada", "status": 404, "code": "not_found"}
        if ticket["status"] == "ISSUED":
            ticket["status"] = "SCRATCHED"
            ticket["scratched_at"] = iso()
        return 200, scratch_ticket_view(ticket)

    if method == "GET" and path == "/scratch/history":
        user_tickets = [scratch_ticket_view(t) for t in STATE["scratch_tickets"].values()
                        if t["user_id"] == "demo-user"]
        return 200, {"tickets": user_tickets}

    if method == "POST" and path == "/scratch/redeem":
        ticket_id = body.get("ticket_id")
        ticket = STATE["scratch_tickets"].get(ticket_id)
        if not ticket:
            return 404, {"title": "Raspadinha não encontrada", "status": 404, "code": "not_found"}
        if ticket["status"] != "SCRATCHED" or not ticket.get("prize_id"):
            return 409, {"title": "Prêmio não disponível para resgate", "status": 409, "code": "not_redeemable"}
        
        ticket["status"] = "REDEEMED"
        ticket["redeemed_at"] = iso()
        redemption = {
            "id": new_id(),
            "ticket_id": ticket_id,
            "user_id": "demo-user",
            "redeemed_at": ticket["redeemed_at"],
            "benefit_applied": ticket["prize_id"],
            "status": "REDEEMED",
        }
        STATE["scratch_redemptions"][redemption["id"]] = redemption
        return 200, redemption

    # --- parceiro: preferências de solicitações ---
    if path == "/partner/preferences" and method == "GET":
        return 200, {"services": list(STATE["service_prefs"]),
                     "min_fare": STATE["min_fare"]}

    if path == "/partner/preferences" and method == "PUT":
        services = body.get("services")
        if not isinstance(services, list) or not services:
            return 422, {"title": "Nenhum tipo ligado", "status": 422,
                         "code": "invalid_services"}
        allowed = {"MOTO", "MOTO_NEGOCIA"}
        chosen = []
        for s in services:
            if s not in allowed or s in chosen:
                continue
            chosen.append(s)
        if not chosen:
            return 422, {"title": "Tipo desconhecido", "status": 422,
                         "code": "invalid_services"}
        # Valor mínimo é opcional no PUT: os switches não o resetam.
        min_fare = STATE["min_fare"]
        if "min_fare" in body:
            raw = body.get("min_fare")
            try:
                value = float(raw)
            except (TypeError, ValueError):
                return 422, {"title": "Valor mínimo inválido", "status": 422,
                             "code": "invalid_min_fare"}
            if value < 0 or value > 500:
                return 422, {"title": "Valor mínimo inválido", "status": 422,
                             "code": "invalid_min_fare"}
            min_fare = round(value, 2)
        STATE["service_prefs"] = chosen
        STATE["min_fare"] = min_fare
        pres = STATE["presences"].get(DRIVER_DEFAULT)
        if pres is not None:
            pres["services"] = list(chosen)
            pres["min_fare"] = min_fare
        return 200, {"services": chosen, "min_fare": min_fare}

    # --- parceiro: pausa operacional (3.2) ---
    if method == "POST" and path == "/partner/break/start":
        minutes = int(body.get("minutes") or 180)
        # Em pausa o parceiro não recebe oferta (o despacho lê a presença).
        _set_presence_status(_driver_id(body.get("driver_id")), "PAUSA")
        return 200, {"started_at": iso(), "expires_at": iso(now() + minutes * 60)}

    if method == "POST" and path == "/partner/break/end":
        did = _driver_id(body.get("driver_id"))
        _set_presence_status(did, "ONLINE_DISPONIVEL")
        return 200, {}

    # --- parceiro: cadastro (3.7) ---
    if method == "PUT" and path == "/partner/profile":
        info = {
            "kyc_status": STATE["kyc_status"],
            "monetization_mode": STATE["mode"],
            "pass_expires_at": STATE["pass_expires_at"],
            "wallet_balance": STATE["wallet_balance"],
            "debt_cents": STATE["debt_cents"],
            **{k: body.get(k) for k in (
                "full_name", "phone_e164", "cnh_number", "cnh_category",
                "cnh_expiry", "vehicle_plate", "vehicle_model",
                "vehicle_year") if body.get(k) is not None},
        }
        STATE["partner_info"] = info
        return 200, {"partner": info}

    # --- parceiro: presença ---
    if method == "POST" and path == "/partner/online":
        if STATE["kyc_status"] != "APPROVED":
            return 403, {"title": "KYC pendente", "status": 403, "code": "kyc_not_approved"}
        # Presença real: sem posição não há como o passageiro encontrar o
        # parceiro. O servidor recusa em vez de inventar um ponto.
        lat, lon = body.get("lat"), body.get("lon")
        if lat is None or lon is None:
            return 422, {"title": "Posição obrigatória", "status": 422,
                         "code": "location_required"}
        did = _driver_id(body.get("driver_id"))
        old = STATE["presences"].get(did) or {}
        ts = now()
        # Fecha o trecho online anterior antes de reescrever a presença.
        _credit_online(did)
        # Tempo online só reinicia quando o parceiro realmente estava fora:
        # é a variável de justiça do despacho (anti-starvation).
        was_online = old.get("status") in (
            "ONLINE_DISPONIVEL", "OFERTA_PENDENTE", "EM_CORRIDA", "EM_ENTREGA", "PAUSA")
        self_prefs = did == DRIVER_DEFAULT
        STATE["presences"][did] = {
            "lat": float(lat), "lon": float(lon),
            "status": "ONLINE_DISPONIVEL", "at": ts,
            "online_since": old.get("online_since", ts) if was_online else ts,
            "rating": float(body.get(
                "rating", old.get("rating", PROFILE_RATING["value"]))),
            "rating_count": int(body.get(
                "rating_count", old.get("rating_count", PROFILE_RATING["count"]))),
            "acceptance_rate": float(body.get(
                "acceptance_rate", old.get("acceptance_rate", 0.95))),
            "completed_rides": int(body.get(
                "completed_rides", old.get("completed_rides", 301))),
            "vehicle": str(body.get("vehicle", old.get("vehicle", "Moto"))),
            "services": _presence_services(
                body.get("services"),
                old.get("services") or (
                    STATE["service_prefs"] if self_prefs
                    else ["MOTO", "MOTO_NEGOCIA"])),
            "min_fare": float(body.get(
                "min_fare",
                old.get("min_fare", STATE["min_fare"] if self_prefs else 0.0))),
            "route_deviation_m": float(body.get(
                "route_deviation_m", old.get("route_deviation_m", 0.0))),
            # Marcador do crédito de tempo online (desempenho semanal).
            "online_credit_at": ts,
        }
        return 200, {"mode": STATE["mode"], "pass_expires_at": STATE["pass_expires_at"]}

    if method == "POST" and path == "/partner/offline":
        did = _driver_id(body.get("driver_id"))
        _credit_online(did)  # conta o último trecho antes de sair
        STATE["presences"].pop(did, None)
        return 200, {}

    if method == "POST" and path == "/partner/heartbeat":
        points = body.get("points") or []
        if points:
            p = points[-1]
            if "lat" in p and "lon" in p:
                did = _driver_id(body.get("driver_id"))
                pres = STATE["presences"].get(did)
                if pres is not None:
                    _credit_online(did)
                    pres["lat"] = float(p["lat"])
                    pres["lon"] = float(p["lon"])
                    pres["at"] = now()
                    # Durante a corrida o heartbeat não devolve o parceiro à
                    # fila de despacho (senão ele receberia oferta em cima de
                    # uma viagem em andamento).
                    if pres.get("status") not in ("EM_CORRIDA", "EM_ENTREGA"):
                        pres["status"] = "ONLINE_DISPONIVEL"
        return 200, {}

    # --- parceiro: ofertas ---
    if method == "GET" and path == "/offers/mine":
        # O app real não manda id → "self". Os testes de despacho usam
        # driver_id para ver a oferta de cada candidato.
        did = _driver_id((query.get("driver_id") or [DRIVER_DEFAULT])[0])
        open_offers = sorted(
            (o for o in STATE["offers"].values()
             if o["status"] == "SENT"
             and o.get("driver_id", DRIVER_DEFAULT) == did),  # type: ignore[arg-type]
            key=lambda o: o["sent_at"])
        return 200, {"offers": [_offer_view(o) for o in open_offers]}

    # Fechamento de uma oferta que já saiu de /offers/mine (timeout): o app
    # precisa do motivo e da perda para explicar, em vez de sumir a tela.
    if method == "GET" and path.startswith("/offers/") and path.count("/") == 2:
        o = _offer_by_path(path)
        if o is None:
            return 404, {"title": "Não encontrada", "status": 404, "code": "not_found"}
        return 200, {
            "offer_id": o["id"], "ride_id": o["ride_id"],
            "status": o["status"],
            "loss": o.get("loss"),
        }

    if path.startswith("/offers/") and path.endswith("/accept") and method == "POST":
        o = _offer_by_path(path)
        if o is None:
            return 404, {"title": "Não encontrada", "status": 404, "code": "not_found"}
        if o["status"] != "SENT" or now() > o["timeout_at"]:
            return 409, {"title": "Indisponível", "status": 409, "code": "offer_unavailable"}
        r = STATE["rides"].get(o["ride_id"])
        # O despacho coloca a corrida em OFERTADA; BUSCANDO só aparece em
        # corridas antigas/simuladas. As duas aceitam a oferta viva.
        if r is None or r["status"] not in ("BUSCANDO", "OFERTADA"):
            o["status"] = "EXPIRED"
            return 409, {"title": "Indisponível", "status": 409, "code": "offer_unavailable"}
        o["status"] = "ACCEPTED"
        o["responded_at"] = now()
        did = o.get("driver_id", DRIVER_DEFAULT)
        _perf_track(did, "accepted")
        r["driver"] = "partner"
        r["partner_driver_id"] = did
        r["status"] = "ACEITA"
        r["accepted_at"] = now()
        r["last_phase_at"] = now()
        # Ponto de partida da moto para o percurso que o passageiro acompanha.
        r["driver_start"] = _partner_start(
            r["origin"]["lat"], r["origin"]["lon"], did)
        # A4: snapshot imutável na aceitação (enum do contrato PASSE|COMISSAO)
        r["pricing_mode_snapshot"] = _ride_pricing_mode()
        r["pricing_mode"] = _ride_pricing_mode()
        r["partner"] = {"name": "Você (parceiro demo)", "rating": 5.0,
                        "vehicle": "Moto"}
        _set_presence_status(did, "EM_CORRIDA")
        for other in STATE["offers"].values():
            if other["ride_id"] == r["id"] and other["status"] == "SENT":
                other["status"] = "EXPIRED"
        return 200, {}

    if path.startswith("/offers/") and path.endswith("/decline") and method == "POST":
        o = _offer_by_path(path)
        if o is None:
            return 404, {"title": "Não encontrada", "status": 404, "code": "not_found"}
        if o["status"] != "SENT":
            return 409, {"title": "Indisponível", "status": 409,
                         "code": "offer_unavailable"}
        did = o.get("driver_id", DRIVER_DEFAULT)
        # Recusa: penalização suave + próximo da fila imediatamente. A resposta
        # leva o que foi perdido (valor, coleta e aceite antes/depois).
        loss = _close_offer(o, "DECLINED", penalize=True)
        _set_presence_status(did, "ONLINE_DISPONIVEL")
        r = STATE["rides"].get(o["ride_id"])
        if r is not None:
            if r["status"] == "OFERTADA":
                r["status"] = "BUSCANDO"
            st = _dispatch_state(r)
            if did not in st["excluded"]:
                st["excluded"].append(did)
            _dispatch_next(r)
        return 200, {"loss": loss}

    # --- parceiro: transições (única via de domínio) ---
    if method == "POST" and path == "/partner/transitions":
        r = STATE["rides"].get(body.get("ride_id", ""))
        if r is None:
            return 404, {"title": "Não encontrada", "status": 404, "code": "not_found"}
        to = body.get("to")
        legal = {"A_CAMINHO": ["ACEITA"], "CHEGOU": ["A_CAMINHO"],
                 "EM_VIAGEM": ["CHEGOU"], "FINALIZADA": ["EM_VIAGEM"]}
        if to not in legal or r["status"] not in legal[to]:
            return 409, {"title": "Transição ilegal", "status": 409, "code": "illegal_transition"}
        if to == "EM_VIAGEM":
            # Relógio do trecho: a demo move a moto ao longo da rota a partir
            # daqui (percurso do destino).
            r["em_viagem_at"] = now()
        if to == "FINALIZADA":
            fare = body.get("fare_total")
            if not fare or fare <= 0:
                return 422, {"title": "Valor obrigatório", "status": 422, "code": "invalid_pricing"}
            r["fare_total"] = fare
            r["cash_declared"] = bool(body.get("cash_declared"))
            r["payment_status"] = "CONFIRMED" if r["cash_declared"] else "PENDING"
        r["status"] = to
        r["last_phase_at"] = now()
        if to == "FINALIZADA":
            _ledger_for_ride(r)
            # Terminou: o parceiro volta para a fila do despacho.
            _set_presence_status(
                r.get("partner_driver_id", DRIVER_DEFAULT), "ONLINE_DISPONIVEL")
        return 200, {}

    # --- passageiro: motoristas próximos (radar da fila) ---
    # O radar agora é real: presença/posição vêm da Edge Function `radar`
    # (Supabase). A demo não inventa motorista nenhum; se este endpoint for
    # chamado por um cliente antigo, ele diz exatamente isso.
    if method == "GET" and path == "/partners/nearby":
        # Radar real: só devolve parceiro que está online E com posição fresca
        # (heartbeat de 30 s, tolerância de 90 s). Sem ninguém online, a lista
        # vem vazia — o app diz "nenhum motorista", nunca inventa um.
        def _f(name: str, default: float) -> float:
            try:
                return float((query.get(name) or [default])[0])
            except (TypeError, ValueError):
                return default
        lat = _f("lat", -8.7607)
        lon = _f("lon", -63.9039)
        radius = _f("radius_km", 3.0)
        drivers = []
        for did, pres in STATE["presences"].items():
            if now() - pres["at"] > PRESENCE_FRESH_S:
                continue
            if pres.get("status") not in ("ONLINE_DISPONIVEL", "OFERTA_PENDENTE"):
                continue
            km = _haversine_km(lat, lon, pres["lat"], pres["lon"])
            if km > radius:
                continue
            # Privacidade: 3 casas (~110 m) e id pseudônimo; a identidade
            # só aparece quando a corrida é aceita.
            drivers.append({
                "driver_id": _pseudonym(did),
                "lat": round(pres["lat"], 3),
                "lon": round(pres["lon"], 3),
                "distance_km": round(km, 1),
                "available": True,
                "vehicle": pres.get("vehicle", "Moto"),
            })
        drivers.sort(key=lambda d: d["distance_km"])
        return 200, {"generated_at": iso(), "radius_km": radius,
                     "eligible_count": len(drivers), "drivers": drivers}

    # --- mapa: calor de chamadas (por zona, normalizado 0..1) ---
    if method == "GET" and path == "/heatmap":
        # Honestidade: esta API é de DEMONSTRAÇÃO. A resposta sempre declara
        # "demo": true e a origem; o app marca a camada com a marca d'água
        # DEMO. Um backend de produção não devolve o flag (ou devolve
        # demo: false) — e nunca devolve números inventados.
        zones = [dict(z) for z in (HEAT_ZONES if DEMO_HEAT else [])]
        # calor ao vivo: chamadas dos últimos 15 min esquentam a zona mais próxima
        recent = [h for h in STATE["heatmap_hits"] if now() - h["ts"] < 900]
        for z in zones:
            near = sum(1 for h in recent
                       if abs(h["lat"] - z["lat"]) < 0.01 and abs(h["lon"] - z["lon"]) < 0.01)
            z["weight"] = round(min(1.0, z["weight"] + 0.07 * near), 2)
            z["calls_last_hour"] += near
        return 200, {"generated_at": iso(), "zones": zones,
                     "demo": True, "source": "demo"}

    # --- parceiro: passe e carteira ---
    # --- demo: relógio (só com --time-travel) -------------------------------
    if method == "POST" and path == "/demo/clock":
        if not TIME_TRAVEL:
            return 403, {"title": "Relógio fixo", "status": 403,
                         "code": "time_travel_disabled"}
        try:
            offset = float(body.get("offset_s"))
        except (TypeError, ValueError):
            return 422, {"title": "offset_s obrigatório", "status": 422,
                         "code": "invalid_offset"}
        if abs(offset) > MAX_CLOCK_OFFSET_S:
            return 422, {"title": "Deslocamento grande demais", "status": 422,
                         "code": "invalid_offset"}
        _shift_clock(offset)
        return 200, {"now": iso(), "offset_s": offset}

    # --- parceiro: desempenho da semana ------------------------------------
    # Números que o servidor já viu (chamadas, aceites, recusas, tempo
    # conectado, posição no ranking e notas). Sem evento no período o campo
    # vem null — a tela diz "sem dados" em vez de inventar 0%.
    if method == "GET" and path == "/partner/performance":
        did = _driver_id((query.get("driver_id") or [DRIVER_DEFAULT])[0])
        return 200, _perf_view(did)

    if method == "GET" and path == "/partner/passes":
        return 200, {
            "mode": STATE["mode"],
            "active": {"pass_id": new_id(), "expires_at": STATE["pass_expires_at"],
                       "counting_strategy": "RELOGIO_CORRIDO"},
            "queue": [], "price": 10.0}

    if method == "POST" and path == "/partner/passes":
        return 201, {"pass_id": new_id(),
                     "checkout": {"pix": "00020126demo-sem-banco...", "card_url": "https://pago.local/demo"}}

    if method == "GET" and path == "/partner/wallet":
        return 200, {
            "balance": STATE["wallet_balance"], "debt_cents": STATE["debt_cents"],
            "statement": STATE["statement"][:20]}

    if method == "POST" and path == "/partner/wallet/withdraw":
        if STATE["debt_cents"] > 0:
            return 409, {"title": "Dívida pendente", "status": 409, "code": "debt"}
        if STATE["wallet_balance"] <= 0:
            return 409, {"title": "Saldo insuficiente", "status": 409, "code": "insufficient"}
        STATE["statement"].insert(0, {
            "entry_group_id": new_id(), "description": "Saque PIX",
            "direction": "D", "amount": STATE["wallet_balance"], "created_at": iso()})
        STATE["wallet_balance"] = 0.0
        return 202, {}

    # --- KYC (demo: aprova na hora) ---
    if method == "POST" and path == "/kyc/cases":
        STATE["kyc_status"] = "APPROVED"
        return 201, {"case_id": new_id(), "status": "AUTO_APPROVED",
                     "position": None, "sla": None}

    if path.startswith("/kyc/cases/") and method == "POST":
        return 201, {}

    # --- suporte/pagamento (stub) ---
    if method == "POST" and path == "/support/tickets":
        return 201, {}
    if method == "POST" and path == "/payments/ride":
        return 201, {"payment_id": new_id(),
                     "pix": {"qr": "data:image/png;base64,demo",
                             "copia_cola": "00020126demo5204000053039865802BR5913DEZEMAIS DEMO6009PORTO VELHO62070503***6304ABCD",
                             "expires_at": iso(now() + 900)}}

    return 404, {"title": f"Rota não implementada na demo: {method} {path}",
                 "status": 404, "code": "not_found"}

def _ride_by_path(path: str) -> dict | None:
    rid = path.split("/")[2]
    return STATE["rides"].get(rid)

def _offer_by_path(path: str) -> dict | None:
    oid = path.split("/")[2]
    return STATE["offers"].get(oid)

# ---------------------------------------------------------------------------
# HTTP (CORS obrigatório: os apps Flutter web chamam de outra origem)
# ---------------------------------------------------------------------------

class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):  # silencia access log poluído
        pass

    def _send(self, status: int, payload: dict) -> None:
        data = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers",
                         "authorization, content-type, idempotency-key")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, PUT, OPTIONS")
        self.end_headers()
        self.wfile.write(data)

    def do_OPTIONS(self):  # preflight
        self._send(204, {})

    def do_GET(self):
        self._handle("GET")

    def do_POST(self):
        self._handle("POST")

    def do_PUT(self):
        self._handle("PUT")

    def _handle(self, method: str) -> None:
        parsed = urlparse(self.path)
        body = {}
        if method in ("POST", "PUT"):
            length = int(self.headers.get("content-length") or 0)
            raw = self.rfile.read(length) if length else b""
            if raw:
                try:
                    body = json.loads(raw.decode("utf-8"))
                except (UnicodeDecodeError, json.JSONDecodeError):
                    # corpo malformado nunca derruba o servidor da demo
                    self._send(400, {"title": "JSON inválido", "status": 400, "code": "bad_request"})
                    return
        try:
            status, payload = route(method, parsed.path, parse_qs(parsed.query), body)
        except Exception as exc:  # nunca derruba o servidor da demo
            status, payload = 500, {"title": f"demo error: {exc}", "status": 500,
                                    "code": "demo_error"}
        # Acesso fica silencioso por padrão; DEMO_LOG=1 mostra o que o app
        # realmente pediu (depurar presença/oferta sem ler o código do app).
        if os.environ.get("DEMO_LOG"):
            print(f"{method} {parsed.path} -> {status}", file=sys.stderr,
                  flush=True)
        self._send(status, payload)

def _geocode(query: str) -> tuple[int, dict]:
    """Proxy do Nominatim com cache em memória. "Porto Velho" é o default
    para a praça piloto da demo."""
    q = (query or "").strip()
    if len(q) < 3:
        return 422, {"title": "Termo muito curto", "status": 422, "code": "invalid_query"}
    cache_key = q.lower()
    cached = STATE["geo_cache"].get(cache_key)
    if cached is not None:
        return 200, cached
    # Praça piloto: Porto Velho (RO). viewbox + bounded=1 mantém tudo dentro
    # da área de serviço sem anular a relevância do Nominatim.
    # viewbox = (minLon, maxLat, maxLon, minLat)
    viewbox = "-63.98,-8.68,-63.82,-8.82"
    params = urllib.parse.urlencode({
        "q": q, "format": "jsonv2", "limit": "5", "countrycodes": "br",
        "addressdetails": "1", "viewbox": viewbox, "bounded": "1",
    })
    url = f"https://nominatim.openstreetmap.org/search?{params}"
    req = urllib.request.Request(url, headers={"User-Agent": "10emais-demo/1.0 (contato@dezemais.app)"})
    try:
        with urllib.request.urlopen(req, timeout=8) as resp:
            raw = json.loads(resp.read().decode("utf-8"))
    except Exception:
        # offline ou rate-limited: devolve vazio sem quebrar o app
        return 200, {"query": q, "results": []}
    # Número do imóvel é obrigatório no pedido: vem do house_number do
    # Nominatim; quando o POI traz o número no display_name ("Shopping, 3288,
    # Avenida..."), ele é extraído de lá. Sem número, o app pede ao usuário.
    results = []
    for it in raw:
        addr = it.get("address") or {}
        number = addr.get("house_number")
        label = it.get("display_name", "")
        if not number:
            m = re.search(r",\s*(\d{1,6})\s*,", label)
            if m:
                number = m.group(1)
        results.append({
            "label": label,
            "lat": float(it["lat"]),
            "lon": float(it["lon"]),
            "house_number": number,
            "road": addr.get("road") or "",
            "suburb": addr.get("suburb") or addr.get("neighbourhood") or "",
            "city": addr.get("city") or addr.get("town") or "Porto Velho",
        })
    payload = {"query": q, "results": results}
    STATE["geo_cache"][cache_key] = payload
    return 200, payload

def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8787)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--time-travel", action="store_true",
                    help="libera POST /demo/clock (roteiro da semana de "
                         "desempenho); sem isso o relógio é fixo")
    args = ap.parse_args()
    global TIME_TRAVEL
    if args.time_travel:
        TIME_TRAVEL = True
    if TIME_TRAVEL:
        print("relógio de demonstração LIBERADO (POST /demo/clock) — "
              "não use isso fora de um ensaio")
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    print(f"API de demonstração (contrato openapi.yaml) em "
          f"http://{args.host}:{args.port} — estado em memória, não é o backend real")
    server.serve_forever()

if __name__ == "__main__":
    main()
