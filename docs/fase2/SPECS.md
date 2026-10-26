# 10 é + — Specs algorítmicas (Fase 2, Parte 4/5)

Todas as funções abaixo são puras/testáveis e parametrizadas por `city_configs` (T7). Nenhum valor é hardcoded.

## 1. Despacho (matching) — Edge Function `dispatch`

### 1.1 Rodadas de despacho

A cada corrida em `BUSCANDO`, o dispatch executa rodadas até `rmax`:

```
R(0) = PRM-match.r0 (2 km); R(n+1) = R(n) + PRM-match.passo (1 km) ≤ PRM-match.rmax (8 km)
timeout de rodada = PRM-oferta.timeout (15 s)
```

Candidatos (SQL, indexado por GiST em `partner_presence.last_position`):

```sql
SELECT p.user_id, pr.last_position, p.rating_avg, p.acceptance_rate, pr.last_heartbeat_at
  FROM partners p JOIN partner_presence pr ON pr.partner_user_id = p.user_id
 WHERE p.city_id = @city AND p.kyc_status = 'APPROVED' AND p.deleted_at IS NULL
   AND pr.online_status = 'ONLINE_DISPONIVEL'
   AND ST_DWithin(pr.last_position, @origin, @radius_m)
   AND pr.last_heartbeat_at > now() - interval '90 seconds'   -- PRM-hb.intervalo+grace
```

### 1.2 Estratégia de oferta: **leva simultânea limitada (N=3)**

| Opção | Prós | Contras | Veredito |
|---|---|---|---|
| Sequencial 1 a 1 | Sem corrida fantasma | p95 = N×15 s (3 parceiros = 45 s > SLO 10 s) | Descartada |
| Broadcast irrestrito | Velocidade | Várias aceitações simultâneas, anti-starvation ruim, ruído | Descartada |
| **Leva de N=3 melhores** | p95 ≤ 15 s; 1 vencedor via `FOR UPDATE` | ~2 avisos "já tomada" por corrida | **Escolhida** |

Na rodada: ordenar por score, ofertar aos 3 primeiros (`fn_dispatch_offer` × 3); o `fn_offer_accept` serializa por `FOR UPDATE` na corrida — o primeiro vence, os demais recebem `offer_unavailable`.

> **Implementado hoje (`scripts/dispatch.py` + `scripts/demo_api.py`): oferta sequencial.**
> Decisão de produto do dono do app: o melhor recebe primeiro, recusa/timeout de
> 15 s → próximo da lista, até esgotar o raio (2 → 8 km). A leva de 3 continua
> sendo o alvo do Edge Function em produção para caber no SLO de 10 s; o score,
> os filtros e a reoferta são os mesmos nos dois modos, então a troca é só no
> número de ofertas simultâneas.

### 1.3 Score (neutralidade ao modo: SEM `monetization_mode` na fórmula — auditoria obrigatória)

```
score = w1·f(ETA) + w2·f(rating) + w3·f(aceitação) + w4·f(ociosidade) + w5·f(rota)
pesos iniciais: w1=0.40, w2=0.20, w3=0.15, w4=0.15, w5=0.10  [calibrar com dados]
```

Normalização (todas as entradas em [0,1], quanto maior melhor):
- `f(ETA) = 1 − clamp(eta_min / 15, 0, 1)` — **alavanca L2 (GATE 2):** ETA estimado localmente (distância retilínea ÷ velocidade média da praça), **não** o provedor de rotas — 4,4 eventos Google/ride economizados sem tocar na neutralidade ao modo. Em staging, comparar com provedor: se o ranqueamento divergir > 10% dos top-3, revisar.
- `f(rating) = clamp((rating_avg − 3.5) / 1.5, 0, 1)` — só星光 com n ≥ 20 conta; abaixo disso 0.7 (neutro).
- `f(aceitação) = acceptance_rate` (janela 30 d).
- `f(ociosidade) = clamp(segundos_ocioso / 1800, 0, 1)` — **anti-starvation**: quem está parado há mais de 30 min pesa máximo; é a variável de justiça.
- `f(rota) = 1 − desvio_do_caminho / 2000 m` — qualidade da posição (desvio da rota direta).

Desempate: maior `f(ociosidade)`, depois menor ETA. Reoferta: a cada rodada exclui os já ofertados; 3 rodadas sem aceite → nova rodada com todos elegíveis (penalização suave por recusa sistemática = reduzir `f(aceitação)`; **nunca** exclução total).

> **Timeout conta como recusa (soft).** Deixar os 15 s estourarem aplica a mesma
> redução de 3% na `acceptance_rate` do parceiro — senão ignorar a oferta sairia
> mais barato do que apertar "Recusar". Todo fechamento (`DECLINED`/`EXPIRED`)
> grava o que o parceiro deixou passar — valor congelado, coleta, corrida e a
> taxa de aceite antes/depois (`OfferLoss` no contrato) — e o app P3 mostra esse
> resumo ao motorista antes de voltar ao painel, para a consequência não ser
> invisível.

### 1.4 Entregas (MVP-B)

