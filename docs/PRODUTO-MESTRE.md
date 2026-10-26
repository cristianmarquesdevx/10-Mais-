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

**Fase 3 (em andamento):** telas do app passageiro em Flutter sobre o contrato `openapi.yaml` + app parceiro + console operação; bloqueios externos do §9 permanecem.

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

## 9. Pendências externas (bloqueios de lançamento)

1. **Advogado (trabalhista/regulatório):** contrato do passe × Tema 1.291; neutrality documentada; Lei 13.640 não cobre entregas.
2. **Contador:** ISS intermediação (LC 116, 10.02), NFS-e do passe/taxa, separação receita×repasse, tratamento fiscal das entregas.
3. **SEMTRAN Porto Velho:** teor da LC 856/2021 (exigências de cadastro/alvará).
4. **PSP:** taxas de PIX/cartão/split, devolução Pix, conta de pagamento para repasse.
5. **Provedores:** SMS/WhatsApp (custo por mensagem/conversa), KYC especializado (preço por verificação, V1).
