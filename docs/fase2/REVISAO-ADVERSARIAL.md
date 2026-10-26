# Revisão adversarial de fechamento — Fase 2 (GATE 2)

> Método: atacar os próprios artefatos como se o adversário tivesse o repo.
> Cada achado virou **correção + teste executável** (suíte `0005_adversarial_tests.sql`).
> Validação final: cadeia limpa `0001 → 0002 → 0003 → 0004 → 0005` em Docker
> PG16+PostGIS, **todos exit 0, 18/18 verificações AV-OK**, E2E do 0003 intacto.

## 1. Achados e correções

| ID | Achado | Sev | Correção | Prova |
|---|---|---|---|---|
| **AV-1** | **Elevação de privilégio**: `fn_ledger_post()` e todas as funções `SECURITY DEFINER` eram executáveis por **qualquer papel** (Postgres dá `EXECUTE` a `PUBLIC` por default). Um parceiro podia creditar a própria wallet chamando a função direto. | **Crítico** | `REVOKE ... FROM PUBLIC/anon` + `GRANT` mínimo dos helpers de policy (0002 §13 + 0004) | AV-1: `permission denied for function fn_ledger_post`; saldo inalterado |
| **AV-1r** | Regressão do próprio remédio: o REVOKE também tirou `EXECUTE` do `service_role` — **todas as Edge Functions ficariam sem poder chamar as `fn_*` em produção** (o teste E2E do 0003 não pegaria: roda como superuser). | **Alto** | Loop de `GRANT ... TO service_role` para todo `fn_*` (0002 §13 + 0004) | AV-1b: matriz de privilégios — toda `fn_*` com `EXECUTE` só para `service_role`, nunca para `authenticated` |
| **AV-2** | Contrato (openapi.yaml) prometia 3 superfícies **sem tabela**: `Idempotency-Key` genérico, `/partner/wallet/withdraw`, `/rides/{id}/share`. | Alto | `0004`: `idempotency_keys`, `withdrawals` (1 em voo/parceiro, `psp_transfer_id UNIQUE`), `ride_share_links` (token hasheado, expirável) + `fn_withdraw_request` | AV-2a/b/c: replay idem, 409 in-flight, 409 saldo, RLS de link alheio |
| **AV-2r** | `GRANT ... ON ALL TABLES` do 0002 roda **antes** das tabelas do 0004 existir: tabelas novas nasciam sem privilégio para `authenticated` ("permission denied for table idempotency_keys"). | Médio | grants explícitos no 0004 | AV-2a1 verde |
| **AV-2s** | `fn_withdraw_request` nasceu sem a `Idempotency-Key` que o contrato exige (sacaria 2× com a mesma chamada). | Médio | assinatura `(p_partner, p_amount, p_idem)`; replay devolve o mesmo id | AV-2b2 verde |
| **AV-3** | **T-20 reavaliado com mais precisão**: `users`/`partners` **não têm policy de UPDATE** — o UPDATE direto casa 0 linhas (deny-by-default), então o "gap de colunas" da Parte 3 não era explorável nessas tabelas. Mantido trigger de imutabilidade como defesa para o cenário futuro (policy de UPDATE de outras colunas no módulo 1). | Corrigido/ documentado | 0004: `trg_immutable_cols` | AV-3a/b: 0 linhas + estado intacto; AV-3c: trigger dispara mesmo com policy de UPDATE temporária |

**Defeito de artefato meu, pego pela própria suíte** (o sistema funciona):
`CREATE TR` (typo), assinatura errada em teste de abuso, uuid aleatório no teste
de saque — cada um abortou a cadeia com mensagem localizada antes de virar
"falso verde".

## 2. O que a revisão NÃO encontrou (já estava correto)

- Recursão de RLS (fix da Parte 3) — `app_role()` definer com `search_path` fixo em **todas** as 13+ funções.
- Append-only, Σ ledger = 0, idempotência de webhook, snapshot imutável — invariantes reafirmadas pelo 0003 + fim do 0005.
- Webhook PSP como única rota sem JWT — assinatura obrigatória (T-04).

## 3. Limite honesto da revisão

- A validação roda com `auth.uid()` stub; no Supabase o mecanismo real é análogo
  (claim JWT), mas a cadeia será reexecutada contra o projeto real no **módulo 1 da Fase 4**.
- `service_role` continua bypass por design (fronteira confiável = Edge Function);
  o que a revisão garantiu é que **nenhum papel de cliente** chega a ela.
- Cenários não cobertos aqui: cliente mobile adulterado (mitigado por servidor-centrista),
  abuso de cota Google (T-18 — mitigação operacional, não código).

## 4. Status do GATE 2

| Critério do gate | Estado |
|---|---|
| DDL completo e executável (30 tabelas, partições, índices) | ✓ 0001 validado em execução |
| RLS deny-by-default + máquina de estados + catálogo de eventos | ✓ 0002 + abuso rejeitado |
| E2E dos dois modos de monetização com ledger balanceado | ✓ 0003 |
| Contrato OpenAPI + specs algorítmicas | ✓ openapi.yaml (22 paths/24 ops) + SPECS.md |
| Threat model STRIDE com ações rastreáveis | ✓ THREAT-MODEL.md (A1..A16) |
| SLOs/observabilidade | ✓ SLOS.md |
| Custo/capacidade 1k/10k/100k | ✓ CUSTO-CAPACIDADE.md (preços oficiais 10/2026) |
| Plano de testes | ✓ PLANO-TESTES.md |
| Revisão adversarial com correções provadas | ✓ este documento + 0005 (18/18) |
| **Aprovação humana do gate** | **PENDENTE — é com o produto** |

Bloqueios externos que atravessam a Fase 3 (não do gate): advogado (Tema 1.291),
contador (ISS/NFS-e), SEMTRAN (LC 856/2021), proposta comercial do PSP — todos
já registrados no PRODUTO-MESTRE §9.
