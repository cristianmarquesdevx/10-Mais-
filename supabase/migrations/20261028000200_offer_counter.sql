-- =============================================================================
-- 10 é + — contraproposta do PARCEIRO na oferta (D2, SPECS §3).
--
-- Até aqui só o passageiro negociava: a oferta chegava com um valor e o
-- parceiro só podia aceitar ou recusar. Agora ele contrapropõe de verdade:
--
--   * o valor é validado no SERVIDOR contra o mesmo piso/teto da cidade
--     (`PRM-neg.piso_fator` / `PRM-neg.teto_fator`) — a tela não decide nada;
--   * consome a MESMA rodada do passageiro: o limite (`PRM-neg.rounds`, 3) é
--     por corrida, não por lado, então ninguém ganha rodadas extras;
--   * contrapropor é PEDIR MAIS: valor menor ou igual ao proposto não é
--     contraproposta, é aceitar;
--   * a rodada fica aberta esperando o passageiro. Enquanto ela estiver
--     aberta, o próprio parceiro NÃO pode aceitar a oferta (seria aceitar o
--     próprio pedido) — `fn_offer_accept` recusa com `negotiation_pending`;
--   * quando o passageiro aceita (`api_negotiation_accept`), a rodada vira
--     ACCEPTED e a oferta ganha janela nova para o parceiro confirmar;
--   * o passageiro também pode contrapropor de novo: cada lado gasta rodada.
--
-- O histórico (`negotiations`) é o mesmo dos dois lados: cada linha diz quem
-- propôs. A tela do parceiro lê limites e rodadas restantes do servidor.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Limites e rodadas — uma conta só, usada por todas as bordas.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_neg_limits(p_ride uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  r rides%ROWTYPE; v_tariff numeric; v_used int; v_allowed int;
BEGIN
  SELECT * INTO r FROM rides WHERE id = p_ride;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ride_not_found' USING ERRCODE = 'P0002';
  END IF;
  v_tariff  := COALESCE((r.pricing->>'fare_total')::numeric, r.fare_total, 0);
  v_allowed := (city_param(r.city_id,'PRM-neg.rounds','3') #>> '{}')::int;
  SELECT COALESCE(MAX(round_no), 0) INTO v_used
    FROM negotiations WHERE ride_id = p_ride;
  RETURN jsonb_build_object(
    'tariff', v_tariff,
    'floor', round(v_tariff * (city_param(r.city_id,'PRM-neg.piso_fator','0.7') #>> '{}')::numeric, 2),
    'ceiling', round(v_tariff * (city_param(r.city_id,'PRM-neg.teto_fator','3.0') #>> '{}')::numeric, 2),
    'rounds_allowed', v_allowed,
    'rounds_used', v_used,
    'rounds_left', GREATEST(0, v_allowed - v_used),
    'proposed_amount', r.proposed_amount);
END $$;

-- -----------------------------------------------------------------------------
-- 2. Regra da rodada — agora com o parceiro como autor.
--    Corpo igual ao anterior (piso/teto, 3 rodadas, 3 corridas/h) + o ramo do
--    parceiro e a recusa de contraproposta que não sobe o valor.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_negotiate(
  p_ride uuid, p_actor uuid, p_amount numeric, p_kind text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  r rides%ROWTYPE; o offers%ROWTYPE;
  v_tariff numeric; v_floor numeric; v_ceiling numeric; v_dump numeric;
  v_rounds int; v_ttl int; v_max_h int;
  v_round int; v_open_rides int; v_id uuid; v_exp timestamptz;
  v_offer_timeout int; v_is_partner boolean := false;
BEGIN
  SELECT * INTO r FROM rides WHERE id = p_ride FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ride_not_found' USING ERRCODE = 'P0002';
  END IF;

  -- Quem fala: o passageiro dono da corrida ou o parceiro da oferta viva.
  IF r.passenger_user_id <> p_actor THEN
    SELECT * INTO o FROM offers
     WHERE ride_id = p_ride AND partner_user_id = p_actor AND status = 'SENT'
     ORDER BY sent_at DESC LIMIT 1;
    IF o.id IS NULL THEN
      RAISE EXCEPTION 'not_your_ride' USING ERRCODE = '42501';
    END IF;
    v_is_partner := true;
    -- O parceiro só contrapropõe; "propor" é do passageiro.
    IF p_kind <> 'COUNTER' THEN
      RAISE EXCEPTION 'invalid_request' USING ERRCODE = '22023';
    END IF;
  END IF;

  IF r.status NOT IN ('BUSCANDO', 'OFERTADA') THEN
    RAISE EXCEPTION 'ride_already_closed' USING ERRCODE = '40900';
  END IF;
  IF p_kind NOT IN ('PROPOSE', 'COUNTER') THEN
    RAISE EXCEPTION 'invalid_request' USING ERRCODE = '22023';
  END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'invalid_request' USING ERRCODE = '22023';
  END IF;

  -- A referência é a TARIFA cotada pelo servidor (não a última proposta, senão
  -- cada contraproposta encolheria o piso até o valor virar outro preço).
  v_tariff := COALESCE((r.pricing->>'fare_total')::numeric, r.fare_total, 0);
  IF v_tariff <= 0 THEN
    RAISE EXCEPTION 'invalid_fare' USING ERRCODE = '22023';
  END IF;
  v_floor   := round(v_tariff * (city_param(r.city_id,'PRM-neg.piso_fator','0.7') #>> '{}')::numeric, 2);
  v_ceiling := round(v_tariff * (city_param(r.city_id,'PRM-neg.teto_fator','3.0') #>> '{}')::numeric, 2);
  IF p_amount < v_floor THEN
    RAISE EXCEPTION 'below_floor' USING ERRCODE = '22023';
  END IF;
  IF p_amount > v_ceiling THEN
    RAISE EXCEPTION 'above_ceiling' USING ERRCODE = '22023';
  END IF;
  -- Contrapropor é pedir MAIS que o valor na mesa; pedir menos é aceitar.
  IF v_is_partner
     AND p_amount <= COALESCE(r.proposed_amount, 0) + 0.005 THEN
    RAISE EXCEPTION 'counter_not_higher' USING ERRCODE = '22023';
  END IF;

  v_rounds := (city_param(r.city_id,'PRM-neg.rounds','3') #>> '{}')::int;
  v_ttl    := (city_param(r.city_id,'PRM-neg.round_ttl','60') #>> '{}')::int;
  v_max_h  := (city_param(r.city_id,'PRM-neg.max_h','3') #>> '{}')::int;

  -- Limite por hora: só a ação do PASSAGEIRO conta (o parceiro contrapropor
  -- não pode consumir a cota do passageiro).
  IF NOT v_is_partner THEN
    SELECT count(DISTINCT n.ride_id) INTO v_open_rides
      FROM negotiations n JOIN rides rr ON rr.id = n.ride_id
     WHERE rr.passenger_user_id = p_actor
       AND n.ride_id <> p_ride
       AND n.created_at > now() - interval '1 hour';
    IF v_open_rides >= v_max_h THEN
      RAISE EXCEPTION 'rate_limited' USING ERRCODE = '22023';
    END IF;
  END IF;

  SELECT COALESCE(MAX(round_no), 0) + 1 INTO v_round
    FROM negotiations WHERE ride_id = p_ride;
  IF v_round > v_rounds THEN
    RAISE EXCEPTION 'round_limit' USING ERRCODE = '40900';
  END IF;

  UPDATE negotiations SET status = 'COUNTERED'
   WHERE ride_id = p_ride AND status = 'OPEN';

  v_exp := now() + make_interval(secs => v_ttl);
  INSERT INTO negotiations (ride_id, round_no, proposed_by_user_id, proposed_amount,
                            status, expires_at)
  VALUES (p_ride, v_round, p_actor, p_amount, 'OPEN', v_exp)
  RETURNING id INTO v_id;

  UPDATE rides SET proposed_amount = p_amount WHERE id = p_ride;

  IF v_is_partner THEN
    -- A oferta passa a mostrar o valor pedido (e ganha timeout novo): quem
    -- decide agora é o passageiro. O aceite do próprio pedido fica bloqueado
    -- em `fn_offer_accept` enquanto esta rodada estiver abre.
    v_offer_timeout := (city_param(r.city_id,'PRM-oferta.timeout','15') #>> '{}')::int;
    UPDATE offers
       SET offered_amount = p_amount,
           timeout_at = now() + make_interval(secs => v_offer_timeout)
     WHERE id = o.id;
    PERFORM fn_emit_event(p_ride, 'offer.countered',
      jsonb_build_object('amount', p_amount, 'round_no', v_round), p_actor,
      'neg:' || v_id);
  ELSE
    -- Anti-dumping (SPECS §3): preço muito abaixo da tarifa fica para revisão.
    v_dump := (city_param(r.city_id,'PRM-anti.dumping.fator','0.5') #>> '{}')::numeric;
    IF p_amount < v_tariff * v_dump THEN
      PERFORM fn_flag_ride_audit(p_ride, 'NEGOTIATED_BELOW_TARIFF',
        jsonb_build_object('proposed', p_amount, 'tariff', v_tariff,
                           'ratio', round(p_amount / v_tariff, 3),
                           'round_no', v_round), p_actor);
    END IF;

    -- A oferta viva passa a valer o novo valor (e ganha o timeout de novo).
    SELECT * INTO o FROM offers
     WHERE ride_id = p_ride AND status = 'SENT'
     ORDER BY sent_at DESC LIMIT 1;
    IF o.id IS NOT NULL THEN
      v_offer_timeout := (city_param(r.city_id,'PRM-oferta.timeout','15') #>> '{}')::int;
      UPDATE offers
         SET offered_amount = p_amount,
             timeout_at = now() + make_interval(secs => v_offer_timeout)
       WHERE id = o.id;
      PERFORM fn_emit_event(p_ride, 'offer.amount_updated',
        jsonb_build_object('amount', p_amount, 'round_no', v_round), p_actor,
        'neg:' || v_id);
    ELSE
      PERFORM fn_dispatch_next(p_ride);
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'negotiation_id', v_id, 'ride_id', p_ride, 'round_no', v_round,
    'amount', p_amount, 'kind', p_kind, 'status', 'OPEN',
    'expires_at', v_exp, 'by_partner', v_is_partner,
    'floor', v_floor, 'ceiling', v_ceiling,
    'rounds_left', GREATEST(0, v_rounds - v_round));
END $$;

-- -----------------------------------------------------------------------------
-- 3. O passageiro aceita o preço pedido pelo parceiro.
--    Só vale a rodada ABERTA de maior número e ainda dentro do prazo do
--    servidor. Aceitar renova a janela da oferta para o parceiro confirmar.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_negotiation_accept(p_ride uuid, p_actor uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  r rides%ROWTYPE; n negotiations%ROWTYPE; v_offer_timeout int;
BEGIN
  SELECT * INTO r FROM rides WHERE id = p_ride FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ride_not_found' USING ERRCODE = 'P0002';
  END IF;
  IF r.passenger_user_id <> p_actor THEN
    RAISE EXCEPTION 'not_your_ride' USING ERRCODE = '42501';
  END IF;
  IF r.status NOT IN ('BUSCANDO', 'OFERTADA') THEN
    RAISE EXCEPTION 'ride_already_closed' USING ERRCODE = '40900';
  END IF;

  SELECT * INTO n FROM negotiations
   WHERE ride_id = p_ride AND status = 'OPEN'
     AND proposed_by_user_id <> p_actor
   ORDER BY round_no DESC LIMIT 1;
  IF n.id IS NULL THEN
    RAISE EXCEPTION 'no_pending_counter' USING ERRCODE = '40900';
  END IF;
  IF n.expires_at < now() THEN
    UPDATE negotiations SET status = 'EXPIRED' WHERE id = n.id;
    RAISE EXCEPTION 'counter_expired' USING ERRCODE = '40900';
  END IF;

  UPDATE negotiations SET status = 'ACCEPTED' WHERE id = n.id;
  UPDATE rides SET proposed_amount = n.proposed_amount WHERE id = p_ride;
  v_offer_timeout := (city_param(r.city_id,'PRM-oferta.timeout','15') #>> '{}')::int;
  UPDATE offers
     SET offered_amount = n.proposed_amount,
         timeout_at = now() + make_interval(secs => v_offer_timeout)
   WHERE ride_id = p_ride AND status = 'SENT';
  PERFORM fn_emit_event(p_ride, 'negotiation.accepted',
    jsonb_build_object('amount', n.proposed_amount, 'round_no', n.round_no),
    p_actor, 'negaccept:' || n.id);

  RETURN fn_neg_limits(p_ride) || jsonb_build_object(
    'negotiation_id', n.id, 'accepted_amount', n.proposed_amount,
    'round_no', n.round_no);
END $$;

-- -----------------------------------------------------------------------------
-- 4. Aceite da oferta: o parceiro não aceita a PRÓPRIA contraproposta.
--    Corpo igual ao anterior + a guarda da rodada aberta do parceiro.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_offer_accept(p_offer uuid, p_partner uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE o offers%ROWTYPE; v_pass_id uuid; mode text;
BEGIN
  SELECT * INTO o FROM offers WHERE id = p_offer FOR UPDATE;
  IF NOT FOUND OR o.partner_user_id <> p_partner OR o.status <> 'SENT' THEN
    RAISE EXCEPTION 'offer_unavailable';
  END IF;
  IF now() > o.timeout_at THEN RAISE EXCEPTION 'offer_unavailable'; END IF;
  PERFORM 1 FROM rides WHERE id = o.ride_id AND status = 'OFERTADA' FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'ride_not_offered'; END IF;
  -- Contraproposta aberta do próprio parceiro: o preço ainda não foi aceito
  -- pelo passageiro, então aceitar agora seria fechar no próprio pedido.
  IF EXISTS (SELECT 1 FROM negotiations n
              WHERE n.ride_id = o.ride_id AND n.status = 'OPEN'
                AND n.proposed_by_user_id = p_partner) THEN
    RAISE EXCEPTION 'negotiation_pending' USING ERRCODE = '40900';
  END IF;
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

-- -----------------------------------------------------------------------------
-- 5. Bordas: parceiro contrapropõe, lê limites e passageiro aceita.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api_offer_counter(p_offer uuid, p_amount numeric)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_uid uuid := app_uid(); o offers%ROWTYPE; v_out jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated' USING ERRCODE = '28000';
  END IF;
  SELECT * INTO o FROM offers WHERE id = p_offer;
  IF NOT FOUND OR o.partner_user_id <> v_uid THEN
    RAISE EXCEPTION 'offer_not_found' USING ERRCODE = 'P0002';
  END IF;
  IF o.status <> 'SENT' OR now() > o.timeout_at THEN
    RAISE EXCEPTION 'offer_unavailable' USING ERRCODE = '40900';
  END IF;
  v_out := fn_negotiate(o.ride_id, v_uid, p_amount, 'COUNTER');
  RETURN v_out || fn_neg_limits(o.ride_id);
END $$;

CREATE OR REPLACE FUNCTION api_offer_negotiation(p_offer uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_uid uuid := app_uid(); o offers%ROWTYPE; v_rounds jsonb; v_pending numeric;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated' USING ERRCODE = '28000';
  END IF;
  SELECT * INTO o FROM offers WHERE id = p_offer;
  IF NOT FOUND OR o.partner_user_id <> v_uid THEN
    RAISE EXCEPTION 'offer_not_found' USING ERRCODE = 'P0002';
  END IF;
  PERFORM fn_negotiation_tick();
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'round_no', n.round_no,
           'amount', n.proposed_amount,
           'by_me', n.proposed_by_user_id = v_uid,
           'status', CASE WHEN n.status = 'OPEN' AND n.expires_at < now()
                          THEN 'EXPIRED' ELSE n.status END,
           'expires_at', n.expires_at) ORDER BY n.round_no), '[]'::jsonb)
    INTO v_rounds
    FROM negotiations n WHERE n.ride_id = o.ride_id;
  SELECT n.proposed_amount INTO v_pending
    FROM negotiations n
   WHERE n.ride_id = o.ride_id AND n.status = 'OPEN'
     AND n.proposed_by_user_id = v_uid
   ORDER BY n.round_no DESC LIMIT 1;
  RETURN fn_neg_limits(o.ride_id) || jsonb_build_object(
    'offer_id', o.id, 'ride_id', o.ride_id,
    'amount_on_table', o.offered_amount,
    'pending_counter', v_pending,
    'rounds', v_rounds);
END $$;

CREATE OR REPLACE FUNCTION api_negotiation_accept(p_ride uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_uid uuid := app_uid();
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated' USING ERRCODE = '28000';
  END IF;
  RETURN fn_negotiation_accept(p_ride, v_uid);
END $$;

-- -----------------------------------------------------------------------------
-- 6. Histórico do passageiro ganha o que ele precisa para decidir: se há
--    contraproposta do parceiro esperando resposta.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api_ride_negotiations(p_ride uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  r rides%ROWTYPE; v_uid uuid := app_uid(); v_out jsonb; v_pending jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated' USING ERRCODE = '28000';
  END IF;
  PERFORM fn_negotiation_tick();
  SELECT * INTO r FROM rides WHERE id = p_ride;
  IF NOT FOUND
     OR (r.passenger_user_id <> v_uid AND r.partner_user_id IS DISTINCT FROM v_uid
         AND NOT app_is_agent()) THEN
    RAISE EXCEPTION 'ride_not_found' USING ERRCODE = 'P0002';
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'round_no', n.round_no,
           'amount', n.proposed_amount,
           'by_me', n.proposed_by_user_id = v_uid,
           'status', CASE WHEN n.status = 'OPEN' AND n.expires_at < now()
                          THEN 'EXPIRED' ELSE n.status END,
           'created_at', n.created_at,
           'expires_at', n.expires_at) ORDER BY n.round_no), '[]'::jsonb)
    INTO v_out
    FROM negotiations n WHERE n.ride_id = p_ride;

  -- Rodada aberta do OUTRO lado: é o que o passageiro precisa aceitar.
  SELECT jsonb_build_object('amount', n.proposed_amount, 'expires_at', n.expires_at,
                            'round_no', n.round_no)
    INTO v_pending
    FROM negotiations n
   WHERE n.ride_id = p_ride AND n.status = 'OPEN'
     AND n.proposed_by_user_id <> v_uid
   ORDER BY n.round_no DESC LIMIT 1;

  RETURN fn_neg_limits(p_ride) || jsonb_build_object(
    'ride_id', p_ride,
    'pending_counter', v_pending,
    'rounds', v_out);
END $$;

-- -----------------------------------------------------------------------------
-- 7. GRANTS — as três bordas novas rodam com o token do app.
-- -----------------------------------------------------------------------------
GRANT EXECUTE ON FUNCTION api_offer_counter(uuid, numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION api_offer_negotiation(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION api_negotiation_accept(uuid) TO authenticated;
