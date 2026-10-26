-- =============================================================================
-- 10 é + — 0004_gap_fixes.sql (Fase 2 Parte 5/5 — revisão adversarial)
-- Depends on 0001_schema.sql + 0002_rls_states_events.sql.
--
-- Achados da revisão adversarial de fechamento (ver REVISAO-ADVERSARIAL.md):
--   AV-1 (T-21) As funções SECURITY DEFINER do 0002 eram executáveis por
--               QUALQUER papel (Postgres dá EXECUTE a PUBLIC por default):
--               um passageiro auferente poderia chamar fn_ledger_post()
--               diretamente e creditar a própria wallet. Corrigido aqui
--               (REVOKE total + GRANT mínimo dos helpers de policy) e no
--               0002 §13 (mesmo remédio para quem aplica as duas migrações).
--   AV-2       O contrato (openapi.yaml) prometia 3 superfícies sem tabela:
--               Idempotency-Key genérico (replays retornam o resultado
--               original), /partner/wallet/withdraw e /rides/{id}/share.
--   AV-3 (T-20) O dono da linha podia editar users.role e
--               partners.monetization_mode (RLS não filtra colunas).
-- Local-safe: nada aqui depende de extensão ou serviço.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- AV-1 — funções de domínio: só o servidor as invoca
-- -----------------------------------------------------------------------------
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC;
DO $$
DECLARE r record;
BEGIN
  IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'anon') THEN
    EXECUTE 'REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM anon';
  END IF;
END $$;

-- Policy helpers precisam ser executáveis pelo invoker (policies rodam como
-- authenticated). Todas as fn_* continuam exclusivas do service_role/owner.
GRANT EXECUTE ON FUNCTION app_uid(), app_role(), app_is_agent(), app_is_admin(),
                          city_param(uuid, text, jsonb)
  TO authenticated, service_role;
-- devolve EXECUTE das funções de domínio a service_role (Edge Functions), que
-- REVOKE acima removeu junto com o PUBLIC-derived privilege
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT p.oid::regprocedure FROM pg_proc p
           JOIN pg_namespace ns ON ns.oid = p.pronamespace
           WHERE ns.nspname = 'public' AND p.prokind = 'f' AND p.proname LIKE 'fn\_%' LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role', r.oid::regprocedure);
  END LOOP;
END $$;

-- -----------------------------------------------------------------------------
-- AV-2a — idempotência genérica (contrato: replay retorna o resultado original)
-- -----------------------------------------------------------------------------
CREATE TABLE idempotency_keys (
  user_id         uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  key             uuid NOT NULL,
  endpoint        text NOT NULL,            -- ex.: 'POST /rides'
  request_hash    text NOT NULL,            -- hash do corpo: mesma chave + corpo diferente = conflito
  response_status int,
  response_body   jsonb,
  created_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, key)
);
CREATE INDEX ix_idem_created ON idempotency_keys (created_at);  -- expurgo > 24 h

-- RLS: dono lê/cria; a resposta é gravada pelo Edge Function (service_role).
ALTER TABLE idempotency_keys ENABLE ROW LEVEL SECURITY;
CREATE POLICY p_idem_self ON idempotency_keys FOR ALL
  USING (user_id = app_uid()) WITH CHECK (user_id = app_uid());

-- -----------------------------------------------------------------------------
-- AV-2b — saques (contrato: POST /partner/wallet/withdraw -> 202)
-- -----------------------------------------------------------------------------
CREATE TABLE withdrawals (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  partner_user_id  uuid NOT NULL REFERENCES users(id),
  amount           numeric(12,2) NOT NULL CHECK (amount > 0),
  status           text NOT NULL DEFAULT 'REQUESTED'
                   CHECK (status IN ('REQUESTED','PROCESSING','PAID','FAILED','CANCELLED')),
  idempotency_key  uuid NOT NULL,
  psp_transfer_id  text UNIQUE,             -- idempotência do lado do PSP
  failure_reason   text,
  requested_at     timestamptz NOT NULL DEFAULT now(),
  processed_at     timestamptz,
  UNIQUE (partner_user_id, idempotency_key) -- replay não duplica saque
);
-- Um saque em voo por parceiro: fecha a corrida de saldo duplo enquanto o
-- ledger ainda não foi debitado (débito + estorno via fn_ledger_post no
-- retorno do PSP — lógica do módulo 1; falha = FAILED + estorno idempotente).
CREATE UNIQUE INDEX uq_withdraw_inflight ON withdrawals (partner_user_id)
  WHERE status IN ('REQUESTED','PROCESSING');

