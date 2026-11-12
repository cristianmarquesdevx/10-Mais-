# Documento Mestre — App de Mobilidade (Porto Velho/RO)

> Fonte única de verdade do produto. Atualizado a cada fase/aprovação.
> Status: **FASE 1 APROVADA (GATE 1)** · **FASE 2 (Arquitetura) APROVADA (GATE 2)** — entrega 5/5, revisão adversarial concluída (suíte 0005: 18/18 verificações em Docker), orçamento fechado com validação pelo simulador de despacho (alavancas L1+L2 registradas), cadeia SQL em script único de CI. **FASE 3 EM ANDAMENTO — apps passageiro (11 telas C1–C11, 24/24 testes) e parceiro (7 telas P1–P7, 18/18 testes) entregues**, ambos com `dart analyze` 0 issues, build web/APK verde sobre o mesmo OpenAPI e **fluxo completo passageiro↔parceiro executado no emulador**; console de operação pendente. Fase 0 aprovada; PRM provisórios confirmados por default (no-show 5 min · pendência R$ 30 · noturno 20h-5h), configuráveis por cidade.

## 0. Contexto e premissas confirmadas

| Item | Definição |
|---|---|
| Praça piloto | Porto Velho/RO (~549 mil hab.), perímetro urbano inicial |
| Concorrentes locais | Uber, 99, inDrive, Urbano Norte (regional) |
| Regulação local | LC 856/2021 (SEMTRAN), LC 717/2018 (parcialmente inconstitucional), LC 977/2024, Lei 3493/2026 (mototaxi); **teor integral a verificar antes do KYC** |
| Federal | Lei 13.640/2018 (art. 11-A/11-B); STF Tema 967 (RE 1.054.110) e Tema 1.291 (RE 1.446.336, em julgamento) |
| Equipe | Dev solo, bootstrapping, 4–6 meses até MVP publicado |
| Stack | Flutter (mobile) + backend próprio leve (monólito modular) + Postgres |
| Serviços | (A) corridas de passageiros (carro/táxi) e (B) entregas (motoboy) — mesmo núcleo, tipos de serviço distintos |
| Monetização | Modelo duplo: **PASSE** R$ 10 / 12h relógio corrido (default, configurável) ou **COMISSÃO 12%** (configurável por cidade) — ver REQ-002 |
| Recorte | **MVP-A** (corridas ponta a ponta) → **MVP-B** (entregas, chat, cartão, alarme) |
| Navegação | Deep link (Google Maps/Waze) **e** navegação embutida — ambas, embarcadas em marcos diferentes |
| Cartão | Checkout hospedado do PSP (escopo PCI-SAQ-A) |
| Entregas | Piso de R$ 8,00 (configurável), tarifa parametrizável por faixa/km |

## 1. Fase 0 — resumo

- **NSM:** corridas concluídas com sucesso por parceiro ativo/semana.
- **Personas:** passageira "Ana" (preço, previsão, segurança), motorista "Seu Raimundo" (líquido visível, PIX rápido, bateria), operadora "Cris" (trilha de auditoria, KYC).
- **Diferenciais:** comissão baixa/zero com passe, negociação de preço, PIX nativo, segurança (facial, SOS, share, áudio), resiliência em rede ruim, leveza.
- **Métricas:** espera p95 < 8 min; aceitação > 70%; cancelamento < 8%; matching p95 < 10s; cold start < 3s; D7 > 25% (passageiro); receita por parceiro monitorada por modo.
- **Seed:** 40–60 parceiros fundadores, comissão 0% 30 dias, onboarding presencial.

## 2. Requisitos consolidados (R1–R10)

| Req | Conteúdo | Decisão principal |
|---|---|---|
| R1 | Abstração MapProvider (render, geocoding, autocomplete, routing/ETA, navegação) | Google default; deep link MVP-A; Navigation SDK embutido MVP-B; OSM = plano B |
| R2 | **Ver REQ-002** (passe) | Modelo duplo PASSE×COMISSÃO |
| R3 | **Ver REQ-003** (taxa simbólica) | Parametrizada por modo |
| R4 | Preço de entregas | Piso R$ 8,00 configurável + faixas |
| R5 | KYC minutos | ML Kit on-device + fila manual (SLA) + provedor especializado em V1 |
| R6 | Chat 24h | Bot determinístico 24h + humano 7h–23h; SOS independente |
| R7 | Fotos obrigatórias na entrega | 1–3 fotos (config.), compressão, upload resiliente, expiração LGPD |
| R8 | Alarme ETA ≤ 4 min | FCM alta prioridade, idempotente, ação "Já estou saindo", fallback SMS/WhatsApp plugável |
| R9 | Limite de cancelamentos | 5 faltas/7 dias (rolling), bloqueio 12h, contestação, no-show/falha/emergência não contam |
| R10 | Pagamentos | PIX + dinheiro + cartão hosted; ver ADR-003 para dinheiro em espécie |

### Custo de mapas (R1, verificado em fontes oficiais; **revisado pelo simulador de despacho 10/2026**)

| Cenário (1.000 corridas/dia) | Custo mensal |
|---|---|
| Google Routes **como SPECS** (~21 eventos/ride, sem alavanca) | US$ ~2.466 (Essentials) – ~4.982 (traffic-aware) |
| Google Routes **com alavancas L1+L2** (~5,6 eventos/ride — decisão do GATE 2) | US$ ~716 – ~1.482 |
| ~~modelo manual antigo (3,8 eventos/ride)~~ | ~~US$ ~567 / ~1.017~~ — subestimado, corrigido no gate |
| **Polling ComputeRoutes 15s (PROIBIDO pela arquitetura)** | **~US$ 15.000** |
| OSM auto-hospedado (VPS + preprocessing) | US$ 10–30 + operação |

Números derivados de `scripts/dispatch_sim.py` (SPECS §1/§4, 50k corridas, seed 42) + tiers oficiais Google — detalhe em `docs/fase2/CUSTO-CAPACIDADE.md` §1.1.

Regras Google verificadas (10/2026): **só valores de lat/long são cacheáveis por 30 dias — conteúdo completo de rota não é cacheável** (Routes API policies), sem combinar conteúdo Google com mapa não-Google, atribuição obrigatória, sem modo offline real; deep links Waze/Google permitidos e gratuitos. Mapbox: exigência de licença comercial p/ uso em veículos (confirmar por escrito). HERE: preços não verificáveis (cotação). OSM: ODbL (atribuição + share-alike se base derivada); servidor público OSM proibido em produção.

