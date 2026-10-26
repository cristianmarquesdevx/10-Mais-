"""Despacho dinâmico — ranking do motorista ideal (SPECS §1.3 + critérios de produto).

O que este módulo NÃO faz: escolher por sorteio, por "quem chega primeiro" ou
olhar o modo de monetização (PASSE/COMISSÃO). O score é auditável e cada
componente é devolvido junto, para o console/QA explicar por que A veio antes
de B.

Critérios (pesos iniciais, calibráveis com dados reais):

    ETA até o embarque .... 0.40   distância ÷ velocidade média da praça
    avaliação ............. 0.20   só conta com n >= 20 (senão neutro)
    taxa de aceite ........ 0.15   janela de 30 dias
    tempo ocioso .......... 0.15   anti-starvation: parado há 30 min = máximo
    experiência ........... 0.05   quem tem menos corridas ganha um pouco
    qualidade da posição .. 0.05   desvio da rota direta

Filtros (não entram no score, eliminam o candidato):

    - tipo de veículo compatível com o serviço (moto ≠ carro)
    - serviço ligado nas preferências do parceiro
    - valor mínimo que o parceiro aceita (corrida abaixo → não recebe)
    - raio da rodada de despacho
    - já recebeu/recusou esta corrida na rodada atual

A escolha é SEQUENCIAL: o melhor recebe a oferta; recusa ou timeout → o
próximo da lista. Depois de 3 rodadas sem aceite, todos voltam a ser
elegíveis (com a taxa de aceite já reduzida pela recusa) — nunca exclusão
permanente.
"""
from __future__ import annotations

import math
from dataclasses import dataclass, field

# --- pesos (somam 1.0) -------------------------------------------------------
W_ETA = 0.40
W_RATING = 0.20
W_ACCEPTANCE = 0.15
W_IDLE = 0.15
W_EXPERIENCE = 0.05
W_ROUTE = 0.05

PICKUPSPEED_KMH = 22.0   # velocidade média de deslocamento na praça piloto
ETA_REFERENCE_MIN = 15.0  # acima disso, f(ETA) = 0
IDLE_CAP_SECONDS = 1800.0  # 30 min parado já é o máximo de "justiça"
NEWCOMER_RIDES = 500       # 500+ corridas → sem bônus de novato
RATING_MIN_COUNT = 20
ROUTE_DEVIATION_M = 2000.0

DEFAULT_RATING = 4.9
DEFAULT_RATING_COUNT = 0
DEFAULT_ACCEPTANCE = 0.95
DEFAULT_VEHICLE = "Moto"
DEFAULT_SERVICES = ("MOTO", "MOTO_NEGOCIA")


def clamp(v: float, lo: float = 0.0, hi: float = 1.0) -> float:
    return max(lo, min(hi, v))


