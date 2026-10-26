# Threat model (STRIDE) — Fase 2 · dezemais

> IDs: T-01..T-24 · rastreia D1/D3/D5, REQ-002/003/006/007/010, RSK-007/010, LGPD.
> Cada ameaça aponta o **controle já existente** (artefato verificado por execução
> quando marcado ✓Exec) e a **ação residual**. Controles marcados `Projetado` ainda
> não têm código nesta fase.

## 1. Ativos e fronteiras de confiança

| Ativo | Por que importa |
|---|---|
| Saldo/ledger (dinheiro real) | Fraude = prejuízo direto + passivo fiscal |
| Conta parceiro + KYC (CPF, face, documentos) | Venda de conta = fraude sistêmica; dado sensível LGPD |
| Posições em tempo real (parceiro) | Spoofing sequestra demanda; vazamento = rastreio de pessoa |
| Reputação/ratings e cancelamentos | Manipulação distorce marketplace (R9) |
| Chave de serviço (service-role) | Bypass total de RLS |
| Cota Google Maps | DoS econômico (custo dispara sem outage) |

Fronteiras: (1) app cliente ↔ Edge Functions (JWT); (2) Edge Functions ↔ Postgres
(service-role + RLS); (3) PSP ↔ `/webhooks/psp` (assinatura); (4) parceiro app ↔
pipeline de posição (BG location); (5) console operação (AGENT/ADMIN) ↔ Postgres;
(6) terceiros: Google, FCM, PSP, provedor KYC.

## 2. Tabela STRIDE

| ID | Ameaça (superfície) | Classe | Controle (artefato) | Residual / ação |
|---|---|---|---|---|
| T-01 | Roubo de JWT / sessão (ambos apps) | S | Supabase Auth; `device_sessions` com **1 sessão ativa por conta** (0001, A7); revoke remoto | Médio → ação A1: revoke em logout + alerta de novo device |
| T-02 | Conta parceiro vendida/aproveitada no KYC | S | KYC com facial+liveness (R5) + fila manual; verificação pontual no `online` | Médio → ação A2: re-checagem facial aleatória no online (V1) |
| T-03 | GPS spoofing (parceiro falseia posição: captura corridas, infla tempo de passe) | S | `partner_positions` server-timestamp (servidor é o relogio, A7); `stale_after` | **Alto** → ação A3: validação de plausibilidade no heartbeat (velocidade máx implausível, salto, accuracy) + score de fraude; RSK-010 |
| T-04 | Webhook PSP forjado (marca corrida paga / ativa passe) | S | Assinatura verificada + endpoint sem JWT (`security: []`) + `payments.idempotency_key UNIQUE` ✓Exec (E2E replay) | Baixo → ação A4: rejeitar assinatura fora de janela 5 min; logar IP |
| T-05 | Link de compartilhamento vazado | S/I | `/share` retorna token opaco, expirável, somente leitura (contrato) | Baixo → ação A5: 1 token por corrida, revoga no fim |
| T-06 | Cliente altera preço (`proposed_amount`, `fare_total`) | T | Preço calculado no servidor; piso/teto do `city_configs`; CHECK `chk_snapshot_from_aceita` ✓Exec (rejeitou corrida pós-aceite sem snapshot) | Baixo → ação A6: `fare_total` declarado × tarifa calculada: variação > 10% → `audit_log` + disputa |
| T-07 | Manipulação do ledger | T | Append-only (trigger) ✓Exec; RLS deny no INSERT ✓Exec ("violates row-level security policy"); `fn_ledger_post` exige Σ=0 ✓Exec | Baixo → ação A7: reconciliação diária Σ=0 + saldo vs `partner_wallets` view (job módulo 4) |
| T-08 | Replay de webhook/evento | T | `idempotency_key` único por partição ✓Exec (replay não duplicou lançamentos) | Baixo |
| T-09 | Recusa de pagamento em DINHEIRO (passageiro diz pagou / parceiro diz não recebeu — ADR-003) | T/R | Confirmação do passageiro + `cash_declared` do parceiro; eventos imutáveis | **Alto operacional** → ação A8: divergência entre declarações abre ticket automático com trilha |
| T-10 | Negação de transição ("eu não finalizei") | R | Transição só por função de domínio; `ride_events` imutável com actor/`occurred_at`/`received_at`/idempotency ✓Exec; `audit_log` | Baixo ✓ |
| T-11 | Suporte/operador nega atendimento | R | `ticket_messages` append-only; SLA timestamps; `audit_log` | Baixo |
| T-12 | Leitura de dados alheios via API | I | RLS deny-by-default em 31 tabelas; 5 testes de abuso verdes ✓Exec (leitura alheia 0 linhas, UPDATE direto 0, ledger rejeitado, extrato alheio 0) | **Gap conhecido**: RLS não filtra **colunas** → ação A9 (bloqueia T-20) |
| T-13 | Vazamento de KYC/PII em repouso ou violação LGPD | I | Posições: retenção 7 d via drop de partição; fotos entrega: expiração 30 d (R7); nunca PAN (token PSP) | **Alto** → ação A10: criptografia de repouso de `kyc_documents`/OCR [VERIFICAR Supabase]; direitos do titular (export/delete) sem apagar o que a fiscal exige 5 anos [VERIFICAR] |
| T-14 | PII em logs/traces | I | Payloads de evento sem documento/PAN; `trace_id` opaco no problem+json (contrato) | Baixo → ação A11: sanitizador de log no módulo 1 |
| T-15 | Chave service-role no cliente | E | Só em Edge Functions; apps usam JWT anônimo | Baixo → ação A12: checklist de build + scanner de segredos no CI |
| T-16 | Flood de chamadas (heartbeat, offers, negociação) | D | Batch ≤ 100 pontos; rate limit negociação 3/h (SPECS); uma corrida ativa por passageiro | Médio → ação A13: rate limit por uid em toda rota (Supabase WAF/limiter) |
| T-17 | Retry storm em mutação | D | `Idempotency-Key` obrigatório em toda mutação; replay retorna 200 sem efeito ✓Exec | Baixo |
| T-18 | Estouro de cota Google = custo descontrolado | D | Chave restringida (App/HTTP referrer) + orçamento com alerta; cache de geocoding ≤ 30 d (regra Google); polling de ETA **proibido** (SPECS/R1) | Médio → ação A14: alerta diário de custo > 120% do previsto |
| T-19 | Realtime saturado (posições) | D | Posições via batch offline-tolerante, não 1 por ponto; gate RSK-007: p95 > 2 s → serviço dedicado | Médio (Pro = 500 conexões de pico, ver CUSTO) |
| T-20 | Escalação de papel: dono da linha edita `users.role` / `partners.monetization_mode` | E | **Reavaliado e fechado**: `users`/`partners` não têm policy de UPDATE (deny-by-default, 0 linhas) + trigger `trg_immutable_cols` como defesa para quando o módulo 1 adicionar policy de UPDATE de outras colunas | Baixo ✓Exec (AV-3a/b/c) |
| T-21 | Invocação direta de função `SECURITY DEFINER` por papel comum (ex.: `fn_ledger_post` creditando a própria wallet) | E | **Corrigido nesta revisão**: `REVOKE ... FROM PUBLIC, anon, authenticated` + `GRANT` só a `service_role` (0002 §13) ✓Exec (teste de abuso: permission denied) | Baixo ✓ |
| T-22 | Hijack de `search_path` em função definer | E | Todas as funções com `SET search_path = public, pg_temp` (verificado em 0002, 13 funções) ✓ | Baixo ✓ |
| T-23 | ADMIN/AGENT contorna regra de dinheiro | E | Nenhuma função de mutação de ledger exposta; agent só **lê** (policy `app_is_agent()` no SELECT) ✓Exec | Baixo → ação A15: regra explícita "nem admin muta ledger" no console (Fase 3) |
| T-24 | Exfiltração via endpoint legado/rota esquecida | E | Contrato único (openapi.yaml, 24 ops); tudo atrás de JWT + RLS; webhook é a única rota `security: []` | Baixo → ação A16: teste de contract no CI: toda rota nova exige política RLS correspondente (lint SQL) |

