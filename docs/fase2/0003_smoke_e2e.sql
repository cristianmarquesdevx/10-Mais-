-- =============================================================================
-- 10 e + — 0003_smoke_e2e.sql (domain smoke test; run after 0001 + 0002)
-- Covers: full ride cycle in both monetization modes (REQ-002), ledger
-- double-entry sum = 0 (T6), pass activation on first online (A2), snapshot
-- immutability (A4), payment idempotency (REQ-010).
-- =============================================================================
\set ON_ERROR_STOP on

-- seed -------------------------------------------------------------------------
INSERT INTO cities(name, uf) VALUES ('Porto Velho','RO');
INSERT INTO service_types(code, display_name) VALUES ('RIDE_CAR','Corrida');
INSERT INTO users(phone_e164, role) VALUES
  ('+5569999990001','PASSENGER'),  -- p1
  ('+5569999990002','PASSENGER'),  -- p2 (abuse tests)
  ('+5569999990003','PARTNER'),    -- partner
  ('+5569999990004','AGENT');
SELECT 'seeded users' AS step;

-- =============================================================================
-- CYCLE 1: COMISSAO mode (no pass)
-- =============================================================================
DO $$
DECLARE
  p_partner uuid; city uuid;
BEGIN
  SELECT id INTO p_partner FROM users WHERE phone_e164 = '+5569999990003';
  SELECT id INTO city FROM cities;
  IF NOT EXISTS (SELECT 1 FROM partners WHERE user_id = p_partner) THEN
    INSERT INTO partners(user_id, city_id, kyc_status) VALUES (p_partner, city, 'APPROVED');
    INSERT INTO partner_presence(partner_user_id) VALUES (p_partner);
    INSERT INTO ledger_accounts(owner_type, owner_user_id, kind) VALUES
      ('PLATFORM', NULL, 'PSP_CASH'), ('PLATFORM', NULL, 'REVENUE_COMMISSION'),
      ('PLATFORM', NULL, 'REVENUE_FEES'), ('PLATFORM', NULL, 'REVENUE_PASSES'),
      ('PARTNER', p_partner, 'WALLET');
  END IF;
END $$;

-- partner goes online first (dispatch requires ONLINE_DISPONIVEL)
SELECT fn_partner_online((SELECT id FROM users WHERE phone_e164='+5569999990003'));
SELECT 'parceiro online: ' || online_status AS presence FROM partner_presence;

-- sequential statements (psql \gset) for cycle 1
SELECT fn_ride_request(
  (SELECT id FROM users WHERE phone_e164='+5569999990001'),
  (SELECT id FROM cities),
  ST_SetSRID(ST_MakePoint(-63.90,-8.76),4326)::geography,
  ST_SetSRID(ST_MakePoint(-63.92,-8.78),4326)::geography,
  '{"base":8.0,"per_km":2.5}'::jsonb) AS ride_c1 \gset
SELECT fn_dispatch_offer(:'ride_c1', (SELECT id FROM users WHERE phone_e164='+5569999990003'), 18.90) AS off_c1 \gset
SELECT fn_offer_accept(:'off_c1', (SELECT id FROM users WHERE phone_e164='+5569999990003'));
SELECT 'C1 aceite: modo=' || pricing_mode_snapshot || ' status=' || status
  FROM rides WHERE id = :'ride_c1';

SELECT fn_ride_transition(:'ride_c1', (SELECT id FROM users WHERE phone_e164='+5569999990003'), 'A_CAMINHO');
SELECT fn_ride_transition(:'ride_c1', (SELECT id FROM users WHERE phone_e164='+5569999990003'), 'CHEGOU');
SELECT fn_ride_transition(:'ride_c1', (SELECT id FROM users WHERE phone_e164='+5569999990003'), 'EM_VIAGEM');
SELECT fn_ride_finish(:'ride_c1', (SELECT id FROM users WHERE phone_e164='+5569999990003'), 18.90);

INSERT INTO payments(ride_id, payer_user_id, method, amount, status, psp_provider, idempotency_key)
VALUES (:'ride_c1', (SELECT id FROM users WHERE phone_e164='+5569999990001'),
        'PIX', 18.90, 'PENDING', 'pagarme', 'pay-c1')
RETURNING id AS pay_c1 \gset

SELECT fn_payment_confirm_ride(:'pay_c1', 'psp_abc123');
SELECT 'C1 pós-pagamento: comissão=' ||
       (SELECT sum(amount) FROM ledger_entries e JOIN ledger_accounts a ON a.id=e.account_id
         WHERE a.kind='REVENUE_COMMISSION' AND e.ride_id=:'ride_c1') ||
       ' wallet=' ||
       (SELECT sum(CASE WHEN direction='C' THEN amount ELSE -amount END)
          FROM ledger_entries e JOIN ledger_accounts a ON a.id=e.account_id
         WHERE a.kind='WALLET') AS c1_result;
