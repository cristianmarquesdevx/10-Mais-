-- =============================================================================
-- 10 e + — 0002_rls_states_events.sql (Fase 2 Parte 3/5)
-- Depends on 0001_schema.sql. Target: Supabase (Postgres) — local-safe:
--   * auth.uid() stub is created ONLY if missing (Supabase already has it).
--   * roles authenticated/service_role created ONLY if missing.
-- Design:
--   * Deny-by-default: RLS enabled on every table; no policy == no access.
--   * All state transitions go through SECURITY DEFINER domain functions
--     (D1: direct UPDATE on status is forbidden); each transition emits an
--     immutable ride_events row with idempotency_key.
--   * ledger_entries: SELECT for partners (own), INSERT only via fn_ledger_post
--     (validates double-entry sum = 0 before writing).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 0. Local-safe roles & auth stub (no-ops on Supabase)
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'authenticated') THEN
    CREATE ROLE authenticated NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'service_role') THEN
    CREATE ROLE service_role NOLOGIN BYPASSRLS;
  END IF;
END $$;

GRANT USAGE ON SCHEMA public TO authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO authenticated;
GRANT ALL ON ALL TABLES IN SCHEMA public TO service_role;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO authenticated, service_role;

DO $stubcheck$
BEGIN
  IF to_regprocedure('auth.uid()') IS NULL THEN
    CREATE SCHEMA auth;
    -- local test only: psql -c "SET app.test_uid = '<uuid>'"
    CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS
      $fn$ SELECT nullif(current_setting('app.test_uid', true), '')::uuid $fn$;
  END IF;
END $stubcheck$;

-- authenticated must be able to resolve auth.uid() inside policies (Supabase does this)
GRANT USAGE ON SCHEMA auth TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION auth.uid() TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 1. Helpers
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION app_uid() RETURNS uuid LANGUAGE sql STABLE AS
  $$ SELECT auth.uid() $$;

-- SECURITY DEFINER: policies on users call app_is_agent(); without definer the
-- users RLS would recurse (policy -> app_role -> users -> policy -> ...)
CREATE OR REPLACE FUNCTION app_role() RETURNS text LANGUAGE sql STABLE SECURITY DEFINER
  SET search_path = public, pg_temp AS
  $$ SELECT role FROM users WHERE id = app_uid() $$;

CREATE OR REPLACE FUNCTION app_is_agent() RETURNS boolean LANGUAGE sql STABLE AS
  $$ SELECT app_role() IN ('AGENT','ADMIN') $$;

CREATE OR REPLACE FUNCTION app_is_admin() RETURNS boolean LANGUAGE sql STABLE AS
  $$ SELECT app_role() = 'ADMIN' $$;

-- City parameter with fallback (T7: never hardcoded; fallback = documented default)
CREATE OR REPLACE FUNCTION city_param(p_city uuid, p_key text, p_default jsonb)
RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT COALESCE((SELECT param_value FROM city_config_current
                   WHERE city_id = p_city AND param_key = p_key LIMIT 1), p_default);
$$;

