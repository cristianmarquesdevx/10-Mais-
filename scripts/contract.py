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

# --- KYC (cadastro do parceiro) ---------------------------------------------

#: Janela humana de revisão do KYC, em HORAS DO FUSO DA PRAÇA
#: (`PRM-kyc.review_inicio_h` .. `PRM-kyc.review_fim_h`).
#:
#: O prazo de um caso NÃO é um temporizador: é o primeiro instante que cumpre
#: a antecedência mínima dentro da janela em que há gente revisando. Prometer
#: "2 h" às 23h30 — sem ninguém reviewing — seria uma promessa falsa.
KYC_REVIEW_START_H = 7
KYC_REVIEW_END_H = 23

#: Antecedência mínima do SLA (`PRM-kyc.sla_antecedencia_h`): o prazo é
#: pelo menos X horas à frente do momento em que o caso entrou na fila.
KYC_SLA_LEAD_H = 2

# --- KYC: o Storage dos documentos -------------------------------------------

#: Bucket PRIVADO onde o app do parceiro sobe a foto do documento.
#:
#: O bucket é privado de propósito: o GET do objeto exige JWT e política de
#: RLS — nenhuma URL anônima entrega documento de parceiro.
KYC_STORAGE_BUCKET = "kyc-docs"

#: Prefixo da PASTA do parceiro dentro do bucket.
#:
#: O path do objeto é `<prefixo>/<partner_user_id>/<case_id>/<doc>_<ms>.jpg`
#: (ex.: `kyc/<uid>/<case>/CNH_1700000000000.jpg`). A segunda pastinha é o
#: uid do DONO: é dela que a RLS tira a conclusão de quem pode ler e escrever.
KYC_STORAGE_PATH_PREFIX = "kyc"

# --- KYC: os motivos padronizados de recusa ----------------------------------

#: Motivos padronizados de recusa (e de pedido de reenvio) do KYC.
#:
#: Recusa sem motivo padronizado é recusa sem ação possível para o parceiro:
#: o código é o que a tela dele mostra. O console da operação oferece esta
#: lista (a pessoa escolhe, não digita); `scripts/test_contract.py` confere
#: que a lista do app continua igual à daqui — um código novo entra nos dois
#: lugares ou em nenhum.
KYC_REJECTION_CODES = (
    "CNH_ILEGIVEL",
    "CNH_VENCIDA",
    "DOC_INCOMPLETO",
    "FOTO_INVALIDA",
    "COMPROVANTE_INVALIDO",
    "DADOS_DIVERGENTES",
)

# --- KYC: a qualidade da foto do documento ------------------------------------

#: Limiar de BORRÃO da foto do documento (F9): a variância do Laplaciano
#: abaixo disto é foto borrada.
#:
#: É uma heurística de CLIENTE (o app avisa o parceiro e mostra a medida à
#: operação), não uma regra do servidor: quem aprova é a pessoa. O mesmo
#: número vive em `app/parceiro/lib/src/media/document_quality.dart`
#: (`kycBlurThreshold`), e `scripts/test_contract.py` confere que os dois
#: continuam iguais.
KYC_BLUR_THRESHOLD = 120

#: Limiar de REFLEXO da foto do documento (F9): a fração de pixels estourados
#: (branco queimado pelo flash) acima disto é foto com reflexo.
#:
#: Mesmo par com o app (`kycGlareRatioThreshold`) — ver a nota acima.
KYC_GLARE_RATIO_THRESHOLD = 0.10
