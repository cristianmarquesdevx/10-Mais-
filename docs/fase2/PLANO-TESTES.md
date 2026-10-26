# Plano de testes — Fase 2 · dezemais

> Princípio do dev solo: **o que protege dinheiro roda em CI a cada mudança;
> o que protege humano roda em checklist antes de cada release.**
> Base já executável: `0003_smoke_e2e.sql` (E2E SQL) + suíte de abuso RLS.

## 1. Pirâmide e onde roda

| Nível | O quê | Ferramenta | Onde |
|---|---|---|---|
| L0 estático | lint de SQL (toda tabela nova exige política RLS), lint de contrato (toda rota nova no OpenAPI tem função correspondente), scanner de segredos | CI (script) | a cada push |
| L1 unitário | domínio puro (preço, matching score, regras R9/R10) | testes Dart (Flutter) | a cada push |
| L2 SQL | funções de domínio, guardas, ledger, idempotência | container PG16+PostGIS (`0001→0003`) | a cada push |
| L3 propriedade | invariantes sob entradas aleatórias | pgTAP/PL + Dart (ver §3) | a cada push (noturno se lento) |
| L4 contrato | Edge Functions × openapi.yaml | script de contract test | a cada deploy preview |
| L5 E2E | fluxos ponta a ponta (app emulado + backend) | integration_test (Flutter) + supabase local | antes de merge em main |
| L6 carga | curvas de volume e latência | k6 contra stack local | semanal / antes de gate |
| L7 campo | aparelhos reais, rede ruim, bateria | checklist manual | antes de cada release |

## 2. L2 — suíte SQL (a que já existe, mais o que falta)

Já verde em Docker (verificado nesta fase):
- E2E corrida **COMISSAO** (comissão 2,27 / wallet 16,63 / Σ ledger 0,00) e **PASSE** (ativo no 1º online, snapshot imutável, comissão 0);
- replay de webhook idempotente; ledger desbalanceado rejeitado;
- 5 abusos RLS: leitura alheia, UPDATE direto em status, INSERT direto no ledger, extrato alheio, função definer invocada por papel comum (**novo, desta rodada**).

A acrescentar no módulo 1 (mesma suíte, mesmo container):
- cancelamento com `counts_as_fault` (R9: 5 faltas/7d → bloqueio 12h);
- expiração de oferta (15 s) → reoferta; negociação: piso 0,7×, 3 rounds, TTL 60 s, rate limit 3/h;
- passe: agendado → ativa no primeiro online (A2) → expiração por relógio corrido;
- saque: saldo insuficiente e com dívida → 409; saque cria `withdrawals` (ver §6);
- `fn_finish_ride`: `fare_total` fora da tolerância → `audit_log` + FALHA_PAGAMENTO (A6/T-06).

## 3. L3 — propriedades (as invariantes caras)

| Propriedade | Gerador | Falha = bug |
|---|---|---|
| **Σ ledger = 0** após N operações aleatórias (corridas, passes, saques, estornos) | seed aleatório de 1.000 corridas | qualquer Σ ≠ 0 |
| **Preço nunca < piso** e é determinístico (mesmos parâmetros → mesmo preço) | pares origem/destino aleatórios dentro do geofence | valor fora da faixa |
| **Neutralidade do modo** (RSK-003): corrida idêntica em PASSE e COMISSÃO produz mesmo preço ao passageiro; só o repasse ao parceiro difere | simulador SQL (SPECS) | diferença no lado do passageiro |
| **Anti-starvation**: em sequência simulada, todo parceiro qualificado recebe oferta em ≤ k rodadas | simulador de despacho (SPECS) | parceiro esquecido |
| **Idempotência**: toda função de domínio chamada 2× com a mesma chave → mesmo estado | replay aleatório | divergência |
| **Retenção**: nenhuma linha de posição com ts > 7 d após job de drop | cron | linha velha |

## 4. L4/L5 — contrato e E2E de app

- Contract: para cada uma das 24 operações do openapi.yaml → request de exemplo → status e schema esperados (falha se rota mudar sem versionar).
- E2E Flutter (emulado, backend `supabase start`): cadastro passageiro → busca → corrida → pagamento PIX simulado; parceiro: KYC (stub) → online → oferta → aceite → transições → finish. Rede **offline no meio** (posições enfileiradas, retomada) — requisito central da Fase 1.
- Dois cenários negativos obrigatórios: app desatualizado enviando versão antiga de payload (409/422 esperado) e sessão revogada (401).

## 5. L6 — carga (k6, stack local)

| Cenário | Curva | Gate |
|---|---|---|
| Despacho sob demanda de pico | 100 corridas/min por 10 min, 300 parceiros ofertados | p95 matching < 10 s; 0 corrida sem oferta |
| Heartbeat | 500 parceiros × 1 lote/5 s | p95 insert < 100 ms; banco < 70% CPU |
| Realtime | 500 conexões (limite Pro) | p95 entrega evento < 2 s → se estourar, dispara gate RSK-007 |
| Webhook burst | 200 webhooks/min | 0 duplicação, p95 < 60 s |

## 6. Achados da revisão adversarial viram teste

| Achado | Teste que passa a existir |
|---|---|
| Funções `SECURITY DEFINER` executáveis por `authenticated` (T-21) | L2: `SET ROLE authenticated; SELECT fn_ledger_post(...)` → **permission denied** |
| Sem tabela de idempotência genérica nem de saque/share (§7 do relatório de revisão) | L2: replay de qualquer mutação com a mesma `Idempotency-Key` → 200 com mesmo resultado, 0 efeito colateral |
| Colunas sensíveis editáveis pelo dono (T-20) | L2: `UPDATE users SET role='ADMIN'` como dono → rejeitado (trigger A9) |

## 7. Gates de qualidade

| Gate | Exigência |
|---|---|
| Merge em main | L0–L2 verdes; sem novo `SECURITY DEFINER` sem `SET search_path` e sem REVOKE |
| Preview → staging | L3–L4 verdes |
| Release mobile | L5 verdes + checklist L7 (aparelhos: Moto G8 nível de entrada + 1 Xiaomi, RSK-008) |
| GATE 3 (Fase 3 concluída) | suíte 0003 + abuso em CI **contra o projeto Supabase real**, k6 com 100 corridas/min |
