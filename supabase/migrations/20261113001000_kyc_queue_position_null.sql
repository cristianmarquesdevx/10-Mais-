-- 10 é + — a POSIÇÃO na fila tem que concordar com a ORDEM da fila.
--
-- O defeito (medido no emulador e no banco):
--
--   A fila é ordenada por `(sla_due_at, created_at, id)` e, no Postgres, um
--   `ASC` põe os NULLs **por último** (NULLS LAST). A POSIÇÃO, porém, era
--   calculada com comparação de LINHA:
--
--       (q.sla_due_at, q.created_at, q.id) <= (v.sla_due_at, v.created_at, v.id)
--
--   E a comparação de linha tem outra regra: quando um dos elementos é
--   NULL, o resultado é **desconhecido** (e o `WHERE` descarta a linha) —
--   não "NULL é o maior", como no `ORDER BY`. Resultado: um caso SEM
--   prazo (o `sla_due_at` é NULL) não contava NENHUM caso à sua frente e
--   recebia **posição 0** — sendo o ÚLTIMO da fila. A tela da operação
--   mostrava "#1" em cima de "#0": dois números que não contam nada.
--
-- A correção: a posição passa a ser contada com a MESMA semântica do
-- `ORDER BY` (NULLS LAST, desempate por entrada e id):
--
--   * caso COM prazo: contam os casos com prazo que o precedem
--     (prazo, entrada, id) — os sem prazo vêm depois, e não contam;
--   * caso SEM prazo: contam TODOS os casos com prazo (eles vêm antes) e
--     os casos sem prazo que o precedem por (entrada, id).
--
-- A fila e a posição passam a dizer a mesma coisa — o que a operação lê
-- no topo da tela é o mesmo número que o `fn_kyc_queue_position` devolve.
--
-- Idempotente: `CREATE OR REPLACE FUNCTION` com a mesma assinatura.

CREATE OR REPLACE FUNCTION fn_kyc_queue_position(p_case uuid)
RETURNS integer
LANGUAGE sql STABLE AS $$
  SELECT count(*)::int
    FROM kyc_cases q
   CROSS JOIN (SELECT c.sla_due_at, c.created_at, c.id
                 FROM kyc_cases c WHERE c.id = p_case) v
   WHERE q.status IN ('IN_REVIEW','RESUBMIT')
     AND (
       -- O caso SEM prazo é o ÚLTIMO da fila (NULLS LAST, como o
       -- `ORDER BY`): todos os casos com prazo vêm antes dele.
       (v.sla_due_at IS NULL AND q.sla_due_at IS NOT NULL)
       -- O caso COM prazo: contam os casos com prazo que o precedem.
       -- (Os sem prazo vêm depois e não contam.)
       OR (v.sla_due_at IS NOT NULL AND q.sla_due_at IS NOT NULL
           AND (q.sla_due_at, q.created_at, q.id)
               <= (v.sla_due_at, v.created_at, v.id))
       -- O caso SEM prazo: entre os sem prazo, desempata por entrada e id.
       OR (v.sla_due_at IS NULL AND q.sla_due_at IS NULL
           AND (q.created_at, q.id) <= (v.created_at, v.id))
     );
$$;

COMMENT ON FUNCTION fn_kyc_queue_position(uuid) IS
  'Posição do caso na fila (1 = o próximo). A contagem usa a MESMA ordem '
  'da fila (prazo, entrada, id; sem prazo = último), para o número da '
  'tela e a ordem da tela nunca discordarem.';