## 3. REQ-002 — Modelo duplo PASSE × COMISSÃO (regra inegociável)

### 3.1 Regra

- PASSE: paga `passe.preco` (default R$ 10,00) e roda `passe.duracao` (default 12h). Com passe ativo: **comissão = 0%, 100% do bruto é do parceiro**.
- Sem passe: modo COMISSÃO — plataforma retém `comissao.percentual`% por corrida/entrega (**default 12%, aprovado; configurável por cidade**).
- **Nunca bloquear por falta de passe.** Vencimento muda o modo automaticamente.

### 3.2 ADR-002 — Definições e justificativas

| # | Questão | Decisão | Alternativas descartadas | Motivo / custo-risco |
|---|---|---|---|---|
| A1 | Contagem | **(a) Relógio corrido da ativação (padrão)**, estratégia (b) horas online implementada como opcional por cidade | (b) como padrão; só (a) sem suporte a (b) | Simplicidade e previsibilidade; sem disputa "o que conta como online". Risco: parceiro de pouco uso se sente lesado → mitigado com relógio visível ao vivo e opção (b) |
| A2 | Ativação | **Agendada: inicia na 1ª transição para ONLINE** (opção "ativar agora" disponível) | Imediata no pagamento; totalmente manual | Com relógio corrido, ativação imediata faria passes vencerem dormindo. Agendada = justo e sem fricção |
| A3 | Compra com passe ativo | **Fila FIFO**: novo passe inicia automaticamente ao vencer o atual (validade da fila configurável, ex.: 30 dias) | Estender imediatamente; proibir compra | Estender com relógio corrido perde dias em silêncio; proibir perde receita. Fila é determinística e transparente |
| A4 | Modo por corrida | **`pricing_mode_snapshot` imutável capturado na ACEITAÇÃO** + `pass_id` de referência | Recalcular no fim; modo do pagamento da corrida | Elimina controvérsia e corridas de race condition; vencimento no meio da corrida não altera o preço |
| A5 | Avisos | Push em 60 min, 15 min e vencimento; renovação em 1 toque; **nunca interromper corrida em andamento** | Só aviso no vencimento | Prevenção > cobrança; reduz tickets |
| A6 | Pagamento/reembolso/idempotência | Ativação só com pagamento **confirmado** (webhook PSP); `idempotency_key` por compra; 1 compra em andamento por parceiro; **reembolso total se nunca ativado e compra < 24h**; demais casos: crédito manual do suporte com auditoria | Reembolso proporcional automático; ativação otimista | Proporcional automático é complexo e contencioso; crédito manual cobre os casos raros sem código extra |
| A7 | Antifraude | Passe é da **conta** (não do veículo/aparelho); 1 sessão de parceiro ativa por conta (heartbeat server-side); **relógio = tempo de parede do servidor**; score de suspeita (GPS fixo, velocidade impossível, desvio sistemático) → revisão, nunca despacho penalizado | Confiar no aparelho; punição via score de matching | Fonte de verdade no servidor mata relógio manipulado e 2 aparelhos; neutralidade do despacho (§6.2) impede punição oculta |

### 3.3 Estados do parceiro (§5.3 — ajustado)

Status operacional: `OFFLINE | ONLINE | EM_CORRIDA | PAUSADO`.
Atributo **ortogonal**: `modo_monetizacao ∈ {PASSE_ATIVO, COMISSAO}` — **nunca bloqueia ofertas**. REMOVIDO: `BLOQUEADO_passe` (inexistente neste modelo).

### 3.4 Despacho (§6.2 — ajustado)

Score de despacho **neutro** ao modo: PASSE/COMISSÃO não entra no score, nem como bônus, nem como penalidade. Auditoria automatizada: simulação com parceiros idênticos em modos distintos deve produzir distribuição estatisticamente igual (teste de regressão). Incentivo ao passe é permitido apenas em UI/CRM, nunca no algoritmo.

## 4. REQ-003 — Taxa simbólica por viagem (revisado)

- Componentes independentes por modo: `TAXA_FIXA`, `COMISSAO_PERCENTUAL`, `PASSE`.
- `taxa_viagem.passe` (default **R$ 0,00**) e `taxa_viagem.comissao` (**pendência de calibragem**: candidatos R$ 0,00 (diferencial de transparência) ou R$ 0,30–0,50 (piso de receita); decidir com dados da praça).
- Não cobra: corrida cancelada, falha do sistema, viagem de teste.
- Transparência obrigatória: recibo e extrato do parceiro itemizam cada componente.

## 5. ADR-003 — Comissão em corridas pagas em DINHEIRO (modo COMISSÃO)

**Opção escolhida: Retenção na origem + carteira líquida (híbrida)**
- PIX/cartão: a plataforma recebe o bruto e **retém a comissão no split** (repasse ao parceiro já líquido).
- Dinheiro em espécie: o parceiro recebe o bruto em mãos; a comissão vira **débito imediato da carteira** do parceiro.
- Saldo insuficiente: dívida acumula e é quitada automaticamente pelas próximas corridas PIX/cartão (débito em cascata).
- **Bloqueio progressivo**: quando `dívida > limite_configuravel`, bloqueia **apenas novas corridas pagas em dinheiro** (nunca todas).
- Saldo residual: cobrança via link PIX dinâmico no app do parceiro.

Alternativas descartadas: (a) pré-pago obrigatório para aceitar dinheiro (trava adoção do parceiro novo); (b) fatura semanal com crédito (exige análise de crédito e módulo de cobrança — V2); (c) débito só no fechamento do dia (expõe mais).

Riscos: parceiro sumir antes do limite (mitigação: limite baixo no MVP, ex.: R$ 30–50; antifraude), disputa de valor declarado (missão: conferência amostral + ticket).

## 6. Ledger (partida dobrada)

Tabelas: `partner_passes` (partner_id, inicio, fim, preco_pago, status, origem_pagamento, pass_id) e `ledger_entries` (append-only).

| Evento | Lançamentos |
|---|---|
| Compra do passe | D caixa/PSP `preco` / C receita de passes `preco` |
| Corrida PASSE (bruto X, passageiro pagou) | D carteira do passageiro (ou PSP) X / C parceiro X — **sem perna de comissão** |
| Corrida COMISSÃO PIX/cartão (X, c = X×p%) | D PSP X / C parceiro (X−c) / C receita comissão c |
| Corrida COMISSÃO dinheiro (X) | C receita comissão c / D carteira do parceiro c (débito) |
| Taxa fixa (se > 0) | D carteira do parceiro t / C receita de taxas t |
| Reembolso de passe (política A6) | D receita de passes / C PSP — com motivo e auditoria |

