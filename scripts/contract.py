"""Contrato do produto em UM lugar só (SPECS §1.1 e §1.5).

Por que este arquivo existe
---------------------------
Os parâmetros que definem o comportamento de rua (a janela da oferta, o
intervalo do heartbeat, a tolerância da presença) estavam escritos em
vários lugares: o SPEC, o `seed.sql`, as migrations, a API de demonstração
e o simulador de despacho. Um deles divergiu — o banco local ficou com a
janela da oferta em **60 s** enquanto todos os outros diziam **15 s** — e
ninguém percebeu: o passageiro passava a esperar 4× mais por um motorista
que talvez nunca visse a oferta, e o E2E "passava" só porque a janela
estava inflada.

Agora os valores vivem aqui, e `scripts/test_contract.py` confere que o
SQL e a documentação continuam batendo com eles. Um desvio passa a falhar
no teste, não em produção.

A fonte de verdade do **contrato** é `docs/fase2/SPECS.md`; este arquivo é
a cópia executável dele.
"""
from __future__ import annotations

# --- despacho ---------------------------------------------------------------

#: Janela para o parceiro responder a oferta (`PRM-oferta.timeout`).
#: O servidor é o dono do prazo: o app só conta regressivamente.
OFERTA_TIMEOUT_S = 15

#: Raio inicial do despacho, em km (`PRM-match.r0`), e o passo (`PRM-match.passo`).
MATCH_R0_KM = 2.0
MATCH_PASSO_KM = 1.0
MATCH_RMAX_KM = 8.0

# --- presença ---------------------------------------------------------------

#: Intervalo do heartbeat do parceiro (`PRM-hb.intervalo`).
PRESENCE_HEARTBEAT_S = 30

#: Tolerância da presença (`PRM-hb.tolerancia`): só quem deu sinal de vida
#: nos últimos 90 s aparece no radar do passageiro.
PRESENCE_FRESH_S = 90