## 3. Ações derivadas (para o módulo 1 / Fase 4)

| Ação | Ameaças | Prioridade |
|---|---|---|
| A9 — trigger de imutabilidade de `users.role` e `partners.monetization_mode` | T-12, T-20 | **P0** |
| A3 — plausibilidade de posição + score de fraude | T-03, RSK-010 | **P0** |
| A6/A8 — conferência de `fare_total` + divergência cash → ticket | T-06, T-09 | **P0** |
| A4/A5 — janela de assinatura PSP, token de share com revogação | T-04, T-05 | P1 |
| A1/A2/A10..A16 | demais | P1–P2 |

## 4. LGPD (consolidação)

| Tratamento | Base/controle |
|---|---|
| Posições (parceiro) | Execução de contrato; retenção **7 d** (drop de partição) ✓Exec |
| Fotos de entrega | LGPD/R7: expiração **30 d** |
| KYC (CPF, face, documentos) | Consentimento + obrigação legal; criptografia de repouso [VERIFICAR]; acesso restrito a AGENT |
| Dados fiscais (receita, NFS-e) | Obrigação legal — **não** apagável no delete do titular [VERIFICAR prazo 5 anos] |
| Titular | Exportação e exclusão via fluxo de suporte (módulo 1); exclusão anonimiza perfil, preserva ledger |

## 5. Projetado × verificado por execução

- **Verificado em Docker (PG16+PostGIS):** T-04 (replay idempotente), T-07 (deny + Σ=0),
  T-08 (idempotência), T-10 (transições/imutabilidade), T-12 (5 abusos RLS),
  T-22 (search_path fixado), T-21 (revogação + matriz de privilégios AV-1b),
  T-20 (AV-3a/b/c) — suíte 0005: 18/18 na cadeia limpa 0001→0005.
- **Projetado (sem código nesta fase):** T-01/02 (auth real do Supabase), T-03 (plausibilidade),
  T-05/13/14/15/16/18 (Edge Functions + LGPD), T-19 (gate medido em produção).