Invariantes (property tests obrigatórios):
1. Σ lançamentos de qualquer período/partição = 0.
2. Nenhuma corrida com `pricing_mode_snapshot = PASSE` gera lançamento de comissão.
3. `pricing_mode_snapshot` é imutável após a aceitação (estado final não altera lançamentos).
4. Corrida aceita antes e finalizada após o vencimento mantém PASSE.
5. Arredondamento monetário determinístico (centavo, comercial 0.005→cima); comissão nunca negativa.
6. Todo lançamento referencia `ride_id` idempotente (reentrega de webhook não duplica).

Casos de teste obrigatórios (REQ): (i) aceita com passe, finaliza após vencimento → comissão 0%; (ii) aceita 1 min após vencimento → comissão p%; (iii) renovação com passe ativo (fila FIFO); (iv) pagamento pendente/falho → segue COMISSAO, sem fila presa; (v) fuso/horário de verão → tudo em **UTC/epoch**, Brasil sem HV desde 2019 (teste de robustez para outras praças); (vi) queda de conexão no vencimento → vencimento é evento de servidor; corrida em andamento não é afetada.

## 7. Unit economics do modelo (Fase 0 — REQ-002)

**Ponto de migração do parceiro** (quando o passe compensa):

`corridas_por_dia × ticket_medio × comissao_percentual > preco_do_passe`

Exemplo paramétrico (comissão 12%, passe R$ 10): breakeven = bruto de **~R$ 83/dia** (ex.: 7 corridas de R$ 12). Acima disso, o parceiro migra para PASSE — **desejável** (incentiva rodar mais e dá previsibilidade), mas reduz receita média por corrida.

**Custo variável por corrida (ordem de grandeza — validar com dados reais):**

| Item | Estimativa | Observação |
|---|---|---|
| Mapas (R1) | ~R$ 0,10–0,15 | US$ 0,023/corrida (câmbio a data) |
| OTP/SMS | a verificar no provedor | Orçar na contratação |
| Taxa PSP | % ou fixo por transação | Negociar; PIX vs cartão diferem |
| Suporte (R6) | Horas/mês ÷ corridas | Meta: < R$ 0,50 |
| **Total grosseiro** | **~R$ 0,40–1,20** | **Hipótese a medir** |

Se um passe de R$ 10/12h gerar ~15 corridas, custo variável (~R$ 7,50) consome quase todo o passe. **Alavancas:** preço do passe (calibrar por praça), `taxa_viagem.passe` (default 0, pode virar R$ 0,30–0,50 se os dados pedirem), duração.

**Limite de uso justo:** não limitar corridas por passe no MVP (risco de UX e de arms race). **Gatilho de revisão:** se custo variável × corridas PASSE/mês > 80% da receita de passes por 2 semanas consecutivas → revisar preço/duração ou introduzir taxa fixa em PASSE.

## 8. Ajustes aplicados ao documento (changelog REQ-002/003)

- §2.4 D1: "Parceiro escolhe: passe barato (100% do ganho dele) ou comissão sem custo fixo."
- §5.3: removido `BLOQUEADO_passe`; adicionado `modo_monetizacao` ortogonal ao status.
- §6.2: neutralidade de score por modo + auditoria automatizada.
- REQ-010: dinheiro em espécie especificado por modo (ADR-003).
- Fase 0 — perguntas: (4) substituída por "passe conta em relógio corrido ou horas online?" (padrão: relógio corrido); adicionada "qual o percentual de comissão no modo sem passe?".
- Navegação (D6): deep link (MVP-A) **e** navegação embutida (MVP-B) — resposta "os dois".
- Cartão: checkout hospedado do PSP (D10 confirmada).
- Entregas: piso R$ 8,00 (R4 confirmada).
- MVP: 2 marcos (MVP-A corridas → MVP-B entregas/chat/cartão/alarme).

## 8b. Fase 0 v2 (Doc de Orquestração) — ADRs e riscos novos

### ADR-004 — Stack móvel (T4, matriz ponderada)

| Critério (peso) | Flutter | React Native | PWA/Capacitor |
|---|---|---|---|
| BG location confiável (20) | 3 | 3 | 1 |
| Bateria (12) | 4 | 3 | 4 |
| Push alta prioridade (10) | 4 | 4 | 3 |
| Mapa em Android de entrada (15) | 3 | 3 | 4 |
| Tamanho APK (10) | 3 | 3 | 5 |
| Produtividade — dev solo já publicou Flutter (20) | 5 | 2 | 5 |
| Manutenção (13) | 4 | 3 | 4 |
| **Ponderado** | **3,85** | **2,85** | **3,35** |

**Decisão: Flutter** (produtividade real do dev decide; BG via foreground service + pacote 3º [VERIFICAR licença/flutter_background_geolocation]). **Plano B: React Native** (custo de troca ~30–50% do código mobile [ESTIMATIVA]; mitigação: domínio puro em camada testável, UI fina). PWA descartada: BG location inviável em Android.

### ADR-005 — PSP (pesquisa oficial 10/2026)

| PSP | Split múltiplos | PIX split | Conta p/ parceiro | Taxa pública PIX | Observação |
|---|---|---|---|---|---|
| Mercado Pago | 1:1 sim; 1:N só carteira assessorada | Não confirmado | Conta própria do vendedor (KYC N6) | Não publicada p/ API | OAuth por parceiro |
| Asaas | Sim (walletId) | Sim (fluxo de cobrança) | Subcontas + BaaS | **R$ 1,99/cobrança** (promo R$ 0,99) | Taxa PIX alta p/ corrida de R$12 — negociar |
| Pagar.me | Sim (recipients) | **Sim, documentado** | Recebedor CPF/CNPJ | 0,99% (página de ofertas [condições]) | Melhor aderência técnica |
| PagBank | Sim (via VTEX) | Sim (VTEX) | Conta vendedor | Não publicada | API própria não comprovada |

**Decisão provisória: Pagar.me como alvo primário** (split multi + PIX com split documentado, 0,99% ~R$ 0,12/corrida de R$12); **Asaas plano B** (doc forte; R$ 1,99/cobrança inviável para ticket baixo sem negociação); MP só se 1:1 for suficiente. [VERIFICAR: propostas comerciais formais antes de PAGAMENTOS no MVP-A].

### Premissas F2 — status final