ALTER TABLE withdrawals ENABLE ROW LEVEL SECURITY;
CREATE POLICY p_withdraw_read ON withdrawals FOR SELECT
  USING (partner_user_id = app_uid() OR app_is_agent());
-- sem policy de INSERT: escrita só via fn_withdraw_request (definer)

CREATE OR REPLACE FUNCTION fn_withdraw_request(p_partner uuid, p_amount numeric, p_idem uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_balance numeric;
  v_wid     uuid;
BEGIN
  -- padrão das demais fn_*: ator vem explícito da Edge Function (uid do JWT);
  -- função é exclusiva do service_role (AV-1b)
  IF p_partner IS NULL THEN RAISE EXCEPTION 'not_authenticated'; END IF;
  -- replay da mesma Idempotency-Key devolve o mesmo saque (contrato: 200 idem)
  SELECT w.id INTO v_wid FROM withdrawals w
    WHERE w.partner_user_id = p_partner AND w.idempotency_key = p_idem;
  IF v_wid IS NOT NULL THEN RETURN v_wid; END IF;
  IF EXISTS (SELECT 1 FROM withdrawals w
             WHERE w.partner_user_id = p_partner AND w.status IN ('REQUESTED','PROCESSING')) THEN
    RAISE EXCEPTION 'withdrawal_in_flight';          -- contrato: 409
  END IF;
  SELECT COALESCE(b.balance, 0) INTO v_balance
    FROM partner_wallet_balance b WHERE b.partner_user_id = p_partner;
  IF COALESCE(v_balance, 0) < p_amount THEN
    RAISE EXCEPTION 'insufficient_balance';          -- contrato: 409
  END IF;
  INSERT INTO withdrawals(partner_user_id, amount, idempotency_key)
    VALUES (p_partner, p_amount, p_idem) RETURNING id INTO v_wid;
  RETURN v_wid;
END $$;
REVOKE EXECUTE ON FUNCTION fn_withdraw_request(uuid, numeric, uuid) FROM PUBLIC, authenticated;
GRANT EXECUTE ON FUNCTION fn_withdraw_request(uuid, numeric, uuid) TO service_role;

-- -----------------------------------------------------------------------------
-- AV-2c — link de compartilhamento (contrato: POST /rides/{id}/share)
-- -----------------------------------------------------------------------------
CREATE TABLE ride_share_links (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ride_id     uuid NOT NULL REFERENCES rides(id) ON DELETE CASCADE,
  token_hash  text NOT NULL UNIQUE,        -- sha256(token); token cru nunca persiste (T-05)
  created_by  uuid NOT NULL REFERENCES users(id),
  expires_at  timestamptz NOT NULL,
  revoked_at  timestamptz,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_share_active ON ride_share_links (ride_id) WHERE revoked_at IS NULL;

ALTER TABLE ride_share_links ENABLE ROW LEVEL SECURITY;
CREATE POLICY p_share_own ON ride_share_links FOR SELECT USING (
  created_by = app_uid()
  OR EXISTS (SELECT 1 FROM rides r WHERE r.id = ride_id AND r.passenger_user_id = app_uid()));
-- leitura do visitante do link: validação do token via service_role na Edge
-- Function (sem policy: anônimo não consulta a tabela — T-05)

-- -----------------------------------------------------------------------------
-- AV-3 — imutabilidade de colunas sensíveis para o próprio dono (T-20/A9)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_immutable_cols() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF current_user <> 'authenticated' THEN RETURN NEW; END IF;  -- funções definer/service_role passam
  IF TG_TABLE_NAME = 'users'
     AND NEW.role IS DISTINCT FROM OLD.role THEN
    RAISE EXCEPTION 'users.role is immutable for clients (T-20/A9)';
  END IF;
  IF TG_TABLE_NAME = 'partners'
     AND NEW.monetization_mode IS DISTINCT FROM OLD.monetization_mode THEN
    RAISE EXCEPTION 'partners.monetization_mode is immutable for clients (T-20/A9)';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_users_immutable BEFORE UPDATE ON users
  FOR EACH ROW EXECUTE FUNCTION trg_immutable_cols();
CREATE TRIGGER trg_partners_immutable BEFORE UPDATE ON partners
  FOR EACH ROW EXECUTE FUNCTION trg_immutable_cols();

-- -----------------------------------------------------------------------------
-- Privilégios das tabelas novas (o GRANT em ALL TABLES do 0002 rodou antes
-- delas existirem; RLS continua filtrando linha a linha)
-- -----------------------------------------------------------------------------
GRANT SELECT, INSERT, UPDATE, DELETE ON idempotency_keys, withdrawals, ride_share_links
  TO authenticated;
GRANT ALL ON idempotency_keys, withdrawals, ride_share_links TO service_role;
