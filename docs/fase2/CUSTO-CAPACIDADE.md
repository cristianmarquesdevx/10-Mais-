# Custo e capacidade — 1k / 10k / 100k corridas/dia (refino Fase 2)

> Preços pesquisados em **fontes oficiais, 10/2026** (ver URLs). Câmbio de
> referência US$ 1 ≈ R$ 5,50 [VERIFICAR no mês do orçamento]. Todo número aqui é
> **estimativa de dimensionamento**, não medição — as primeiras medições reais
> saem nos primeiros 30 dias (SLOS.md).

## 1. Modelo de tráfego (derivado do contrato — **validado pelo simulador**)

Unidade: **corrida**. Os fatores abaixo são produzidos pelo **simulador de
despacho** [`scripts/dispatch_sim.py`](../../scripts/dispatch_sim.py)
(Monte Carlo das regras da SPECS.md §1 rodadas/leva-N/timeout e §4 recálculo
DE ETA; 50k corridas, seed 42 — reproduzível):

```
python3 scripts/dispatch_sim.py --rides 50000 --seed 42
```

| Item | Chamadas/msgs por corrida | Nota |
|---|---:|---|
| Edge Functions (API) | **~29** (p95 40) | recálculo de ETA ~16, transições 4, poll fallback ~2,4, despacho ~1,1, ciclo de vida ~5,3 |
| Realtime (msgs) | **~28,5** (p95 40) | updates de ETA ~16 + estado da corrida 6 + ofertas/resultado ~4,8 + negociação/cancel |
| **Google Routes (eventos pagos)** | **21,3 como SPECS · 5,55 com alavancas** | ver §1.1 — era o número errado do modelo manual |
| Pontos de posição | ~450 | 12/min × ~25 min de janela ativa + 50% de ociosidade (PostgREST, fora do Edge) |
| Linhas novas no banco (exceto posições) | ~50 | rides, eventos, ofertas, ledger, pagamentos |
| Parceiros ativos por praça | ~0,6 × pico de corridas simultâneas | liquidez RSK-005 |

### 1.1 Revisão pelo simulador — discrepância encontrada e corrigida

O modelo manual anterior estimava **3,8 ComputeRoutes/corrida**. O simulador
mostrou que a SPECS, **como escrita**, dispara muito mais:

| Origem de chamada paga | eventos/corrida |
|---|---:|
| Recálculos de ETA (4 fases + 90 s em viagem ≈ 10,7 + virada 0,30 + desvio 0,25) | ~15,9 |
| Matriz do despacho (f(ETA) por candidato elegível, SPECS §1.3) | ~4,4 |
| Rota de precificação origem→destino | 1,0 |
| **Total como SPECS** | **~21,3** (≈ 5,6× o modelo manual) |