| Premissa | Status |
|---|---|
| Passe R$ 10/12h | **Aprovado** |
| Relógio corrido | **Aprovado** (HORAS_ONLINE como opção por cidade) |
| Taxa em PASSE = R$ 0 | **Aprovado** |
| Comissão | **Aprovado: 12%** |
| REQ-004 | **Aprovado: piso R$ 8,00** (faixa diferenciada implementada como estratégia) |
| Metas 90 dias | **Aprovado:** seed 40–60 parceiros, 300–500 corridas/dia no mês 3 |

### RSK (registro consolidado)

| ID | Risco | Sev | Mitigação |
|---|---|---|---|
| RSK-001 | Marca "10 é +" genérica / INPI | Média | Busca registral antes de investir; depósito de marca cedo; slug `dezemais` |
| RSK-002 | LC 856/2021 (alvará/cadastro motorista) | Alta | Ler norma antes do KYC; cadastro "pendente de alvará" |
| RSK-003 | STF Tema 1.291 (contrato do passe) | Média-Alta | Advogado; contrato transparente; neutralidade auditada |
| RSK-004 | Prazo × dev solo | Alta | Fases/gates; MVP-A/B; sem escopo novo sem ADR |
| RSK-005 | Liquidez de duas pontas | Alta | Seed fundadores; garantia de renda 30d; geofence |
| RSK-006 | Taxa PIX do PSP × ticket baixo | Média-Alta | Pagar.me 0,99%; negociar tarifa; kill switch por método |
| RSK-007 | Throughput Realtime Supabase (posições) | Média | Gate: p95 evento > 2s → serviço dedicado (fronteira pré-projetada) |
| RSK-008 | BG location em fabricantes agressivos (Xiaomi etc.) | Média | Teste em aparelhos reais; guia de permissões; fallback polling |
| RSK-009 | Entregas: regime jurídico próprio (Lei 13.640 não cobre) | Média | Análise separada no MVP-B |
| RSK-010 | Fraude de passe/colusão | Média | Servidor-centrista (ADR-002 A7); score → revisão |
| RSK-011 | Custo de suporte humano 24h | Média | Bot 24h + humano 7h–23h; SLA declarado |
| RSK-012 | Rejeição Google Play por BG location | Média | [VERIFICAR: política vigente] divulgação proeminente; teste beta fechado |

## 8c. Fase 2 — entrega (arquitetura, 5/5)

| Artefato | Conteúdo |
|---|---|
| `docs/fase2/0001_schema.sql` | DDL completo (30 tabelas, partições diária/mensal com retenção, índices GiST/BRIN, `city_configs` versionadas, saldos derivados) — validado em execução (PG16+PostGIS) |
| `docs/fase2/0002_rls_states_events.sql` | RLS deny-by-default em 31 tabelas, 11+ funções de domínio (única via de transição), catálogo `ride.event.v1`, hardening T-21 |
| `docs/fase2/0003_smoke_e2e.sql` | E2E dos 2 modos (COMISSAO/PASSE), ledger Σ=0, replay idempotente |
| `docs/fase2/0004_gap_fixes.sql` | Achados da revisão adversarial: idempotência genérica, saques, links de compartilhamento, imutabilidade de papel |
| `docs/fase2/0005_adversarial_tests.sql` | Suíte de abuso executável (CI): 18 verificações |
| `docs/fase2/openapi.yaml` | Contrato das Edge Functions (39 paths / 43 ops após a Fase 3, JWT, `Idempotency-Key`, problem+json; validado por `openapi-spec-validator` e contra respostas da demo) |
| `docs/fase2/SPECS.md` | Despacho (leva de 3, R(t)), motor de preço, negociação anti-colusão, ETA sem polling |
| `docs/fase2/THREAT-MODEL.md` | STRIDE (T-01..T-24) com ações A1..A16 e rastreio LGPD |
| `docs/fase2/SLOS.md` | SLOs → SLIs servidor-centristas, error budget, alertas, runbooks |
| `docs/fase2/CUSTO-CAPACIDADE.md` | 1k/10k/100k corridas/dia com preços oficiais 10/2026; gates de decisão |
| `docs/fase2/PLANO-TESTES.md` | Pirâmide L0–L7, propriedades, carga, gates de qualidade |
| `docs/fase2/REVISAO-ADVERSARIAL.md` | Fechamento: AV-1 (EoP crítico) corrigido e provado; limite honesto |

**GATE 2 APROVADO** — orçamento fechado após revisão com o simulador de despacho da SPECS (ver CUSTO-CAPACIDADE.md §1.1) e cadeia `0001→0005` em script único de CI (`scripts/ci_db_suite.sh` + workflow `.github/workflows/db-suite.yml`).

**Fase 3 (em andamento):** telas do app passageiro em Flutter sobre o contrato `openapi.yaml` + app parceiro + **console da operação** (fila do KYC, SLA e decisão) + **câmera do parceiro** (F9); bloqueios externos do §9 permanecem.

### 8d. Fase 3 — entrega parcial: app passageiro (MVP-A)

| Artefato | Conteúdo |
|---|---|
| `app/passageiro/` | Flutter app: 11 telas C1–C11 da Fase 1 sobre o contrato; `dart analyze` 0 issues, **24/24 testes**, `flutter build web` e APK debug verdes |
| `lib/src/api/client.dart` | Client tipado do `openapi.yaml`: Idempotency-Key em toda mutação, problem+json → `ApiProblem(code)` (UI decide por code, nunca por mensagem) |
| `lib/src/state/ride_controller.dart` | Estado único da corrida; Realtime primário + poll fallback c/ backoff (nunca polling de ETA) |
| `test/api_client_test.dart` | Contrato client↔OpenAPI: corpo, headers, enums do 0001, 409/422 codes |
| `test/flow_test.dart` | Fluxos C1→C2→fila, 409 sem navegar, histórico vazio |
| `openapi.yaml` (+2 ops) | `GET /rides` (histórico/ativa) e `POST /rides/{id}/rating` — exigidos por C9/C8 e ausentes no contrato da Fase 2; então 23 paths / 26 ops, schema `Ride` documentado |
| `scripts/dispatch_sim.py` | Simulador de despacho (SPECS §1/§4) que revisou o orçamento — §1.1 do CUSTO-CAPACIDADE |
| `scripts/ci_db_suite.sh` + `.github/workflows/db-suite.yml` | Cadeia 0001→0005 em container único (18/18 asserts, ledger Σ=0) a cada push; workflow roda também analyze/test do app |