def haversine_km(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    """Distância em linha reta — mesma base usada no raio do radar."""
    r = 6371.0
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp = math.radians(lat2 - lat1)
    dl = math.radians(lon2 - lon1)
    a = (math.sin(dp / 2) ** 2
         + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2)
    return 2 * r * math.asin(math.sqrt(a))


def f_eta(eta_min: float) -> float:
    return 1.0 - clamp(eta_min / ETA_REFERENCE_MIN)


def f_rating(rating: float, count: int) -> float:
    # Poucas avaliações não podem eleger ninguém: valor neutro até n>=20.
    if count < RATING_MIN_COUNT:
        return 0.7
    return clamp((rating - 3.5) / 1.5)


def f_acceptance(rate: float) -> float:
    return clamp(rate)


def f_idle(seconds: float) -> float:
    return clamp(seconds / IDLE_CAP_SECONDS)


def f_experience(completed_rides: int) -> float:
    return 1.0 - clamp(completed_rides / NEWCOMER_RIDES)


def f_route(deviation_m: float) -> float:
    return 1.0 - clamp(deviation_m / ROUTE_DEVIATION_M)


def vehicle_supports(vehicle: str | None, service: str) -> bool:
    """Moto só faz serviço de moto; carro não pega corrida de moto."""
    v = (vehicle or "").strip().lower()
    s = (service or "").strip().upper()
    if s.startswith("MOTO"):
        return "moto" in v or v in ("", "bike", "motorcycle")
    if s.startswith("CARRO") or s.startswith("CAR"):
        return "carro" in v or "car" in v or v in ("", "auto")
    return True


@dataclass
class Candidate:
    """Foto do parceiro no momento do despacho (nada de dado mutável)."""

    partner_id: str
    lat: float
    lon: float
    rating: float = DEFAULT_RATING
    rating_count: int = DEFAULT_RATING_COUNT
    acceptance_rate: float = DEFAULT_ACCEPTANCE
    idle_seconds: float = 0.0
    completed_rides: int = 0
    vehicle: str = DEFAULT_VEHICLE
    services: tuple[str, ...] = DEFAULT_SERVICES
    min_fare: float = 0.0
    route_deviation_m: float = 0.0


@dataclass
class Evaluation:
    candidate: Candidate
    distance_km: float
    eta_min: float
    score: float = 0.0
    components: dict[str, float] = field(default_factory=dict)
    eligible: bool = True
    reason: str | None = None


def evaluate_candidate(
    c: Candidate,
    *,
    origin: tuple[float, float],
    fare: float,
    service: str,
    max_distance_km: float,
) -> Evaluation:
    distance = haversine_km(origin[0], origin[1], c.lat, c.lon)
    eta_min = distance / PICKUPSPEED_KMH * 60.0

    def reject(reason: str) -> Evaluation:
        return Evaluation(c, distance, eta_min, eligible=False, reason=reason)

    if service not in c.services:
        return reject("service_disabled")
    if not vehicle_supports(c.vehicle, service):
        return reject("vehicle_mismatch")
    if fare < c.min_fare:
        return reject("below_min_fare")
    if distance > max_distance_km:
        return reject("out_of_radius")

    parts = {
        "eta": f_eta(eta_min),
        "rating": f_rating(c.rating, c.rating_count),
        "acceptance": f_acceptance(c.acceptance_rate),
        "idle": f_idle(c.idle_seconds),
        "experience": f_experience(c.completed_rides),
        "route": f_route(c.route_deviation_m),
    }
    score = (W_ETA * parts["eta"]
             + W_RATING * parts["rating"]
             + W_ACCEPTANCE * parts["acceptance"]
             + W_IDLE * parts["idle"]
             + W_EXPERIENCE * parts["experience"]
             + W_ROUTE * parts["route"])
    return Evaluation(c, distance, eta_min, round(score, 6), parts)


def evaluate_candidates(
    candidates: list[Candidate],
    *,
    origin: tuple[float, float],
    fare: float,
    service: str,
    max_distance_km: float,
    exclude: set[str] | None = None,
) -> list[Evaluation]:
    """Avalia TODOS (para explicar a rodada) e ordena elegíveis primeiro."""
    excluded = exclude or set()
    out: list[Evaluation] = []
    for c in candidates:
        if c.partner_id in excluded:
            out.append(Evaluation(c, 0.0, 0.0, eligible=False, reason="already_offered"))
            continue
        out.append(evaluate_candidate(
            c, origin=origin, fare=fare, service=service,
            max_distance_km=max_distance_km))
    out.sort(key=_sort_key)
    return out


def _sort_key(e: Evaluation):
    # Elegíveis primeiro, maior score, mais tempo ocioso (desempate de
    # justiça) e, por fim, id estável — sem isso a ordem variava entre polls.
    return (
        0 if e.eligible else 1,
        -e.score,
        -e.candidate.idle_seconds,
        e.eta_min,
        e.candidate.partner_id,
    )


def rank_candidates(
    candidates: list[Candidate],
    *,
    origin: tuple[float, float],
    fare: float,
    service: str,
    max_distance_km: float,
    exclude: set[str] | None = None,
) -> list[Evaluation]:
    return [e for e in evaluate_candidates(
        candidates, origin=origin, fare=fare, service=service,
        max_distance_km=max_distance_km, exclude=exclude) if e.eligible]


def score_of(parts: dict[str, float]) -> float:
    """Mesma conta do evaluate, exposta para simulações/console."""
    return (W_ETA * parts["eta"]
            + W_RATING * parts["rating"]
            + W_ACCEPTANCE * parts["acceptance"]
            + W_IDLE * parts["idle"]
            + W_EXPERIENCE * parts["experience"]
            + W_ROUTE * parts["route"])