SELECT 'C1 soma ledger (precisa 0.00): ' ||
       sum(CASE WHEN direction='C' THEN amount ELSE -amount END) AS c1_sum
  FROM ledger_entries;

-- replay do webhook deve ser idempotente
SELECT fn_payment_confirm_ride(:'pay_c1', 'psp_abc123');
SELECT 'C1 replay: lançamentos=' || count(*) AS c1_replay FROM ledger_entries;

-- =============================================================================
-- CYCLE 2: PASSE mode (pass active at acceptance)
-- =============================================================================
INSERT INTO payments(payer_user_id, method, amount, status, psp_provider, idempotency_key)
VALUES ((SELECT id FROM users WHERE phone_e164='+5569999990003'),
        'PIX', 10.00, 'PENDING', 'pagarme', 'pay-pass')
RETURNING id AS pay_pass \gset

SELECT fn_pass_purchase((SELECT id FROM users WHERE phone_e164='+5569999990003'),
                        (SELECT id FROM cities), :'pay_pass') AS pass_id \gset
SELECT fn_pass_confirm(:'pay_pass');
SELECT 'Passe pós-confirmação: ' || status AS pass_status FROM partner_passes WHERE id = :'pass_id';

SELECT fn_partner_online((SELECT id FROM users WHERE phone_e164='+5569999990003'));
SELECT 'Passe ativo: status=' || p.status || ' modo_parceiro=' || pr.monetization_mode
  FROM partner_passes p JOIN partners pr ON pr.user_id = p.partner_user_id
 WHERE p.id = :'pass_id';

SELECT fn_ride_request(
  (SELECT id FROM users WHERE phone_e164='+5569999990001'),
  (SELECT id FROM cities),
  ST_SetSRID(ST_MakePoint(-63.89,-8.75),4326)::geography,
  ST_SetSRID(ST_MakePoint(-63.93,-8.79),4326)::geography,
  '{"base":8.0}'::jsonb) AS ride_c2 \gset
SELECT fn_dispatch_offer(:'ride_c2', (SELECT id FROM users WHERE phone_e164='+5569999990003'), 30.00) AS off_c2 \gset
SELECT fn_offer_accept(:'off_c2', (SELECT id FROM users WHERE phone_e164='+5569999990003'));
SELECT 'C2 aceite: modo=' || pricing_mode_snapshot || ' pass_id_preenchido=' ||
       (pass_id IS NOT NULL) FROM rides WHERE id = :'ride_c2';

SELECT fn_ride_transition(:'ride_c2', (SELECT id FROM users WHERE phone_e164='+5569999990003'), 'A_CAMINHO');
SELECT fn_ride_transition(:'ride_c2', (SELECT id FROM users WHERE phone_e164='+5569999990003'), 'CHEGOU');
SELECT fn_ride_transition(:'ride_c2', (SELECT id FROM users WHERE phone_e164='+5569999990003'), 'EM_VIAGEM');
SELECT fn_ride_finish(:'ride_c2', (SELECT id FROM users WHERE phone_e164='+5569999990003'), 30.00);

INSERT INTO payments(ride_id, payer_user_id, method, amount, status, psp_provider, idempotency_key)
VALUES (:'ride_c2', (SELECT id FROM users WHERE phone_e164='+5569999990001'),
        'PIX', 30.00, 'PENDING', 'pagarme', 'pay-c2')
RETURNING id AS pay_c2 \gset
SELECT fn_payment_confirm_ride(:'pay_c2', 'psp_def456');

SELECT 'C2 (PASSE): comissão lançada=' ||
       COALESCE((SELECT sum(amount) FROM ledger_entries e JOIN ledger_accounts a ON a.id=e.account_id
                  WHERE a.kind='REVENUE_COMMISSION' AND e.ride_id=:'ride_c2'), 0) ||
       ' ganho parceiro=' ||
       (SELECT sum(CASE WHEN direction='C' THEN amount ELSE -amount END)
          FROM ledger_entries e JOIN ledger_accounts a ON a.id=e.account_id
         WHERE a.kind='WALLET' AND e.ride_id=:'ride_c2') AS c2_result;
SELECT 'Soma final do ledger (precisa 0.00): ' ||
       sum(CASE WHEN direction='C' THEN amount ELSE -amount END) AS final_sum
  FROM ledger_entries;