Bugs reais pegados pela verificação durante a Fase 3: `AppScope` lido em `initState` (ilegal → `didChangeDependencies`), timer de poll órfão no teste, imports de tela errados, `widget_test.dart` de scaffold do `flutter create`. Corrigidos; nenhum teste suprimido.

### 8e. Fase 3 — entrega parcial: app parceiro (MVP-A, P1–P7)

| Artefato | Conteúdo |
|---|---|
| `app/parceiro/` | Flutter app: telas P1–P7 da Fase 1 (P8 tickets fica para o MVP-B) sobre o mesmo contrato; `dart analyze` 0 issues, **18/18 testes**, `flutter build web` verde |
| `lib/src/state/partner_controller.dart` | Máquina OFFLINE → ONLINE → EM_CORRIDA (SPECS §5.3); poll de ofertas com backoff (fallback Realtime); `monetization_mode` ortogonal — nunca bloqueia oferta (§3.3) |
| `lib/src/screens/painel_screen.dart` | P2 tela única (ADX-UX-2): chip modo + PassCard + carteira + CTA grande; gate KYC (F9: em análise ≠ online) decide por code `kyc_not_approved` |
| `lib/src/screens/oferta_screen.dart` | P3 OfferCard com hierarquia obrigatória (bruto 31 dp > coleta > total > destino ≈ R$/h > cronômetro 15 s); timeout é do servidor — o app só conta |
| `lib/src/screens/em_corrida_screen.dart` | P4 3 fases + deep link (MVP-A; ponto de troca do MapProvider isolado); P5 confirmação de dinheiro (ADR-003) como sheet que só coleta — a transição é da tela (evita corrida com o pop) |
| `openapi.yaml` (+3 schemas) | `Offer`, `PartnerWallet` (extrato itemizado D/C), `PartnerPassState` (fila FIFO A3) + `Me.partner.kyc_status` — exigidos pelas telas P3/P6/P7/P1 e antes só descritos em prosa; então 23 paths / 26 ops com respostas tipadas (hoje 39/43 após o alinhamento da Fase 3) |
| `test/api_client_test.dart` (13) | Contrato: Idempotency-Key em online/accept/transitions/passes/withdraw/kyc, enums do 0001, `fare_total` só em FINALIZADA, 409 codes (offer_unavailable/illegal_transition/debt), parse de Offer/Wallet/Pass/KYC |
| `test/flow_test.dart` (5) | Fluxos: P2→P3→aceitar (POST accept c/ Idempotency-Key → EM_CORRIDA), P4 transições + P5 dinheiro (`cash_declared` + `fare_total`), F9 gate KYC → onboarding, P7 carteira por direção D/C |

Bugs reais pegados pela verificação no app parceiro (corrigidos na causa, nenhum teste suprimido): mocks de teste codificavam latin1 e quebravam o `utf8.decode` do client (o servidor real manda UTF-8 — RFC 8259; helper `resp()` com charset), `Spacer` dentro de `ListView` (ParentData), `loadMe()` notificando síncronamente durante build (`markNeedsBuild` ilegal → agendado pós-frame), sheet P5 disparando `transition` após o pop (corrida de estado → spinner eterno; agora devolve resultado e a tela transiciona), painel re-empilhando telas a cada rebuild (falta de guarda `isCurrent`).

### 8f. Revisão da Fase 3 e execução E2E (22/10/2026)

Revisão completa dos dois apps, da demo e do contrato, com relatório em
`docs/REVISAO-FASE3.md`. Principais correções: telas de convite e layout do
Perfil quebrados (build), `AppScope` em `initState` (convite/raspadinha),
poll do passageiro que morria na primeira falha de rede e não retomava no
foreground, backoff do poll do parceiro que fazia perder ofertas de 15 s,
C7 pedindo pagamento quando o dinheiro já estava confirmado, e resposta do
PSP ignorada na tela de PIX. Também: novos endpoints de demo (convites,
perfil, pausa, radar) e smoke E2E reutilizável (`scripts/smoke_demo_api.py`).

**Teste automatizado:** o roteiro acima virou `python
scripts/e2e_emulator.py` (exit 0 = PASS): ele sobe AVD e API isolados,
compila/instala os dois APKs, conduz as duas UIs por adb/uiautomator e
confere o estado final no servidor. Roda em CI pelo workflow
`e2e-emulator` (`workflow_dispatch`). Detalhes e política de retentativa em
`docs/REVISAO-FASE3.md` §3.5–3.6.

**Execução real no emulador:** pedido (cotação do momento + rota OSRM —
R$ 12,08 às 9h50 e R$ 10,16 às 10h de 23/10, tarifa dinâmica) →
parceiro ONLINE recebe oferta (reoferta a cada 15 s) → aceite →
A CAMINHO → CHEGUEI → EM VIAGEM → FINALIZADA (dinheiro declarado) →
passageiro vê “Pagamento confirmado” → avalia → home. Evidências em
`.preview/e2e_hoje/20261023-094557-a1` e
`.preview/e2e_final_hoje/20261023-095842-a1` (`result.json` com
`status: pass`). A revisão de 23/10
(cotação dinâmica × valor fixo nos docs, rota OSRM, o que ficou pendente)
está em [`docs/REVISAO-FABLE.md`](REVISAO-FABLE.md). O `openapi.yaml` foi
alinhado aos endpoints da Fase 3 (perfil, convites, raspadinha, pausa e
radar), passou no validador OpenAPI 3.0 e teve 14 respostas reais da demo
validadas contra os schemas.

### 8g. Bloco 1 do KYC: console da operação + câmera (F9) (11–12/11/2026)

O KYC do parceiro deixou de ser "o parceiro preenche e alguém vê": o
cadastro virou uma **fila com SLA e decisão**, e existem duas superfícies
novas — o **console da operação** (onde a fila é lida e a decisão é tomada)
e a **câmera do parceiro** (onde o documento é fotografado e enviado de
verdade).