**Correção de política de cache (pesquisa 10/2026):** a regra dos 30 dias do
Google cobre **apenas valores de lat/long**, não o conteúdo completo da rota
(geometria/duração) — não existe estratégia de cache que reduza essas
chamadas. As fontes são: [Routes API policies](https://developers.google.com/maps/documentation/routes/policies)
e [pricing](https://developers.google.com/maps/billing-and-pricing/pricing)
(tiers: Essentials US$ 0,005/evento 0–100k/mês c/ 10k grátis; traffic-aware
(Pro) US$ 0,010 c/ 5k grátis; decaimento por volume até US$ 0,00038 acima de
5M — o simulador aplica os tiers, não o preço cheio).

**Alavancas recomendadas (decisão de produto, registro aqui antes do orçamento):**

| # | Alavanca | Efeito | Risco |
|---|---|---|---|
| L1 | ETA em viagem (gatilho 90 s) c/ **modelo local** sobre o GPS próprio (distância restante ÷ velocidade observada) — provedor só nos gatilhos (a) virada e (d) fases | −10,7 eventos/ride | ETA menos preciso no trânsito parado; mitigação: reavaliação a cada virada/fase mantida |
| L2 | f(ETA) do despacho c/ estimativa local (straight-line ÷ velocidade da praça) em vez de matriz paga | −4,4 eventos/ride | troca ranqueamento por proxy barato — invariante de neutralidade intacta (não toca no modo) |
| — | **Soma (L1+L2)** | **21,3 → 5,55 eventos/ride (−74%)** | — |

As alavancas mudam a SPECS §1.3/§4 e estão **pendentes de decisão no GATE 2**;
sem elas, o orçamento do Cenário A multiplica ~3–4× (tabelas §2/§3 já
mostram os dois cenários).

**Decisão de arquitetura embutida no modelo:** heartbeat/posições entram via
**PostgREST direto** (insert em lote protegido por RLS), **não** via Edge Function —
isso mantém o consumo de invocações proporcional a corridas, não a parceiros
online. Realtime fica reservado a ofertas e estado de corrida (não posição por ponto).

## 2. Cenário A — 1.000 corridas/dia (30k/mês) · praça piloto

| Rubrica | Detalhe | Custo mensal (US$) |
|---|---|---:|
| Supabase **Pro** | US$ 25 · 8 GB DB, 250 GB egress, **2M invocações Edge**, **5M msgs Realtime**, 500 conexões de pico | 25 |
| Edge excedente | 0,87M/mês < 2M incluso | 0 |
| Realtime | 0,85M msgs < 5M | 0 |
| Banco/posições | ~450k pontos/dia × 7 d retenção ≈ 3M linhas vivas (~300 MB); crescimento líquido ~300 MB/mês | 0 (no 8 GB) |
| **Google Routes (§1.1)** | 639k eventos/mês como SPECS → **US$ 2.466** (Essentials) – **US$ 4.982** (traffic-aware); com alavancas L1+L2 → **US$ 716 – 1.482** | 716 – 4.982 |
| Places (busca de destino) | ~1,5 buscas/ride: Autocomplete US$ 0,00283 (10k grátis/mês) + Place Details Essentials US$ 0,005 em sessão | ~60 – 120 |
| Geocoding | US$ 0,005 (10k grátis) | ~10 |
| Push FCM | gratuito | 0 |
| PSP (Pagar.me) | 0,99% PIX — repassado ao usuário no MVP-A [VERIFICAR comercial] | ~0,12/ride |
| **Total plataforma** | | **com alavancas: ≈ US$ 840 – 1.650/mês · como SPECS: ≈ US$ 2.570 – 5.140/mês** |

**Conclusão A (revisada):** com as alavancas da §1.1 o Google continua
dominando (≈75–90%) e o quadro do modelo manual original se mantém
(**≈ R$ 4,6 – 9,1 mil**). **Sem** as alavancas, o custo multiplica ~3×:
**≈ R$ 14 – 28 mil/mês** — ainda viável para 1k corridas/dia, mas paga o
triplo pelo mesmo produto. Supabase Pro segue folgado. Custo por corrida:
**US$ 0,028 – 0,055** com alavancas · **US$ 0,086 – 0,171** como SPECS.
**Decisão registrada:** adotar L1+L2 (mudança de SPECS §1.3/§4) — validar
precisão do ETA local nos primeiros 30 dias (SLOS) antes de fixar.

## 3. Cenário B — 10.000 corridas/dia (300k/mês)

| Rubrica | Detalhe | Custo mensal (US$) |
|---|---|---:|
| Supabase Pro | Edge 8,69M → **+US$ 13,4** (excedente 6,69M × US$ 2/M); Realtime 8,54M → **+US$ 8,85** (excedente 3,54M × US$ 2,50/M); egress e banco ainda no Pro | ~47 |
| Realtime | parceiros online 600–800 > 500 conexões de pico → Spend Cap off (+US$ 10/1k pico) ou confiar em batch (decisão: batch) | 0 – 20 |
| **Google Routes (§1.1)** | 6,39M eventos/mês como SPECS → **US$ 10.077 – 20.190**; com alavancas (1,67M) → **US$ 4.548 – 9.145** | 4.548 – 20.190 |
| Places + Geocoding | escalam linearmente | ~600 – 1.200 |
| **Total** | | **com alavancas: ≈ US$ 5,2 – 10,5 mil/mês · como SPECS: ≈ US$ 10,7 – 21,5 mil/mês** |

**Conclusão B (revisada):** Google é **88–95% do custo de infra** (mais
dominante do que a estimativa anterior). Com alavancas o número converge
perto do previsto (≈ US$ 6,3 – 11,4 mil); sem elas, o plano B da Fase 0
(OSM auto-hospedado: VPS US$ 10–30 + preprocessing + operação) vira conta
positiva **antes** do esperado, mas exige **ADR novo** (licença ODbL +
share-alike da base derivada + proibição de servidor OSM público em
produção + perda de camadas Google em um mesmo mapa). **Gate:** ao cruzar
~2.000 corridas/dia firmes, medir rotas reais/ride no console Google —
com o simulador, **21,3 (sem alavanca) ou 5,55 (com) eventos/ride** é a
métrica a comparar (não mais "3,8").

## 4. Cenário C — 100.000 corridas/dia (3M/mês)

| Rubrica | Detalhe | Custo mensal (US$) |
|---|---|---:|
| Google Routes | US$ 57k – 102k/mês → **inviável como padrão**: routing deve ser OSM self-hosted (Valhalla/OSRM multi-VPS ~US$ 200–500 + engenharia dedicada) | 200 – 500 + eng. |
| Banco | ~50M linhas/mês (exceto posições que dropam); Pro deixa de ser suficiente → Postgres dedicado (cotação Supabase Enterprise ou self-host com pooler) | cotação |
| Realtime/posições | gate RSK-007 dispara de vez: posições em serviço dedicado (kafka/fila + DB separado), não no Postgres primário | projeto próprio |
| API/Edge | workers em runtime próprio (ou Cloudflare Workers) — 30M invocações/mês não cabem no mental model do Pro | projeto próprio |
| **Total** | | **≈ US$ 0,5 – 1,5 mil de infra + equipe** |

**Conclusão C:** 100k/dia é **arquitetura nova**, não "escala do Pro". É um
problema de sucesso comercial — dimensionar aqui é guardar o desenho das
fronteiras já previstas (Realtime dedicado, OSM, Postgres dedicado) e não
comprometer o MVP-A com elas hoje.

## 5. Gates de decisão (quando revisar)

| Marco | Ação |
|---|---|
| **Antes do módulo 1 (Fase 4)** | Fixar alavancas L1+L2 na SPECS §1.3/§4 e medir precisão do ETA local vs provedor em staging (gate do orçamento) |
| 2k corridas/dia firmes | Heartbeat 100% PostgREST; medir **eventos Routes/ride reais** no console vs simulador (21,3 como SPECS / 5,55 com alavancas) |
| 5k corridas/dia firmes | Spend Cap off + posições em instância/banco separado se p95 > 2 s (RSK-007) |
| 10k corridas/dia firmes | **ADR-001 revisado** (OSM self-host) + Postgres dedicado |
| Qualquer momento | cota diária Google > 120% do previsto (T-18) → alerta e revisão |

## Fontes (10/2026)

- Supabase preços e quotas: https://supabase.com/pricing · https://supabase.com/docs/guides/platform/billing-on-supabase (Pro US$ 25; 8 GB; 250 GB egress; 2M invocações Edge; 5M msgs Realtime; 500 conexões de pico; add-ons US$ 0,125/GB, US$ 0,09/GB, US$ 2/M, US$ 2,50/M, US$ 10/1k)
- Realtime limites: https://supabase.com/docs/guides/realtime/limits (500 msg/s com Spend Cap; 2.500 sem)
- Google preços por SKU (tiers com decaimento por volume + free tier 10k/5k): https://developers.google.com/maps/billing-and-pricing/pricing (Routes Essentials US$ 0,005/evento 0–100k · Routes traffic-aware US$ 0,010 · Geocoding US$ 0,005 · Autocomplete US$ 0,00283 · Place Details Essentials US$ 0,005; crédito mensal de US$ 200 encerrado em 28/02/2025)
- Política de cache (limita a lat/long a 30 d; conteúdo de rota não é cacheável): https://developers.google.com/maps/documentation/routes/policies
- Limites Routes: https://developers.google.com/maps/documentation/routes/usage-and-billing (3.000 req/min; TRAFFIC_AWARE cobra como Pro)
- Supabase excedentes: https://supabase.com/docs/guides/platform/manage-your-usage/edge-function-invocations (US$ 2/M) · https://supabase.com/docs/guides/realtime/pricing (US$ 2,50/M · US$ 10/1k pico)
- Simulador de despacho (deste gate): `scripts/dispatch_sim.py` — SPECS §1/§4, seed fixa