Mesmo algoritmo; candidatos filtrados por `service_type` compatível e `vehicles.category`; raio inicial menor (3 km) por coleta; `batching` opcional: aceitar 2ª coleta se desvio ≤ 30% e destino a ≤ 2 km do primeiro destino.

## 2. Motor de preço

```
tarifa = max(piso, base + km·t_km + min·t_min + espera + extras) × multiplicador + taxas
```

- Todos os componentes em `city_configs` por cidade × service_type (ex.: `PRM-preco.base`, `.t_km`, `.t_min`, `.espera_min`, `.piso`).
- `espera`: minutos de espera do passageiro no embarque após CHEGOU (> 3 min) × tarifa de espera.
- **Multiplicador de demanda** (por célula H3 res 9, janela 15 min):

```
razão = demanda (pedidos abertos na célula) / oferta (parceiros ONLINE_DISPONIVEL na célula+vizinhança)
m = clamp(1 + 0.25 × (razão − 1), 1.0, PRM-preco.m_max (1.8))   # linear amortecida
suavização: m_efetivo = 0.7 × m_anterior + 0.3 × m   (evita oscilação 1.0→1.8→1.0)
```

- Transparência: a UI exibe "tarifa com aumento de demanda: R$ X" quando `m > 1.15`; nunca "surge" oculto.
- Piso/repasse do passageiro que negocia: proposta mínima sugerida = `0.7 × tarifa` (configurável), abaixo disso a API responde `422 below_floor`.
- **Entregas (REQ-004, interpretação A aprovada):** `piso = PRM-entrega.piso (R$ 8,00)`; a estratégia B (faixa diferenciada acima de R$ 8) existe como `PRM-entrega.regime ∈ {PISO, FAIXA}` — mesma fórmula com `faixas` de km/troca.
- **Nunca cobra:** corrida cancelada, falha do sistema, viagem de teste (`PRM-teste.numeros`).
- Simulador: função SQL pura `fn_price_simulate(city, km, min, wait_min, surge, regime)` usada pelo console (K5) antes de publicar vigência — mesma implementação do cálculo real.

## 3. Negociação (D2)

- Passageiro propõe (`PROPOSE`): valor ≥ `0.7 × tarifa` e ≤ `3 × tarifa`; rate limit: 3 negociações abertas/h (`PRM-neg.max_h`).
- Parceiro vê a proposta como oferta com `offered_amount` do proposto; pode **aceitar** ou **contrapropor** (`COUNTER`, ≥ piso); máx. 3 rounds; cada round expira em 60 s (`PRM-neg.round_ttl`).
- Expiração sem aceite → corrida volta a `BUSCANDO` em modo tarifa (o passageiro pode pedir pela tarifa cheia).
- **Anti-colusão:** par (passageiro, parceiro) com ≥ 3 corridas negociadas em 24 h → bloqueio temporário de negociação entre eles + flag de revisão (nunca despacho penalizado).
- **Anti-dumping:** preço final negociado abaixo de `0.5 × tarifa` → marcado para auditoria amostral; passageiro com 5+ cancelamentos em 7 d não abre negociação (usa tarifa).

## 4. ETA e recálculo

- Base: provedor de rotas (R1) com tráfego quando disponível; **servidor calcula sempre** (o passageiro nunca calcula ETA do parceiro).
- Correção estatística local: `eta_final = eta_base × p95_ratio(trecho)` com histórico por origem×destino (aprende atrasos reais de Porto Velho); inicializa em 1.0.
- **Recálculo sob demanda** (nunca polling 15 s — armadilha de custo US$ 15k/mês): (a) virada de rota detectada (≥ 15% de mudança no traçado), (b) a cada 90 s em viagem, (c) desvio > 200 m do traçado, (d) a cada nova fase (ACEITA→A_CAMINHO→CHEGOU).
  - **Alavanca L1 (GATE 2):** o gatilho (b) de 90 s usa **modelo local** (distância restante ÷ velocidade observada do próprio GPS do parceiro); o provedor de rotas é chamado **só** em (a), (c) e (d). −10,7 eventos Google/ride. O `eta_final` continua passando pela correção `p95_ratio(trecho)` acima. Política Google 10/2026: conteúdo de rota não é cacheável (só lat/long 30 d) — por isso a ETA local não deriva de nada armazenado do Google.
- GPS ruim: snap-to-road no servidor (PostGIS `ST_ClosestPoint` em ways) + descarte de outliers (velocidade > 130 km/h ou salto > 500 m em < 5 s); `stale_after` na presença expõe a frescor à UI.
- Alarme ≤ 4 min (REQ-008): o servidor avalia o cross do threshold a cada atualização de ETA; dispara **1 evento idempotente por corrida** com histerese (re-arm só se ETA > 360 s).

## 5. Invariantes auditáveis (QA)

1. Score do despacho não contém `monetization_mode` (teste estático no CI: grep no código + simulação com parceiros idênticos em modos distintos → distribuição igual).
2. `multiplicador` sempre dentro dos limites da cidade (property test).
3. Toda cobrança passa por `max(piso, ...)`; nenhuma corrida concluída < piso (exceto teste).
4. ETA é monotônico para a mesma fase (não "anda para trás" sem mudança de rota > limiar).