| Artefato | Conteúdo |
|---|---|
| `app/console/` | **Console da operação** (Flutter mobile, Android/iOS): login por código de uso único (sem auto-cadastro e sem mexer no papel), conferência de papel (`GET /kyc/me`), fila (posição, SLA, documentos, **nome e telefone do parceiro**, atualização automática), detalhe do caso (**identidade do parceiro + o DOCUMENTO visto**, miniatura e tela cheia com zoom, marca de **ARQUIVO PENDENTE**) e decisão (aprovar/recusar/pedir reenvio com folha de motivo padronizado). `dart analyze` limpo, **33/33 testes** |
| `packages/ten_auth/` | **Fonte única do login** dos três apps (passageiro, parceiro, console): `AuthService` extraído das duas cópias, `sendCode(createUser:, withRole:)`, `accountId()`. **18/18 testes**; passageiro **90/90**, parceiro **139/139** |
| `supabase/migrations/20261110000600_kyc_storage.sql` | Bucket **privado** `kyc-docs` + 4 políticas de RLS (dono = 2ª pasta do path) + `api_kyc_case_document` conferindo dono e existência do objeto (422 `storage_path_not_owned` / `document_not_found`, 503 `storage_unavailable`) |
| `supabase/migrations/20261110000700_kyc_console.sql` | `api_kyc_me()` — o papel da conta vem do `users.role` (que só o trigger escreve) |
| `supabase/migrations/20261110000800_kyc_console_docs.sql` | A operação **vê** o documento e **identifica** o parceiro: a política de SELECT do bucket libera o papel AGENT/ADMIN (`OR app_is_agent()` — e só ele), e `api_kyc_case_get`/`api_kyc_queue` devolvem `partner_name`, `partner_phone`, `storage_path` e `has_file` |
| `app/parceiro/lib/src/media/` | **Câmera nativa** (plugin `camera`, com stub honesto onde não há câmera) + **captura guiada** com medição de borrão/reflexo em Dart puro; upload **real** do arquivo no bucket privado antes do registro do documento |
| `scripts/contract.py` + `scripts/test_contract.py` | Contrato como fonte única: bucket, prefixo do path, motivos de recusa e limiares de qualidade. **29/29 testes** |
| `scripts/kyc_smoke.py` | Smoke do KYC no Postgres **com upload real** no bucket + 2 casos negativos (path alheio, objeto inexistente) + a conferência de papel (`/me`) + o passo "a operação vê o documento" (a operação baixa o objeto com o próprio token; um parceiro alheio é recusado) |
| `scripts/kyc_console_seed.py` | Deixa um caso **real** na fila (com documento no bucket) para a prova visual do console — o smoke apaga o caso dele, o seed prepara a mesa |

Verificação desta rodada: `ci_migrations.sh` aplica **24 migrations do zero**
e fecha com "TODOS OS ASSERTS OK"; `kyc_smoke.py` PASS (re-executável);
`GET /kyc/me` provado no stack local (AGENT → `is_agent: true`, PARTNER →
`false`); upload no bucket privado provado com POST **e** PUT usando só o
JWT do parceiro; **os dois APKs debug buildam** — parceiro em 282,5 s (com
`android.permission.CAMERA` no manifesto) e console em 83,4 s
(`app.dezemais.console_operacao`, rótulo "10 é + Console").

### 8h. Rodada "o console usável" (12/11/2026)

O console existia, mas **não dava para trabalhar**: a operação não via o
documento (aprovava uma CNH que nunca tinha visto), não sabia de quem era o
cadastro ("Parceiro 77777777"), e o APK de **release** saía **sem rede** (a
permissão `INTERNET` só estava no manifest de debug). A auditoria de design
acusou mais 12 defeitos de layout/feedback (overflow de 262 px em 360×800 com
fonte 2.0, spinner teal sobre teal = 1:1 de contraste, inset de gesto não
reservado, erro pintado de teal, folha de decisão sem superfície…).

| Artefato | Conteúdo |
|---|---|
| `app/console/lib/src/api/console_api.dart` | `partnerName`/`partnerPhone`/`storagePath`/`hasFile`, base do Storage (`STORAGE_BASE`, derivada do host da função quando não vem) e `documentBytes()` — o download do bucket privado **com o próprio token** (sem service role, sem URL assinada) |
| `app/console/lib/src/widgets/document_preview.dart` | O documento VISTO: miniatura, tela cheia com zoom, e os estados honestos (carregando / pronto / falha — um conteúdo que não é imagem aparece como falha, nunca como moldura vazia) |
| `app/console/lib/src/screens/` | Fila com nome e telefone + polling de 30 s + erro de atualização visível; detalhe com a identidade do parceiro, o documento e as decisões; login com erro no campo/banner e spinner com contraste; folha de decisão com superfície, raio, sombra, rolagem e `SafeArea` |
| `app/console/android/app/src/main/AndroidManifest.xml` | **`android.permission.INTERNET` no manifest `main`** — sem ela, o APK de release não tinha rede (o build de debug mascarava) |
| `packages/ten_design/` | Mudanças **aditivas**: `EmptyState` ganhou `tone` (erro em `danger`, nunca em teal), `AppCard` ganhou `borderRadius` (a onda do toque respeita a borda) e `StatusChip` encolhe com reticências em vez de estourar |

Verificação desta rodada: `dart analyze` limpo no console e no `ten_design`;
**33/33 testes do console** (33 = 22 anteriores + identidade, documento,
360×800 com fonte 2.0 e o download do bucket); passageiro **90/90** e parceiro
**139/139** (o `ten_design` foi mexido); `test_contract.py` **29/29**;
`ci_migrations.sh` aplica **24 migrations do zero** → "TODOS OS ASSERTS OK";
`kyc_smoke.py` PASS com o passo novo (a operação baixa o documento do bucket
privado, um parceiro alheio é recusado com 400); **APKs debug e release
buildam** e o **release foi inspecionado**: `uses-permission:
name='android.permission.INTERNET'` (o bloqueador de release, fechado);
**prova no emulador** (AVD API 37): login por OTP → fila com **"Parceiro KYC
dev / +5596990000004"** → detalhe com o **documento na tela** → tela cheia
com zoom → folha de decisão → aprovação (o caso saiu da fila e o
`partners.kyc_status` foi para `APPROVED` no banco).

### 8i. Rodada "os defeitos que o juiz achou" (12/11/2026)

A verificação adversarial (`fable-judge` + `engineering-code-reviewer`) do
commit `530736c` deu **VERIFIED WITH CAVEATS** e achou **dois defeitos
reais** no que eu tinha affirmationado. Corrigidos aqui.

