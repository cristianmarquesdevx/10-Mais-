-- -----------------------------------------------------------------------------
-- A3: renovação de passe entra na FILA atrás do passe que está valendo.
--
-- `fn_pass_confirm` marcava todo pagamento confirmado como SCHEDULED. Com um
-- passe já ACTIVE isso contrariava a regra A3 e, no primeiro ONLINE, o
-- `fn_partner_online` tentava ativar o segundo passe e batia no índice único
-- `uq_pass_active_per_partner` (um ACTIVE por parceiro).
--
-- Agora a confirmação decide o destino do passe:
--   sem passe na frente -> SCHEDULED (ativa no 1º online, A2)
--   com passe na frente  -> QUEUED + queue_after_pass_id (FIFO, A3)
-- "na frente" = valendo agora ou já esperando o primeiro online. Assim nunca
-- existe mais de um passe SCHEDULED por parceiro.
-- Quem promove a fila continua sendo `fn_pass_tick`, no relógio do servidor.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_pass_confirm(p_payment uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE p partner_passes%ROWTYPE; ativo uuid;
BEGIN
  SELECT * INTO p FROM partner_passes WHERE payment_id = p_payment FOR UPDATE;
  IF NOT FOUND OR p.status <> 'PENDING_PAYMENT' THEN RETURN; END IF;  -- webhook reentregue
  -- Quem já está na frente do comprador: o passe valendo ou, se não há, o que
  -- espera o primeiro online. Com alguém na frente, a renovação entra na fila.
  SELECT id INTO ativo FROM partner_passes
   WHERE partner_user_id = p.partner_user_id
     AND (status IN ('SCHEDULED', 'QUEUED')
          OR (status = 'ACTIVE' AND now() < expires_at))
   ORDER BY (status = 'ACTIVE') DESC, created_at
   LIMIT 1;
  UPDATE partner_passes
     SET status = CASE WHEN ativo IS NULL THEN 'SCHEDULED' ELSE 'QUEUED' END,
         queue_after_pass_id = ativo
   WHERE id = p.id;
  PERFORM fn_ledger_post(gen_random_uuid(),
    jsonb_build_array(
      jsonb_build_object('owner_type','PLATFORM','kind','PSP_CASH','dir','D','amount',p.price_paid,'desc','pass purchase'),
      jsonb_build_object('owner_type','PLATFORM','kind','REVENUE_PASSES','dir','C','amount',p.price_paid,'desc','pass revenue')
    ), 'pass:' || p.id);
END $$;

-- -----------------------------------------------------------------------------
-- A2 + A3 no mesmo lugar: ao ficar ONLINE o relógio do servidor roda primeiro
-- (expira o vencido e promove a fila) e só então um passe SCHEDULED ativa —
-- nunca dois ACTIVE ao mesmo tempo.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_partner_online(p_partner uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE p partner_passes%ROWTYPE; dur int;
BEGIN
  UPDATE partner_presence SET online_status = 'ONLINE_DISPONIVEL', last_heartbeat_at = now()
   WHERE partner_user_id = p_partner;

  PERFORM fn_pass_tick(p_partner);   -- expira vencido e promove a fila FIFO

  SELECT * INTO p FROM partner_passes
   WHERE partner_user_id = p_partner AND status = 'SCHEDULED' FOR UPDATE;
  -- A2: o agendado só ativa se a vaga estiver livre (o índice único manda).
  IF FOUND AND NOT EXISTS (SELECT 1 FROM partner_passes
                            WHERE partner_user_id = p_partner AND status = 'ACTIVE') THEN
    dur := p.duration_minutes;
    UPDATE partner_passes SET status = 'ACTIVE', activated_at = now(),
           starts_at = now(), expires_at = now() + make_interval(mins => dur),
           queue_after_pass_id = NULL
     WHERE id = p.id;
    PERFORM fn_emit_event(NULL, 'pass.activated', jsonb_build_object('pass_id', p.id), p_partner, 'pass-on:' || p.id);
  END IF;

  UPDATE partners SET monetization_mode =
    CASE WHEN EXISTS (SELECT 1 FROM partner_passes
                       WHERE partner_user_id = p_partner AND status='ACTIVE' AND now() < expires_at)
         THEN 'PASSE_ATIVO' ELSE 'COMISSAO' END
   WHERE user_id = p_partner;
END $$;

-- -----------------------------------------------------------------------------
-- Plano de contas da plataforma.
--
-- O ledger não inventa conta: `fn_ledger_post` recusa lançar em conta que não
-- existe. `fn_pass_confirm` lança em PLATFORM/PSP_CASH e PLATFORM/
-- REVENUE_PASSES, então a primeira compra de passe morria com "ledger account
-- missing". As contas são do produto (não do teste), por isso nascem aqui.
--
-- O índice único não cobre `owner_user_id NULL`, então a idempotência é pelo
-- NOT EXISTS em vez de ON CONFLICT.
-- -----------------------------------------------------------------------------
INSERT INTO ledger_accounts (owner_type, owner_user_id, kind)
SELECT 'PLATFORM', NULL, k
FROM (VALUES ('PSP_CASH'), ('REVENUE_PASSES'), ('REVENUE_COMMISSION'),
             ('REVENUE_FEES'), ('REFUNDS'), ('RECEIVABLE_CASH')) AS t(k)
WHERE NOT EXISTS (
  SELECT 1 FROM ledger_accounts a
   WHERE a.owner_type = 'PLATFORM' AND a.owner_user_id IS NULL AND a.kind = t.k);
