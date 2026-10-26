-- =============================================================================
-- 10 é + — 0005_adversarial_tests.sql (run after 0001..0004; fixtures from 0003)
-- Proves the adversarial-review fixes hold under abuse:
--   AV-1 (T-21) client role cannot invoke domain SECURITY DEFINER functions
--   AV-2 (contract) withdraw/in-flight/idempotency/share-link behave as spec'd
--   AV-3 (T-20) owner cannot edit users.role / monetization_mode
-- Exit code 0 = every abuse blocked. Any abuse that succeeds = hard failure.
-- =============================================================================
\set ON_ERROR_STOP on

-- helpers ------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION _av_assert(p_cond boolean, p_label text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF p_cond THEN RAISE NOTICE 'AV-OK   %', p_label;
  ELSE RAISE EXCEPTION 'AV-FAIL % (asserção falsa)', p_label; END IF;
END $$;

CREATE OR REPLACE FUNCTION _av_assert_raises(p_label text, p_sql text, p_needle text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  BEGIN
    EXECUTE p_sql;
  EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    IF position(p_needle in SQLERRM) > 0 THEN
      RAISE NOTICE 'AV-OK   % -> %', p_label, SQLERRM;
      RETURN;
    END IF;
    RAISE EXCEPTION 'AV-FAIL %: erro inesperado: %', p_label, SQLERRM;
  END;
  EXECUTE 'RESET ROLE';
  RAISE EXCEPTION 'AV-FAIL %: ABUSO PASSOU (nenhum erro)', p_label;
END $$;

CREATE OR REPLACE FUNCTION _av_assert_count(p_label text, p_sql text, p_expected bigint)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE v bigint;
BEGIN
  EXECUTE 'RESET ROLE';
  EXECUTE p_sql INTO v;
  EXECUTE 'RESET ROLE';
  IF v = p_expected THEN RAISE NOTICE 'AV-OK   % (% linhas)', p_label, v;
  ELSE RAISE EXCEPTION 'AV-FAIL %: esperado % linhas, obtido %', p_label, p_expected, v; END IF;
END $$;

-- AV-1: fn_ledger_post() invocada por cliente autenticado -----------------------
SELECT _av_assert_raises(
  'AV-1: cliente chama fn_ledger_post (crédito fraudulento na própria wallet)',
  'SET ROLE authenticated; SELECT fn_ledger_post(gen_random_uuid(), ''' ||
    jsonb_build_array(
      jsonb_build_object('owner_type','PARTNER',
        'owner_user_id',(SELECT id FROM users WHERE phone_e164='+5569999990003'),
        'kind','WALLET','dir','C','amount','999.00','desc','fraud credit'),
      jsonb_build_object('owner_type','PLATFORM','kind','REVENUE_FEES',
        'dir','D','amount','999.00','desc','fraud credit'))::text || '''::jsonb, ''adv-fraud-1'')',
  'permission denied');
SELECT _av_assert(
  (SELECT COALESCE(balance,0) FROM partner_wallet_balance
    WHERE partner_user_id = (SELECT id FROM users WHERE phone_e164='+5569999990003')) < 900,
  'AV-1: saldo do parceiro não foi fraudado');

-- AV-1b: matriz de privilégios — toda função de domínio (fn_*) é do servidor:
--   service_role (Edge Functions) DEVE poder chamar; authenticated NÃO pode.
--   (Cobre os dois lados do remédio: EoP bloqueado sem quebrar produção.)
DO $$
DECLARE r record; n int := 0;
BEGIN
  FOR r IN SELECT p.oid::regprocedure FROM pg_proc p
           JOIN pg_namespace ns ON ns.oid = p.pronamespace
           WHERE ns.nspname = 'public' AND p.prokind = 'f' AND p.proname LIKE 'fn\_%' LOOP
    IF NOT has_function_privilege('service_role', r.oid, 'EXECUTE') THEN
      RAISE EXCEPTION 'AV-FAIL AV-1b: % sem EXECUTE para service_role (Edge Function quebraria)', r.oid;
    END IF;
    IF has_function_privilege('authenticated', r.oid, 'EXECUTE') THEN
      RAISE EXCEPTION 'AV-FAIL AV-1b: % executável por authenticated (elevação de privilégio)', r.oid;
    END IF;
    n := n + 1;
  END LOOP;
  RAISE NOTICE 'AV-OK   AV-1b: % funções de domínio exclusivas do servidor', n;
END $$;

-- AV-3: imutabilidade de colunas sensíveis (o dono edita o próprio registro) ----
SELECT set_config('app.test_uid',
  (SELECT id::text FROM users WHERE phone_e164='+5569999990001'), false);
-- users/partners não têm policy de UPDATE: o UPDATE direto casa 0 linhas
-- (deny-by-default). O trigger do 0004 é defesa em profundidade para quando o
-- módulo 1 adicionar policy de UPDATE de outras colunas (ex.: telefone).
SELECT _av_assert_count('AV-3a: auto-promoção a ADMIN não alcança nenhuma linha',
  $q$SET ROLE authenticated; UPDATE users SET role = 'ADMIN' WHERE id = auth.uid();
     SELECT count(*) FROM users WHERE id = auth.uid() AND role = 'ADMIN'$q$, 0);
SELECT _av_assert((SELECT role FROM users WHERE phone_e164='+5569999990001') = 'PASSENGER',
  'AV-3a: role do passageiro intacto');
SELECT set_config('app.test_uid',
  (SELECT id::text FROM users WHERE phone_e164='+5569999990003'), false);
SELECT monetization_mode AS mode_before FROM partners
  WHERE user_id = (SELECT id FROM users WHERE phone_e164='+5569999990003') \gset
SELECT _av_assert_count('AV-3b: troca de monetization_mode não alcança nenhuma linha',
  $q$SET ROLE authenticated; UPDATE partners SET monetization_mode =
       CASE WHEN monetization_mode='COMISSAO' THEN 'PASSE_ATIVO' ELSE 'COMISSAO' END
     WHERE user_id = auth.uid();
     SELECT count(*) FROM partners WHERE user_id = auth.uid()$q$, 1);
SELECT _av_assert(
  (SELECT monetization_mode FROM partners
    WHERE user_id = (SELECT id FROM users WHERE phone_e164='+5569999990003')) = :'mode_before',
  'AV-3b: modo do parceiro não foi adulterado');
-- defesa em profundidade (trigger do 0004): com uma policy de UPDATE
-- temporária (cenário futuro do módulo 1), a coluna role continua bloqueada
BEGIN;
CREATE POLICY p_test_users_upd ON users FOR UPDATE
  USING (id = app_uid()) WITH CHECK (true);
SELECT set_config('app.test_uid',
  (SELECT id::text FROM users WHERE phone_e164='+5569999990001'), false);
SELECT _av_assert_raises('AV-3c: trigger bloqueia edição de role mesmo com policy de UPDATE',
  'SET ROLE authenticated; UPDATE users SET role = ''ADMIN'' WHERE id = auth.uid()',
  'immutable');
ROLLBACK;

-- AV-2b: saques (contrato: 202 enfileirado; 409 in-flight / insufficient) --------
-- parceiro lê o próprio saldo via papel autenticado (policy de leitura ok)
SELECT _av_assert_count('AV-2b0: parceiro vê próprio saldo na view',
  $q$SET ROLE authenticated; SELECT count(*) FROM partner_wallet_balance WHERE partner_user_id = auth.uid()$q$, 1);
SELECT id AS att_partner FROM users WHERE phone_e164='+5569999990003' \gset
SELECT gen_random_uuid() AS wd_key \gset
SELECT _av_assert(fn_withdraw_request(:'att_partner'::uuid, 10, :'wd_key'::uuid) IS NOT NULL,
  'AV-2b1: saque REQUESTED criado');
SELECT _av_assert(fn_withdraw_request(:'att_partner'::uuid, 10, :'wd_key'::uuid) =
    (SELECT id FROM withdrawals WHERE idempotency_key = :'wd_key'::uuid),
  'AV-2b2: replay da mesma Idempotency-Key devolve o mesmo saque');
SELECT _av_assert_raises('AV-2b3: segundo saque em voo -> 409',
  format('SELECT fn_withdraw_request(%L, 5, gen_random_uuid())', :'att_partner'::uuid),
  'withdrawal_in_flight');
UPDATE withdrawals SET status = 'FAILED', failure_reason = 'teste';
SELECT _av_assert_raises('AV-2b4: saque acima do saldo -> 409',
  format('SELECT fn_withdraw_request(%L, 999999999, gen_random_uuid())', :'att_partner'::uuid),
  'insufficient_balance');

-- AV-2a: idempotência genérica (replay protegido; linha alheia invisível) --------
SELECT set_config('app.test_uid',
  (SELECT id::text FROM users WHERE phone_e164='+5569999990001'), false);
SELECT _av_assert_count('AV-2a1: cliente grava própria chave de idempotência',
  $q$SET ROLE authenticated; INSERT INTO idempotency_keys(user_id,key,endpoint,request_hash)
     SELECT auth.uid(), gen_random_uuid(), 'POST /rides', 'h'; SELECT count(*) FROM idempotency_keys WHERE user_id = auth.uid()$q$, 1);
SELECT _av_assert_count('AV-2a2: chave de outro usuário invisível (RLS)',
  $q$SET ROLE authenticated; SELECT count(*) FROM idempotency_keys WHERE user_id <> auth.uid()$q$, 0);

-- AV-2c: link de compartilhamento (visitante não consulta a tabela; dono vê) -----
INSERT INTO ride_share_links(ride_id, token_hash, created_by, expires_at)
SELECT r.id, 'hash-teste-1', r.passenger_user_id, now() + interval '30 minutes'
  FROM rides r WHERE r.passenger_user_id = (SELECT id FROM users WHERE phone_e164='+5569999990001') LIMIT 1;
SELECT _av_assert_count('AV-2c1: passageiro vê o link da própria corrida',
  $q$SET ROLE authenticated; SELECT count(*) FROM ride_share_links WHERE created_by = auth.uid()$q$, 1);
SELECT set_config('app.test_uid',
  (SELECT id::text FROM users WHERE phone_e164='+5569999990002'), false);
SELECT _av_assert_count('AV-2c2: passageiro alheio não vê o link',
  $q$SET ROLE authenticated; SELECT count(*) FROM ride_share_links$q$, 0);

-- invariante final: ledger continua balanceado e sem fraude ---------------------
SELECT _av_assert(
  (SELECT COALESCE(SUM(CASE WHEN e.direction='C' THEN e.amount ELSE -e.amount END),0)
     FROM ledger_entries e) = 0,
  'FIM: ledger ainda soma 0.00 após toda a suíte de abuso');

SELECT 'ADVERSARIAL_SUITE_OK' AS result;