| Defeito | O que era | O que é agora |
|---|---|---|
| **`has_file` MENTIA** (F2-a) | A 00800 calculava "o objeto existe" como *"o caminho não é o marcador `PENDENTE/`"*. Um `storage_path` que não aponta para objeto nenhum vinha como **ARQUIVO OK** (verde) e o preview falhava logo abaixo — duas afirmações contrárias na mesma tela | A 00900 cria `fn_kyc_storage_object_present` e o `has_file` pergunta **ao bucket**. Provado dos dois lados: objeto real → `true`; path sem objeto → `false` (a tela mostra **SEM ARQUIVO**) |
| **A FILA PODIA OMITIR o caso mais urgente** (pré-existente) | O `LIMIT` estava **sem `ORDER BY`**: o Postgres devolvia 50 linhas arbitrárias e só depois ordenava. Com mais de 50 casos, o caso que vence primeiro podia não estar na tela — esconder trabalho numa fila de atendimento | O `ORDER BY (sla_due_at, created_at, id)` vai **dentro** do subquery, **antes** do `LIMIT`, na mesma chave do ranking (`fn_kyc_queue_position`) |
| **`jsonb_strip_nulls` omitia nulos** (F2-b) | O `openapi.yaml` dizia `nullable: true`, o que faz o leitor esperar a chave presente com `null` — mas o servidor **omite** a chave | O `openapi.yaml` documenta: *"a response é montada com `jsonb_strip_nulls`: um campo NULO é OMITIDO"*; o console trata "ausente" e "nulo" igual |
| **Preview sem `didUpdateWidget`** | Trocar de documento mantinha os bytes antigos: a tela podia mostrar a **CNH com o rótulo da CRLV** | `didUpdateWidget` recarrega quando o caminho muda, e a resposta antiga (de outro path) é descartada |
| **Corrida no controller** | Polling (30 s) + "puxar para baixo" + decisão podiam cruzar: a resposta **mais antiga** chegava depois e sobrescrevia a fila com um retrato velho | Cada leitura recebe um número; **só a última escreve o estado** |
| **Ícone perdido no CTA** | O botão "APROVAR CADASTRO" ficou só com texto (a troca de `FilledButton` por `GradientButton` perdeu o ícone) | O ícone `check_circle_outline` voltou (o CTA primário diz, no olhar, o que faz) |
| **Preview estourava em 360×800 com fonte 2.0** | A caixa de altura fixa (200 px) não cabia o aviso de falha com a fonte grande — overflow de 90 px | A caixa tem **altura mínima** (não fixa) e o aviso de falha cabe; o `errorBuilder` da imagem tem um aviso compacto próprio |

| Artefato | Conteúdo |
|---|---|
| `supabase/migrations/20261110000900_kyc_console_docs_fix.sql` | `fn_kyc_storage_object_present` (pergunta ao bucket, degrada para `false` sem o schema `storage`), `api_kyc_case_get` com o `has_file` honesto e `api_kyc_queue` com o `ORDER BY` antes do `LIMIT` |
| `app/console/lib/src/state/console_controller.dart` | Guarda de concorrência: a leitura mais antiga é descartada |
| `app/console/lib/src/widgets/document_preview.dart` | `didUpdateWidget`, altura variável e aviso compacto de decodificação |
| `app/console/lib/src/screens/case_screen.dart` | Ícone do CTA de aprovação |
| `app/console/test/` | **45/45** (33 + controller (4) + preview (6) + "SEM ARQUIVO" + ícone do CTA) |
| `scripts/ci_migrations.sh` | Assert do `has_file` **dos dois lados**: o path com objeto é "COM arquivo" e o path sem objeto é `false` (um assert só do lado feliz deixaria a mentira passar) |
| `scripts/kyc_smoke.py` | Prova o `has_file` honesto contra o stack real (documento com objeto → `true`; marcador `PENDENTE/` → `false`) |
| `scripts/test_contract.py` | **34/34** (29 + `has_file` pergunta ao bucket + `ORDER BY` antes do `LIMIT` + CI prova os dois lados + openapi diz que o nulo é omitido) |

Verificação desta rodada: `dart analyze` limpo (console + `ten_design`);
console **45/45**; passageiro **90/90**; parceiro **139/139**; `ten_auth`
**18/18**; `test_contract.py` **34/34**; `ci_migrations.sh` aplica **25
migrations do zero** → "TODOS OS ASSERTS OK"; `kyc_smoke.py` PASS com o
`has_file` honesto provado dos dois lados; **APKs debug e release buildam**
(release inspecionado: `uses-permission: name='android.permission.INTERNET'`);
**prova no emulador** (AVD API 37) refeita com o build novo: fila → detalhe
com **o documento na tela** → **"SEM ARQUIVO"** em vermelho no documento cujo
path não aponta para objeto nenhum (o `has_file` honesto, visto pela
operação) → folha de decisão → aprovação (a fila esvaziou e o
`partners.kyc_status` = `APPROVED` no banco).

### 8j. Rodada "os 8 defeitos da 2ª verificação" (12/11/2026)

A **segunda** verificação adversarial do commit `24a46aa` voltou a dar
**VERIFIED WITH CAVEATS** — e achou **8 defeitos** (F3-a…F3-h), não 6: dois
testes **inertes** (que passavam mesmo com o defeito presente), um
**desvio de segurança**, duas arestas de comportamento no controller e uma
**frase falsa no contrato** — exatamente a categoria que a rodada dizia
estar corrigindo. Todos corrigidos aqui.

