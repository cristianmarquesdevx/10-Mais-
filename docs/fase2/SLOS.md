# SLOs e observabilidade — Fase 2 · dezemais

> IDs: D1/D5, RSK-007, métricas do Fase 0 §1. Princípio: **toda SLO tem SLI
> medível no servidor** (sem depender de telemetria do cliente). Janela de erro
> 30 d; burn rate documentada para alerta.

## 1. SLO do produto → SLI do servidor

| SLO (produto) | Meta | SLI (medida no servidor) | Fonte |
|---|---|---|---|
| Matching (aceite → `EM_VIAGEM` início da busca → `ACEITA`) | p95 < **10 s** | `ride_events`: Δ(ts `offer.accepted` − ts `ride.created`) | `ride_events` |
| Espera do passageiro (criação → `A_CAMINHO`) | p95 < **8 min** | Δ(ts `ride.a_caminho` − ts `ride.created`) | `ride_events` |
| Taxa de aceite de oferta | > **70%** | `offer.accepted` / `offer.sent` (janela 1 h, por cidade) | `offers` |
| Cancelamentos | < **8%** | `cancel_events` com `counts_as_fault` / corridas finalizadas (7 d rolling) | `cancel_events` |
| Alarme ETA ≤ 4 min (R8) | **100%** idempotente, ≤ 4 min após cruzar threshold | 1 `notification` de alarme por corrida (contagem ≤ 1) e atraso evento→push | `notifications` |
| Latência da API (pontos críticos) | p95 < **400 ms** Edge Function; p99 < 1,5 s | métrica Supabase/observabilidade | Edge runtime |
| Disponibilidade da API | **99,5%** mensal (MVP) | 1 − (5xx ÷ total) excluindo manutenção | gateway |
| Webhook PSP → estado pago | p95 < **60 s** | Δ(webhook recebido → `payments.status=CONFIRMED`) | `payments` |
| Pagamento/ativacao de passe | ativação **só** com confirmação (A6) | contagem de passos ACTIVE com evento de pagamento | `partner_passes` |
| Ledger consistente | **0** janelas com Σ ≠ 0 | job de reconciliação diário (A7) | `ledger_entries` |
| Integridade de domínio | **0** corridas sem snapshot pós-aceite | job: `aceita → FINALIZADA` sem snapshot = page | `rides` |
| Cold start do app | < 3 s | métrica cliente (crash/ANR + TTID); gate do squad | telemetry cliente |

Nota: espera/matching são SLOs de **mercado** (dependem de oferta), não só de
engenharia — por isso são acompanhadas por cidade; uma praça nova tem curva própria.

## 2. Error budget e alertas

| Alerta | Condição | Canal | Ação |
|---|---|---|---|
| P1 — dinheiro | job diário Σ ledger ≠ 0; ou duplicidade `payments` | page | **congelar saques** (kill switch ADR-006) + investigar |
| P1 — 5xx | erro 5xx > 1% por 10 min | page | rollback da Edge Function |
| P1 — webhook PSP | 0 webhooks em 15 min com corridas FINALIZADA pendentes | page | fila de reprocessamento (Fase 1 F4) |
| P2 — matching | p95 matching > 15 s por 1 h (praça) | ticket | revisar despacho/Raio; verificar liquidez (RSK-005) |
| P2 — Realtime | p95 entrega de evento > 2 s sustentado (gate RSK-007) | ticket | migrar posições para serviço dedicado (fronteira pré-projetada) |
| P2 — custo Google | consumo diário > 120% do previsto (T-18) | ticket | revisar tráfego/simulador; chegar quota |
| P2 — fraude | score de spoofing/T-03 > limiar; par com > 3 corridas em 24 h (anti-colusão SPECS) | ticket | revisão humana + bloqueio do par |
| P3 — KYC | fila > SLA (2 min EMERGENCY / demais declarados) | ticket | acionar operação |

Budget: 99,5% ⇒ **3 h 39 min** de indisponibilidade/mês; se o budget queimar
> 50% em 30 d, congela-se deploy de features e prioriza-se estabilidade.

## 3. Observabilidade — o que emitir

| Camada | Conteúdo | Regra |
|---|---|---|
| Logs estruturados (Edge) | `trace_id`, `uid` (sub), rota, duração, status, código de erro `problem+json` | **nunca** PII, PAN, token, coordenada de passageiro fora de corrida ativa (T-14) |
| Eventos de produto | `ride_events` (já imutável e append-only) | fonte única das SLOs de negócio — sem log paralelo |
| Auditoria | `audit_log` em toda mutação sensível (papel, preço, saque, KYC) | nunca editável |
| Banco | `pg_stat_statements` (top queries), índices particionados, tamanho/partições | retenção: posições 7 d e fotos 30 d **derrubam dados de verdade** |
| Métricas de negócio | corridas/dia por cidade e modo, receita por parceiro (T7), taxa de passe vs comissão | painel do console (Fase 3) |
| Client | crash/ANR, TTID (cold start), falhas de BG location por fabricante (RSK-008) | gating de release |

## 4. Runbooks mínimos (módulo 4)

1. **Ledger desbalanceado** → congelar saques → exportar `ledger_entries` do dia →
   reconciliar com `payments` → postar ajuste via `fn_ledger_post` (nunca UPDATE).
2. **Corrida presa em fase** → conferir eventos + `ride_events` último evento →
   `fn_ride_transition` com actor suporte (comentado em `audit_log`).
3. **Webhook PSP fora** → fila de reprocessamento idempotente (mesmo `idempotency_key`).
4. **Passe ativo sem pagamento** → bloquear novo `online` + crédito manual com auditoria (A6).