-- -----------------------------------------------------------------------------
-- 2. Event emission (immutable, idempotent)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_emit_event(
  p_ride uuid, p_type text, p_payload jsonb, p_actor uuid, p_idem text
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  -- events without a ride (pass, blocks) use the zero-uuid sentinel (PK needs NOT NULL)
  INSERT INTO ride_events(ride_id, event_type, payload, actor_user_id, idempotency_key, occurred_at)
  VALUES (COALESCE(p_ride, '00000000-0000-0000-0000-000000000000'::uuid),
          p_type, COALESCE(p_payload,'{}'), p_actor, p_idem, now())
  ON CONFLICT DO NOTHING;  -- replay-safe (unique idempotency_key per partition)
END $$;

-- -----------------------------------------------------------------------------
-- 3. Ledger (double-entry; sum must be zero)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_ledger_post(
  p_group uuid, p_entries jsonb, p_idem text
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE e jsonb; acc_id uuid; sum_d numeric := 0; sum_c numeric := 0; idx int := 0;
BEGIN
  FOR e IN SELECT jsonb_array_elements(p_entries) LOOP
    SELECT id INTO acc_id FROM ledger_accounts
     WHERE owner_type = e->>'owner_type'
       AND owner_user_id IS NOT DISTINCT FROM (e->>'owner_user_id')::uuid
       AND kind = e->>'kind';
    IF acc_id IS NULL THEN
      RAISE EXCEPTION 'ledger account missing: %/%/%', e->>'owner_type', e->>'owner_user_id', e->>'kind';
    END IF;
    IF e->>'dir' = 'D' THEN sum_d := sum_d + (e->>'amount')::numeric;
    ELSE sum_c := sum_c + (e->>'amount')::numeric; END IF;
  END LOOP;
  IF sum_d <> sum_c THEN
    RAISE EXCEPTION 'ledger not balanced: D % <> C %', sum_d, sum_c;  -- invariant 1
  END IF;
  FOR e IN SELECT jsonb_array_elements(p_entries) LOOP
    idx := idx + 1;
    SELECT id INTO acc_id FROM ledger_accounts
     WHERE owner_type = e->>'owner_type'
       AND owner_user_id IS NOT DISTINCT FROM (e->>'owner_user_id')::uuid
       AND kind = e->>'kind';
    INSERT INTO ledger_entries(entry_group_id, account_id, ride_id, pass_id,
                               direction, amount, description, idempotency_key)
    VALUES (p_group, acc_id, (e->>'ride_id')::uuid, (e->>'pass_id')::uuid,
            e->>'dir', (e->>'amount')::numeric, e->>'desc', p_idem || ':' || idx)
    ON CONFLICT DO NOTHING;
  END LOOP;
END $$;

-- -----------------------------------------------------------------------------
-- 4. Ride state machine (D1: only these functions may move status)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_ride_request(
  p_passenger uuid, p_city uuid, p_origin geography, p_destination geography,
  p_pricing jsonb, p_proposed numeric DEFAULT NULL
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE rid uuid;
BEGIN
  IF EXISTS (SELECT 1 FROM rides
              WHERE passenger_user_id = p_passenger
                AND status IN ('BUSCANDO','OFERTADA','ACEITA','A_CAMINHO','CHEGOU','EM_VIAGEM')) THEN
    RAISE EXCEPTION 'active_ride_exists';
  END IF;
  rid := gen_random_uuid();
  INSERT INTO rides(id, city_id, service_type_id, passenger_user_id, status, pricing,
                    proposed_amount, origin, destination)
  VALUES (rid, p_city, (SELECT id FROM service_types WHERE code='RIDE_CAR'),
          p_passenger, 'BUSCANDO', p_pricing, p_proposed, p_origin, p_destination);
  PERFORM fn_emit_event(rid, 'ride.created', jsonb_build_object('proposed', p_proposed), p_passenger, 'created:' || rid);
  RETURN rid;
END $$;

CREATE OR REPLACE FUNCTION fn_dispatch_offer(
  p_ride uuid, p_partner uuid, p_amount numeric
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE off uuid; t int;
BEGIN
  PERFORM 1 FROM rides WHERE id = p_ride AND status = 'BUSCANDO' FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'ride_not_searching'; END IF;
  IF NOT EXISTS (SELECT 1 FROM partners p JOIN partner_presence pr ON pr.partner_user_id = p.user_id
                  WHERE p.user_id = p_partner AND p.kyc_status = 'APPROVED'
                    AND pr.online_status IN ('ONLINE_DISPONIVEL','OFERTA_PENDENTE')) THEN
    RAISE EXCEPTION 'partner_not_available';
  END IF;
  t := (city_param((SELECT city_id FROM rides WHERE id=p_ride),'PRM-oferta.timeout','15') #>> '{}')::int;
  off := gen_random_uuid();
  INSERT INTO offers(id, ride_id, partner_user_id, sequence_no, offered_amount, timeout_at)
  VALUES (off, p_ride, p_partner,
          (SELECT COALESCE(MAX(sequence_no),0)+1 FROM offers WHERE ride_id = p_ride),
          p_amount, now() + make_interval(secs => t));
  UPDATE rides SET status = 'OFERTADA', offered_at = now() WHERE id = p_ride;
  PERFORM fn_emit_event(p_ride, 'offer.sent', jsonb_build_object('amount', p_amount), p_partner, 'offer:' || off);
  RETURN off;
END $$;

CREATE OR REPLACE FUNCTION fn_offer_accept(p_offer uuid, p_partner uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE o offers%ROWTYPE; v_pass_id uuid; mode text;
BEGIN
  SELECT * INTO o FROM offers WHERE id = p_offer FOR UPDATE;
  IF NOT FOUND OR o.partner_user_id <> p_partner OR o.status <> 'SENT' THEN
    RAISE EXCEPTION 'offer_unavailable';
  END IF;
  IF now() > o.timeout_at THEN RAISE EXCEPTION 'offer_unavailable'; END IF;  -- timeout is authoritative
  PERFORM 1 FROM rides WHERE id = o.ride_id AND status = 'OFERTADA' FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'ride_not_offered'; END IF;
  -- REQ-002/A4: mode captured IMMUTABLY at acceptance
  SELECT id INTO v_pass_id FROM partner_passes
   WHERE partner_user_id = p_partner AND status = 'ACTIVE' AND now() < expires_at LIMIT 1;
  mode := CASE WHEN v_pass_id IS NULL THEN 'COMISSAO' ELSE 'PASSE' END;
  UPDATE offers SET status = 'ACCEPTED', responded_at = now() WHERE id = p_offer;
  UPDATE rides SET status = 'ACEITA', partner_user_id = p_partner, accepted_at = now(),
                  pricing_mode_snapshot = mode, pass_id = v_pass_id
   WHERE id = o.ride_id;
  PERFORM fn_emit_event(o.ride_id, 'offer.accepted',
    jsonb_build_object('mode', mode, 'pass_id', v_pass_id), p_partner, 'accept:' || p_offer);
  RETURN o.ride_id;
END $$;

CREATE OR REPLACE FUNCTION fn_offer_expire(p_offer uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE o offers%ROWTYPE;
BEGIN
  SELECT * INTO o FROM offers WHERE id = p_offer FOR UPDATE;
  IF NOT FOUND OR o.status <> 'SENT' THEN RETURN; END IF;
  UPDATE offers SET status = 'EXPIRED', responded_at = now() WHERE id = p_offer;
  PERFORM fn_emit_event(o.ride_id, 'offer.expired', NULL, o.partner_user_id, 'expire:' || p_offer);
  -- reoffer: back to BUSCANDO when no live offers remain
  IF NOT EXISTS (SELECT 1 FROM offers WHERE ride_id = o.ride_id AND status = 'SENT') THEN
    UPDATE rides SET status = 'BUSCANDO' WHERE id = o.ride_id AND status = 'OFERTADA';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION fn_ride_transition(p_ride uuid, p_partner uuid, p_to text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE r rides%ROWTYPE; ok boolean;
BEGIN
  SELECT * INTO r FROM rides WHERE id = p_ride FOR UPDATE;
  IF r.id IS NULL THEN RAISE EXCEPTION 'ride_not_found'; END IF;
  IF r.partner_user_id IS DISTINCT FROM p_partner THEN RAISE EXCEPTION 'not_your_ride'; END IF;
  ok := (r.status = 'ACEITA'    AND p_to = 'A_CAMINHO')
     OR (r.status = 'A_CAMINHO' AND p_to = 'CHEGOU')
     OR (r.status = 'CHEGOU'    AND p_to = 'EM_VIAGEM')
     OR (r.status = 'EM_VIAGEM' AND p_to = 'FINALIZADA');
  IF NOT ok THEN RAISE EXCEPTION 'illegal_transition %->%', r.status, p_to; END IF;
  UPDATE rides SET status = p_to,
    arrived_at   = CASE WHEN p_to = 'CHEGOU'     THEN now() ELSE arrived_at END,
    started_at   = CASE WHEN p_to = 'EM_VIAGEM'  THEN now() ELSE started_at END,
    finished_at  = CASE WHEN p_to = 'FINALIZADA' THEN now() ELSE finished_at END
   WHERE id = p_ride;
  PERFORM fn_emit_event(p_ride, 'ride.' || lower(p_to), NULL, p_partner, 't:' || p_ride || ':' || p_to);
END $$;

CREATE OR REPLACE FUNCTION fn_ride_finish(p_ride uuid, p_partner uuid, p_fare numeric)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF p_fare <= 0 THEN RAISE EXCEPTION 'invalid_fare'; END IF;
  PERFORM fn_ride_transition(p_ride, p_partner, 'FINALIZADA');
  UPDATE rides SET fare_total = p_fare, payment_status = 'PENDING' WHERE id = p_ride;
END $$;

CREATE OR REPLACE FUNCTION fn_ride_cancel(p_ride uuid, p_actor uuid, p_reason text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE r rides%ROWTYPE; side text; fault boolean;
BEGIN
  SELECT * INTO r FROM rides WHERE id = p_ride FOR UPDATE;
  IF r.id IS NULL THEN RAISE EXCEPTION 'ride_not_found'; END IF;
  IF r.status IN ('FINALIZADA','EXPIRADA','CANCELADA_CLIENTE','CANCELADA_PARCEIRO',
                  'CANCELADA_SISTEMA','CANCELADA_SUPORTE') THEN
    RAISE EXCEPTION 'ride_already_closed: %', r.status;
  END IF;
  IF p_actor = r.passenger_user_id THEN side := 'PASSENGER';
  ELSIF p_actor = r.partner_user_id THEN side := 'PARTNER';
  ELSE IF NOT app_is_agent() THEN RAISE EXCEPTION 'not_participant'; END IF; side := 'SUPPORT'; END IF;
  -- R9: only user-regret faults count
  fault := p_reason IN ('PASSENGER_REGRET','PARTNER_REGRET');
  UPDATE rides SET status = CASE side
      WHEN 'PASSENGER' THEN 'CANCELADA_CLIENTE'
      WHEN 'PARTNER'   THEN 'CANCELADA_PARCEIRO'
      ELSE 'CANCELADA_SUPORTE' END,
    cancelled_at = now() WHERE id = p_ride;
  INSERT INTO cancel_events(ride_id, cancelled_by_user_id, side, reason_code, counts_as_fault)
  VALUES (p_ride, p_actor, side, p_reason, fault);
  PERFORM fn_emit_event(p_ride, 'ride.cancelled',
    jsonb_build_object('side', side, 'reason', p_reason, 'fault', fault), p_actor, 'cancel:' || p_ride);
END $$;

-- -----------------------------------------------------------------------------
-- 5. Passe (REQ-002: activation on first online, FIFO queue, server clock)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_pass_purchase(p_partner uuid, p_city uuid, p_payment uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE pid uuid; price numeric; dur int;
BEGIN
  IF EXISTS (SELECT 1 FROM partner_passes WHERE partner_user_id = p_partner AND status = 'PENDING_PAYMENT') THEN
    RAISE EXCEPTION 'purchase_in_flight';  -- A6: one pending purchase per partner
  END IF;
  price := (city_param(p_city,'PRM-passe.preco','10.00') #>> '{}')::numeric;
  dur   := (city_param(p_city,'PRM-passe.duracao','720')   #>> '{}')::int;
  pid := gen_random_uuid();
  INSERT INTO partner_passes(id, partner_user_id, city_id, price_paid, duration_minutes,
                             status, payment_id, counting_strategy)
  VALUES (pid, p_partner, p_city, price, dur, 'PENDING_PAYMENT', p_payment,
          city_param(p_city,'PRM-passe.contagem','"RELOGIO_CORRIDO"') #>> '{}');
  RETURN pid;
END $$;

-- Called by PSP webhook (idempotent): pending -> SCHEDULED (activation on first online, A2)
CREATE OR REPLACE FUNCTION fn_pass_confirm(p_payment uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE p partner_passes%ROWTYPE;
BEGIN
  SELECT * INTO p FROM partner_passes WHERE payment_id = p_payment FOR UPDATE;
  IF NOT FOUND OR p.status <> 'PENDING_PAYMENT' THEN RETURN; END IF;
  UPDATE partner_passes SET status = 'SCHEDULED' WHERE id = p.id;
  PERFORM fn_ledger_post(gen_random_uuid(),
    jsonb_build_array(
      jsonb_build_object('owner_type','PLATFORM','kind','PSP_CASH','dir','D','amount',p.price_paid,'desc','pass purchase'),
      jsonb_build_object('owner_type','PLATFORM','kind','REVENUE_PASSES','dir','C','amount',p.price_paid,'desc','pass revenue')
    ), 'pass:' || p.id);
END $$;

CREATE OR REPLACE FUNCTION fn_partner_online(p_partner uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE p partner_passes%ROWTYPE; dur int;
BEGIN
  UPDATE partner_presence SET online_status = 'ONLINE_DISPONIVEL', last_heartbeat_at = now()
   WHERE partner_user_id = p_partner;
  -- A2: scheduled pass activates on FIRST transition to online
  SELECT * INTO p FROM partner_passes WHERE partner_user_id = p_partner AND status = 'SCHEDULED' FOR UPDATE;
  IF FOUND THEN
    dur := p.duration_minutes;
    UPDATE partner_passes SET status = 'ACTIVE', activated_at = now(),
           starts_at = now(), expires_at = now() + make_interval(mins => dur)
     WHERE id = p.id;
    PERFORM fn_emit_event(NULL, 'pass.activated', jsonb_build_object('pass_id', p.id), p_partner, 'pass-on:' || p.id);
  END IF;
  UPDATE partners SET monetization_mode =
    CASE WHEN EXISTS (SELECT 1 FROM partner_passes
                       WHERE partner_user_id = p_partner AND status='ACTIVE' AND now() < expires_at)
         THEN 'PASSE_ATIVO' ELSE 'COMISSAO' END
   WHERE user_id = p_partner;
END $$;

-- Server-side tick (scheduler): expire + promote FIFO queue (A3)
CREATE OR REPLACE FUNCTION fn_pass_tick(p_partner uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE exp_id uuid; q partner_passes%ROWTYPE; dur int;
BEGIN
  SELECT id INTO exp_id FROM partner_passes
   WHERE partner_user_id = p_partner AND status = 'ACTIVE' AND now() >= expires_at FOR UPDATE;
  IF exp_id IS NOT NULL THEN
    UPDATE partner_passes SET status = 'EXPIRED' WHERE id = exp_id;
    PERFORM fn_emit_event(NULL, 'pass.expired', jsonb_build_object('pass_id', exp_id), p_partner, 'pass-exp:' || exp_id);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM partner_passes WHERE partner_user_id = p_partner AND status = 'ACTIVE') THEN
    SELECT * INTO q FROM partner_passes WHERE partner_user_id = p_partner AND status = 'QUEUED'
     ORDER BY created_at LIMIT 1 FOR UPDATE;
    IF FOUND THEN
      dur := q.duration_minutes;
      UPDATE partner_passes SET status = 'ACTIVE', activated_at = now(), starts_at = now(),
             expires_at = now() + make_interval(mins => dur) WHERE id = q.id;
    END IF;
  END IF;
  UPDATE partners SET monetization_mode =
    CASE WHEN EXISTS (SELECT 1 FROM partner_passes
                       WHERE partner_user_id = p_partner AND status='ACTIVE' AND now() < expires_at)
         THEN 'PASSE_ATIVO' ELSE 'COMISSAO' END
   WHERE user_id = p_partner;
END $$;

-- -----------------------------------------------------------------------------
-- 6. Payment confirmation -> ledger by immutable snapshot (REQ-010, ADR-003)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_payment_confirm_ride(p_payment uuid, p_psp_id text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE pay payments%ROWTYPE; r rides%ROWTYPE; pct numeric; taxa numeric;
        comissao numeric; grp uuid; legs jsonb;
BEGIN
  SELECT * INTO pay FROM payments WHERE id = p_payment FOR UPDATE;
  IF NOT FOUND OR pay.status <> 'PENDING' THEN RETURN; END IF;   -- idempotent webhook
  SELECT * INTO r FROM rides WHERE id = pay.ride_id FOR UPDATE;
  UPDATE payments SET status = 'CONFIRMED', confirmed_at = now(), psp_payment_id = p_psp_id
   WHERE id = p_payment;
  UPDATE rides SET payment_status = 'CONFIRMED' WHERE id = r.id;
  grp := gen_random_uuid();
  IF pay.method = 'CASH' THEN
    IF r.pricing_mode_snapshot = 'COMISSAO' THEN
      pct   := (city_param(r.city_id,'PRM-comissao.pct','0.12') #>> '{}')::numeric;
      comissao := round(r.fare_total * pct, 2);
      -- ADR-003: commission in cash = partner DEBIT (debt repaid by next PIX/card rides)
      IF comissao > 0 THEN
        PERFORM fn_ledger_post(grp, jsonb_build_array(
          jsonb_build_object('owner_type','PARTNER','owner_user_id',r.partner_user_id,'kind','WALLET','dir','D','amount',comissao,'desc','commission cash','ride_id',r.id),
          jsonb_build_object('owner_type','PLATFORM','kind','REVENUE_COMMISSION','dir','C','amount',comissao,'desc','commission cash','ride_id',r.id)
        ), 'pay:' || p_payment);
      END IF;
    END IF;  -- PASSE + cash: no ledger legs (partner keeps all)
  ELSE
    pct   := (city_param(r.city_id,'PRM-comissao.pct','0.12') #>> '{}')::numeric;
    taxa  := (city_param(r.city_id,'PRM-taxa.comissao','0.00') #>> '{}')::numeric;
    IF r.pricing_mode_snapshot = 'PASSE' THEN
      PERFORM fn_ledger_post(grp, jsonb_build_array(
        jsonb_build_object('owner_type','PLATFORM','kind','PSP_CASH','dir','D','amount',r.fare_total,'desc','ride gross','ride_id',r.id),
        jsonb_build_object('owner_type','PARTNER','owner_user_id',r.partner_user_id,'kind','WALLET','dir','C','amount',r.fare_total,'desc','ride gross PASSE','ride_id',r.id)
      ), 'pay:' || p_payment);
    ELSE
      comissao := round(r.fare_total * pct, 2);
      legs := jsonb_build_array(
        jsonb_build_object('owner_type','PLATFORM','kind','PSP_CASH','dir','D','amount',r.fare_total,'desc','ride gross','ride_id',r.id),
        jsonb_build_object('owner_type','PARTNER','owner_user_id',r.partner_user_id,'kind','WALLET','dir','C','amount',r.fare_total - comissao - taxa,'desc','ride net COMISSAO','ride_id',r.id)
      );
      IF comissao > 0 THEN
        legs := legs || jsonb_build_array(
          jsonb_build_object('owner_type','PLATFORM','kind','REVENUE_COMMISSION','dir','C','amount',comissao,'desc','commission','ride_id',r.id));
      END IF;
      IF taxa > 0 THEN
        legs := legs || jsonb_build_array(
          jsonb_build_object('owner_type','PLATFORM','kind','REVENUE_FEES','dir','C','amount',taxa,'desc','per-ride fee','ride_id',r.id));
      END IF;
      PERFORM fn_ledger_post(grp, legs, 'pay:' || p_payment);
    END IF;
  END IF;
  PERFORM fn_emit_event(r.id, 'payment.confirmed', jsonb_build_object('method', pay.method), NULL, 'payevt:' || p_payment);
END $$;

-- -----------------------------------------------------------------------------
-- 7. RLS — deny by default (no policy == no access)
-- -----------------------------------------------------------------------------
ALTER TABLE users ENABLE ROW LEVEL SECURITY;
ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE device_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE cities ENABLE ROW LEVEL SECURITY;
ALTER TABLE service_types ENABLE ROW LEVEL SECURITY;
ALTER TABLE city_configs ENABLE ROW LEVEL SECURITY;
ALTER TABLE feature_flags ENABLE ROW LEVEL SECURITY;
ALTER TABLE partners ENABLE ROW LEVEL SECURITY;
ALTER TABLE partner_presence ENABLE ROW LEVEL SECURITY;
ALTER TABLE vehicles ENABLE ROW LEVEL SECURITY;
ALTER TABLE kyc_cases ENABLE ROW LEVEL SECURITY;
ALTER TABLE kyc_documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE rides ENABLE ROW LEVEL SECURITY;
ALTER TABLE deliveries ENABLE ROW LEVEL SECURITY;
ALTER TABLE delivery_photos ENABLE ROW LEVEL SECURITY;
ALTER TABLE negotiations ENABLE ROW LEVEL SECURITY;
ALTER TABLE offers ENABLE ROW LEVEL SECURITY;
ALTER TABLE ride_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE partner_positions ENABLE ROW LEVEL SECURITY;
ALTER TABLE payment_methods ENABLE ROW LEVEL SECURITY;
ALTER TABLE payments ENABLE ROW LEVEL SECURITY;
ALTER TABLE partner_passes ENABLE ROW LEVEL SECURITY;
ALTER TABLE ledger_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE ledger_entries ENABLE ROW LEVEL SECURITY;
ALTER TABLE blocks ENABLE ROW LEVEL SECURITY;
ALTER TABLE cancel_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE ratings ENABLE ROW LEVEL SECURITY;
ALTER TABLE tickets ENABLE ROW LEVEL SECURITY;
ALTER TABLE ticket_messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE notifications ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_log ENABLE ROW LEVEL SECURITY;

-- Identity
CREATE POLICY p_users_self ON users FOR SELECT USING (id = app_uid() OR app_is_agent());
CREATE POLICY p_profiles_self ON profiles FOR SELECT USING (true);  -- names needed for ratings; minimize columns app-side
CREATE POLICY p_profiles_upd ON profiles FOR UPDATE USING (user_id = app_uid());
CREATE POLICY p_sessions_self ON device_sessions FOR ALL USING (user_id = app_uid()) WITH CHECK (user_id = app_uid());
CREATE POLICY p_presence_own ON partner_presence FOR UPDATE USING (partner_user_id = app_uid());
CREATE POLICY p_presence_read ON partner_presence FOR SELECT USING (true);

-- Reference data
CREATE POLICY p_cities_read ON cities FOR SELECT USING (true);
CREATE POLICY p_services_read ON service_types FOR SELECT USING (true);
CREATE POLICY p_configs_read ON city_configs FOR SELECT USING (true);
CREATE POLICY p_flags_read ON feature_flags FOR SELECT USING (true);

-- Partner
CREATE POLICY p_partners_read ON partners FOR SELECT USING (true);
CREATE POLICY p_vehicles_own ON vehicles FOR ALL USING (partner_user_id = app_uid()) WITH CHECK (partner_user_id = app_uid());
CREATE POLICY p_kyc_cases_own ON kyc_cases FOR SELECT USING (partner_user_id = app_uid() OR app_is_agent());
CREATE POLICY p_kyc_cases_agent ON kyc_cases FOR UPDATE USING (app_is_agent());
CREATE POLICY p_kyc_docs_insert ON kyc_documents FOR INSERT WITH CHECK (
  EXISTS (SELECT 1 FROM kyc_cases WHERE id = case_id AND partner_user_id = app_uid()));
CREATE POLICY p_kyc_docs_read ON kyc_documents FOR SELECT USING (
  app_is_agent() OR EXISTS (SELECT 1 FROM kyc_cases WHERE id = case_id AND partner_user_id = app_uid()));

-- Marketplace (mutations only via domain functions => no INSERT/UPDATE policies)
CREATE POLICY p_rides_read ON rides FOR SELECT USING (
  passenger_user_id = app_uid() OR partner_user_id = app_uid() OR app_is_agent());
CREATE POLICY p_offers_read ON offers FOR SELECT USING (partner_user_id = app_uid() OR app_is_agent());
CREATE POLICY p_negot_read ON negotiations FOR SELECT USING (
  app_uid() IN (SELECT passenger_user_id FROM rides WHERE id = ride_id)
  OR app_uid() IN (SELECT partner_user_id FROM rides WHERE id = ride_id) OR app_is_agent());
CREATE POLICY p_events_read ON ride_events FOR SELECT USING (app_is_agent());
CREATE POLICY p_deliveries_read ON deliveries FOR SELECT USING (
  app_uid() IN (SELECT passenger_user_id FROM rides WHERE id = ride_id)
  OR app_uid() IN (SELECT partner_user_id FROM rides WHERE id = ride_id) OR app_is_agent());
CREATE POLICY p_dphotos_read ON delivery_photos FOR SELECT USING (
  app_uid() IN (SELECT passenger_user_id FROM rides r JOIN deliveries d ON d.ride_id = r.id WHERE d.ride_id = ride_id)
  OR app_uid() IN (SELECT partner_user_id FROM rides r JOIN deliveries d ON d.ride_id = r.id WHERE d.ride_id = ride_id)
  OR app_is_agent());

-- Geo: partner writes own position; passenger reads live position of own active ride
CREATE POLICY p_pos_insert ON partner_positions FOR INSERT WITH CHECK (partner_user_id = app_uid());
CREATE POLICY p_pos_read ON partner_positions FOR SELECT USING (
  app_is_agent() OR EXISTS (SELECT 1 FROM rides r
    WHERE r.partner_user_id = partner_user_id AND r.passenger_user_id = app_uid()
      AND r.status IN ('ACEITA','A_CAMINHO','CHEGOU','EM_VIAGEM')));

-- Money
CREATE POLICY p_pmethods_self ON payment_methods FOR ALL USING (user_id = app_uid()) WITH CHECK (user_id = app_uid());
CREATE POLICY p_payments_read ON payments FOR SELECT USING (
  payer_user_id = app_uid() OR app_is_agent()
  OR EXISTS (SELECT 1 FROM rides WHERE id = ride_id AND partner_user_id = app_uid()));
CREATE POLICY p_passes_own ON partner_passes FOR SELECT USING (partner_user_id = app_uid() OR app_is_agent());
CREATE POLICY p_accounts_read ON ledger_accounts FOR SELECT USING (
  (owner_type = 'PARTNER' AND owner_user_id = app_uid()) OR app_is_agent());
CREATE POLICY p_entries_read ON ledger_entries FOR SELECT USING (
  app_is_agent() OR EXISTS (SELECT 1 FROM ledger_accounts a
    WHERE a.id = account_id AND a.owner_type = 'PARTNER' AND a.owner_user_id = app_uid()));

-- Operations
CREATE POLICY p_blocks_own ON blocks FOR SELECT USING (user_id = app_uid() OR app_is_agent());
CREATE POLICY p_ratings_read ON ratings FOR SELECT USING (true);
CREATE POLICY p_ratings_insert ON ratings FOR INSERT WITH CHECK (
  rater_user_id = app_uid()
  AND EXISTS (SELECT 1 FROM rides WHERE id = ride_id AND status = 'FINALIZADA'
              AND (passenger_user_id = app_uid() OR partner_user_id = app_uid())));
CREATE POLICY p_tickets_self ON tickets FOR SELECT USING (user_id = app_uid() OR app_is_agent());
CREATE POLICY p_tickets_insert ON tickets FOR INSERT WITH CHECK (user_id = app_uid());
CREATE POLICY p_tmsg_self ON ticket_messages FOR SELECT USING (
  app_is_agent() OR EXISTS (SELECT 1 FROM tickets t WHERE t.id = ticket_id AND t.user_id = app_uid()));
CREATE POLICY p_tmsg_insert ON ticket_messages FOR INSERT WITH CHECK (
  author_user_id = app_uid()
  AND (app_is_agent() OR EXISTS (SELECT 1 FROM tickets t WHERE t.id = ticket_id AND t.user_id = app_uid())));
CREATE POLICY p_notif_self ON notifications FOR SELECT USING (user_id = app_uid());
CREATE POLICY p_notif_read ON notifications FOR UPDATE USING (user_id = app_uid());
CREATE POLICY p_audit_read ON audit_log FOR SELECT USING (app_is_agent());

-- -----------------------------------------------------------------------------
-- 8. Event catalog seed (ride.event.v1) — versioned contract for clients/BI
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS event_catalog (
  version smallint NOT NULL,
  event_type text NOT NULL,
  description text NOT NULL,
  payload_schema jsonb NOT NULL DEFAULT '{}'::jsonb,
  PRIMARY KEY (version, event_type)
);
INSERT INTO event_catalog(version, event_type, description, payload_schema) VALUES
 (1,'ride.created','Passenger requested a ride','{"proposed":"number?"}'),
 (1,'offer.sent','Offer sent to one partner','{"amount":"number"}'),
 (1,'offer.accepted','Partner accepted; mode snapshot taken','{"mode":"PASSE|COMISSAO","pass_id":"uuid?"}'),
 (1,'offer.expired','Offer timeout; reoffer','{}'),
 (1,'ride.aceita','Ride accepted state entered','{}'),
 (1,'ride.a_caminho','Partner driving to pickup','{}'),
 (1,'ride.chegou','Partner arrived at pickup','{}'),
 (1,'ride.em_viagem','Trip started','{}'),
 (1,'ride.finalizada','Trip finished with fare','{}'),
 (1,'ride.cancelled','Cancelled with reason + fault flag','{"side":"PASSENGER|PARTNER|SYSTEM|SUPPORT","reason":"string","fault":"boolean"}'),
 (1,'payment.confirmed','PSP confirmed payment','{"method":"PIX|CARD|CASH"}'),
 (1,'pass.purchased','Pass purchase created','{"pass_id":"uuid"}'),
 (1,'pass.activated','Pass started (first online)','{"pass_id":"uuid"}'),
 (1,'pass.expiring','Warning at 60/15/0 minutes','{"minutes_left":"number"}'),
 (1,'pass.expired','Pass ended server-side','{"pass_id":"uuid"}'),
 (1,'negotiation.proposed','Passenger proposed a price','{"amount":"number"}'),
 (1,'negotiation.countered','Partner countered','{"amount":"number"}'),
 (1,'kyc.decided','KYC decision','{"status":"AUTO_APPROVED|IN_REVIEW|REJECTED|RESUBMIT","reason":"string?"}'),
 (1,'ticket.opened','Support ticket opened','{"priority":"EMERGENCY|NORMAL"}'),
 (1,'block.applied','User blocked','{"kind":"CANCEL_ABUSE|KYC|SUPPORT|FRAUD|PAYMENT_DEBT","ends_at":"timestamptz?"}')
ON CONFLICT DO NOTHING;

-- -----------------------------------------------------------------------------
-- 13. Harden — funções de domínio são exclusivas do servidor (T-21/AV-1)
-- Postgres concede EXECUTE a PUBLIC por default: sem este bloco, qualquer
-- papel autenticado poderia chamar fn_ledger_post()/fn_*_transition()
-- diretamente (escalação de privilégio — achado da revisão adversarial).
-- Os helpers usados dentro de policies rodam como authenticated e por isso
-- recebem EXECUTE de volta (mínimo necessário).
-- -----------------------------------------------------------------------------
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC;
DO $$
BEGIN
  IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'anon') THEN
    EXECUTE 'REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM anon';
  END IF;
END $$;
GRANT EXECUTE ON FUNCTION app_uid(), app_role(), app_is_agent(), app_is_admin(),
                          city_param(uuid, text, jsonb)
  TO authenticated, service_role;

-- ...e devolve EXECUTE a service_role para TODAS as funções de domínio (fn_*):
-- sem isto as Edge Functions (service_role) ficariam sem permissão de chamá-las
-- (regressão pego pelo teste AV-1b da suíte 0005).
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT p.oid::regprocedure FROM pg_proc p
           JOIN pg_namespace ns ON ns.oid = p.pronamespace
           WHERE ns.nspname = 'public' AND p.prokind = 'f' AND p.proname LIKE 'fn\_%' LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role', r.oid::regprocedure);
  END LOOP;
END $$;