| Defeito | O que era | O que é agora |
|---|---|---|
| **F3-a — teste inerte** (🟡) | O teste do `didUpdateWidget` servia o **mesmo PNG** nos dois caminhos e só afirmava que existia uma `Image`: com o bug presente, **passava**. Provado por mutação (removendo o `didUpdateWidget`, o teste continuava verde) | Bytes **distintos** por caminho (PNG vermelho e azul) e comparação dos **bytes renderizados** (`bytesNaTela`) + um teste da **resposta atrasada do caminho antigo** (a que chega depois da troca não pode tomar a tela) |
| **F3-b — o contrato afirmava mais do que provava** (🟡) | O `test_contract.py` exigia a **DEFINIÇÃO** de `fn_kyc_storage_object_present` — uma migration podia definí-la e nunca chamá-la (a própria mentira da F2-a) | O contrato exige o **USO** (`'has_file', fn_kyc_storage_object_present(` dentro do `api_kyc_case_get`) e **proíbe** a fórmula antiga (`NOT LIKE 'PENDENTE/%'`) |
| **F3-c — endpoint público** (🟡) | A função nova herdava o default do Postgres (`EXECUTE TO PUBLIC`): qualquer visitante podia perguntar "esse documento existe?" — um oráculo de existência de documento num bucket **privado** | A 00900 repete o padrão da 00600: `REVOKE … FROM PUBLIC, anon` + `GRANT … TO authenticated, service_role`. Provado no banco: `proacl = {postgres=X, authenticated=X, service_role=X}` (sem PUBLIC/anon) e o CI confere o `pg_proc.proacl` |
| **F3-d — a guarda descartava uma leitura boa** (🟡) | A comparação era com a última *tentativa*: se a leitura **nova** falhava e a **antiga** dava certo, o último retrato verdadeiro era jogado fora (tela vazia + erro) | Dois contadores: `_lastOkAttempt` (a fila só é reescrita por um sucesso **mais novo**) e `_lastErrAttempt` (o erro só é apagado por um sucesso **mais novo**). A leitura antiga que deu certo fica na tela **com o aviso** |
| **F3-e — o spinner podia ficar preso** (🟡) | Sem prazo no cliente HTTP, uma leitura pendurada deixava a tela em "carregando" para sempre | `ConsoleApi.requestTimeout` (padrão 20 s) → `TimeoutException` vira `ApiProblem('offline')`; o prazo cobre **os cabeçalhos e o corpo** (um `.timeout` só no corpo não protegia nada). O spinner pertence à leitura mais recente: só ela desliga (sem piscar) e ela sempre termina |
| **F3-f — frase falsa no openapi** (🟡) | "storage_path … OMITTED when the document has no object" — **falso**: o servidor devolve o marcador `PENDENTE/…` **literalmente** (a coluna é `NOT NULL`) | A descrição diz a verdade: o marcador legado volta **como está**, e o `has_file` dele é `false`. E no `KycCase` os campos nulos **não** são marcados `nullable` (eles são **omitidos** — o `nullable: true` fazia o leitor esperar uma chave com `null`) |
| **F3-g — usuário sem recuperação** (💭) | O `errorBuilder` da imagem substituía o conteúdo do preview: quem caísse em "é imagem mas não decodifica" ficava **sem botão nenhum** (e o comentário dizia o contrário) | O `_DecodeFailed` ganhou o botão **"Tentar de novo"** (`document-retry-decode`) e o comentário foi corrigido |
| **F3-h — duas afirmações imprecisas** (💭) | O `jsonb_agg` externo ordenava sem o desempate por `id` (empates saíam em ordem arbitrária na tela) e a frase do commit sobre o `build/` "sair do versionamento" era falsa (nunca foi versionado) | O `ORDER BY` externo usa a **mesma chave do ranking** (`sla_due_at, created_at, case_id`); a frase falsa não se repete |

**Extra (não estava na lista do juiz, mas foi fechado):** o claim "a fila
ordena antes do `LIMIT`" era provado **só por grep**. Agora o CI prova
**comportamentalmente**: cria 61 casos, insere o **mais urgente por último**
(a ordem do heap o deixaria fora do `LIMIT` de 50) e exige que ele esteja na
tela **e em primeiro lugar**.

| Artefato | Conteúdo |
|---|---|
| `supabase/migrations/20261110000900_kyc_console_docs_fix.sql` | `fn_kyc_storage_object_present` + o **revoke/grant** (convenção da 00600), `api_kyc_case_get` com o `has_file` honesto, `api_kyc_queue` com o `ORDER BY` antes do `LIMIT` e o desempate por `case_id` |
| `app/console/lib/src/state/console_controller.dart` | Guarda em dois contadores (`_lastOkAttempt`/`_lastErrAttempt`) e o spinner com dono (a leitura mais recente) |
| `app/console/lib/src/api/console_api.dart` | `requestTimeout` (padrão 20 s) cobrindo cabeçalhos **e** corpo |
| `app/console/lib/src/widgets/document_preview.dart` | Botão "Tentar de novo" no aviso de decodificação (com o comentário corrigido) |
| `app/console/test/` | **52/52** (45 + o teste do `didUpdateWidget` com bytes distintos + a resposta atrasada + a leitura boa preservada + o spinner preso + o spinner que não pisca + o botão de decodificação) |
| `scripts/ci_migrations.sh` | Assert do `pg_proc.proacl` (sem PUBLIC/anon) e assert **comportamental** da fila (>50 casos: o mais urgente tem que aparecer e em primeiro lugar) |
| `scripts/test_contract.py` | **37/37** (34 + o **uso** da função no `has_file` + o revoke + o assert comportamental da fila) |
| `docs/fase2/openapi.yaml` | O marcador `PENDENTE/…` devolvido **como está**; no `KycCase` os nulos são **omitidos** (sem `nullable: true`); `KycQueueItem.sla_due_at` é `nullable` (lá o nulo **vem** como `null`) |

Verificação desta rodada: `dart analyze` limpo (console + `ten_design`);
console **52/52**; passageiro **90/90**; parceiro **139/139**; `ten_auth`
**18/18**; `test_contract.py` **37/37**; `ci_migrations.sh` aplica **25
migrations do zero** → "TODOS OS ASSERTS OK"; a 00900 é **idempotente**
(3 aplicações seguidas no stack local, sem erro) e o `proacl` da função nova
foi conferido no banco (`anon: f`, `authenticated: t`); `kyc_smoke.py` PASS
com o `has_file` honesto provado dos dois lados; **APKs debug e release
buildam** (release inspecionado: `uses-permission:
name='android.permission.INTERNET'`); **prova no emulador** refeita com o
build novo (fila → documento na tela → "SEM ARQUIVO" → folha de decisão →
aprovação, com o banco em `APPROVED`).


Bloqueio de ambiente (não de produto): `flutter pub get` no app parceiro
falha neste host com "Building with plugins requires symlink support" — o
plugin `camera` é novo e o Flutter injeta plugins para **Windows**, que
exige symlink (admin/Developer Mode; não há admin nesta máquina). Não
afeta Android/iOS/web: o Gradle usa `.flutter-plugins-dependencies`, sem
symlink — e o APK do Android **compila** com a câmera dentro.

## 9. Pendências externas (bloqueios de lançamento)

1. **Advogado (trabalhista/regulatório):** contrato do passe × Tema 1.291; neutrality documentada; Lei 13.640 não cobre entregas.
2. **Contador:** ISS intermediação (LC 116, 10.02), NFS-e do passe/taxa, separação receita×repasse, tratamento fiscal das entregas.
3. **SEMTRAN Porto Velho:** teor da LC 856/2021 (exigências de cadastro/alvará).
4. **PSP:** taxas de PIX/cartão/split, devolução Pix, conta de pagamento para repasse.
5. **Provedores:** SMS/WhatsApp (custo por mensagem/conversa), KYC especializado (preço por verificação, V1).
