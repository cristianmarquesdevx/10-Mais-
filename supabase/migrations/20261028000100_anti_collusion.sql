-- =============================================================================
-- 10 é + — anti-colusão e auditoria de preço muito abaixo da tarifa.
--
-- Implementa o que o SPECS §3 já determinava e o backend ainda não fazia:
--
--   * ANTI-COLUSÃO — par (passageiro, parceiro) com >= 3 corridas NEGOCIADAS
--     em 24 h não segue negociando: o aceite da oferta é recusado com
--     `pair_negotiation_blocked` e a tentativa entra no `audit_log`. O
--     despacho não é penalizado (o score continua neutro): a corrida apenas
--     segue para o próximo candidato, ou o passageiro usa a tarifa cheia.
--
--   * ANTI-DUMPING — preço (proposto ou final) abaixo de 50% da tarifa cotada
--     não é bloqueado, mas a corrida fica marcada para auditoria amostral:
--     `rides.audit_flag` + linha em `audit_log` + evento `ride.audit_flagged`.
--     Reincidência do MESMO par na janela escala o motivo para
--     `...+PAIR_RECIDIVE`, que é o que a operação revisa primeiro.
--
-- A referência de preço é SEMPRE a tarifa cotada pelo servidor no pedido
-- (`rides.pricing->>'fare_total'`), nunca a última proposta — senão cada
-- contraproposta reduziria a própria régua.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Flag de auditoria na própria corrida (consulta rápida da operação) e
--    parâmetros da regra em `city_configs`.
-- -----------------------------------------------------------------------------
ALTER TABLE rides
  ADD COLUMN IF NOT EXISTS audit_flag boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS audit_reason text,
  ADD COLUMN IF NOT EXISTS audit_flagged_at timestamptz;

CREATE INDEX IF NOT EXISTS idx_rides_audit
  ON rides (audit_flagged_at DESC) WHERE audit_flag;

CREATE OR REPLACE FUNCTION fn_city_defaults(p_city uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE p record;
BEGIN
  FOR p IN SELECT * FROM (VALUES
    ('PRM-preco.base',            '5.00'::jsonb),
    ('PRM-preco.km',              '2.20'::jsonb),
    ('PRM-preco.piso',            '8.00'::jsonb),
    ('PRM-preco.fator_via',       '1.35'::jsonb),
    ('PRM-preco.validade',        '90'::jsonb),
    ('PRM-demanda.janela_min',    '15'::jsonb),
    ('PRM-demanda.raio_m',        '1500'::jsonb),
    ('PRM-demanda.peso',          '0.07'::jsonb),
    ('PRM-demanda.teto',          '0.35'::jsonb),
    ('PRM-despacho.velocidade',        '22'::jsonb),
    ('PRM-despacho.velocidade_viagem', '30'::jsonb),
    ('PRM-despacho.eta_ref_min',       '15'::jsonb),
    ('PRM-despacho.ocioso_teto_s',     '1800'::jsonb),
    ('PRM-despacho.novato_corridas',   '500'::jsonb),
    ('PRM-despacho.notas_min',         '20'::jsonb),
    ('PRM-hb.tolerancia',              '90'::jsonb),
    ('PRM-match.retry_s',              '20'::jsonb),
    ('PRM-corrida.busca_max_s',        '600'::jsonb),
    ('PRM-pagamento.validade_s',       '900'::jsonb),
    ('PRM-neg.piso_fator',             '0.7'::jsonb),
    ('PRM-neg.teto_fator',             '3.0'::jsonb),
    ('PRM-neg.rounds',                 '3'::jsonb),
    ('PRM-neg.round_ttl',              '60'::jsonb),
    ('PRM-neg.max_h',                  '3'::jsonb),
    -- anti-colusão / anti-dumping (SPECS §3)
    ('PRM-anti.dumping.fator',         '0.5'::jsonb),  -- abaixo disto = auditoria
    ('PRM-anti.reincidencia',          '3'::jsonb),    -- corridas do par na janela
    ('PRM-anti.janela_h',              '24'::jsonb)
  ) AS t(k, v)
  LOOP
    INSERT INTO city_configs (city_id, param_key, param_value, valid_from)
    SELECT p_city, p.k, p.v, now() - interval '1 day'
    WHERE NOT EXISTS (
      SELECT 1 FROM city_configs cc
       WHERE cc.city_id = p_city AND cc.param_key = p.k);
  END LOOP;
END $$;

SELECT fn_city_defaults(c.id) FROM cities c;

-- -----------------------------------------------------------------------------
-- 2. Marcar a corrida para auditoria — um lugar só, idempotente.
--    Grava o flag na corrida, uma linha imutável em `audit_log` e o evento
--    `ride.audit_flagged` (reentrega não duplica: a chave é por regra+corrida).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_flag_ride_audit(
  p_ride uuid, p_reason text, p_payload jsonb DEFAULT '{}'::jsonb,
  p_actor uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  r rides%ROWTYPE; v_h int; v_limit int; v_pair int; v_reason text := p_reason;
BEGIN
  SELECT * INTO r FROM rides WHERE id = p_ride FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ride_not_found' USING ERRCODE = 'P0002';
  END IF;

  v_h     := (city_param(r.city_id,'PRM-anti.janela_h','24') #>> '{}')::int;
  v_limit := (city_param(r.city_id,'PRM-anti.reincidencia','3') #>> '{}')::int;

  -- Reincidência do MESMO par dentro da janela (sem contar esta corrida).
  SELECT count(*) INTO v_pair
    FROM rides x
   WHERE x.id <> p_ride
     AND x.audit_flag
     AND x.passenger_user_id = r.passenger_user_id
     AND x.partner_user_id IS NOT DISTINCT FROM r.partner_user_id
     AND x.audit_flagged_at > now() - make_interval(hours => v_h);
  IF r.partner_user_id IS NOT NULL AND v_pair + 1 >= v_limit THEN
    v_reason := p_reason || '+PAIR_RECIDIVE';
  END IF;

  -- Mesma regra já aplicada: não polui o log (o evento também é idempotente).
  IF r.audit_flag AND r.audit_reason IS NOT DISTINCT FROM v_reason THEN
    RETURN jsonb_build_object('audit_flag', true, 'reason', v_reason,
                              'pair_flags', v_pair + 1, 'duplicate', true);
  END IF;

  UPDATE rides
     SET audit_flag = true,
         audit_reason = v_reason,
         audit_flagged_at = COALESCE(audit_flagged_at, now())
   WHERE id = p_ride;

  INSERT INTO audit_log (actor_user_id, action, entity_type, entity_id, after_data)
  VALUES (p_actor, 'RIDE_AUDIT_FLAG', 'ride', p_ride::text,
          COALESCE(p_payload,'{}') || jsonb_build_object(
            'rule', p_reason, 'reason', v_reason, 'pair_flags', v_pair + 1,
            'window_h', v_h, 'limit', v_limit));

  PERFORM fn_emit_event(p_ride, 'ride.audit_flagged',
    COALESCE(p_payload,'{}') || jsonb_build_object(
      'rule', p_reason, 'reason', v_reason, 'pair_flags', v_pair + 1),
    p_actor, 'audit:' || p_reason || ':' || p_ride);

  RETURN jsonb_build_object('audit_flag', true, 'reason', v_reason,
                            'pair_flags', v_pair + 1);
END $$;

-- -----------------------------------------------------------------------------
-- 3. Anti-colusão: quantas corridas NEGOCIADAS este par já teve na janela.
--    Lido no aceite da oferta — é o primeiro momento em que o par é conhecido
--    (a negociação acontece antes de existir parceiro).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_pair_negotiation(p_offer uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  o offers%ROWTYPE; r rides%ROWTYPE; v_h int; v_limit int; v_n int;
BEGIN
  SELECT * INTO o FROM offers WHERE id = p_offer;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'offer_not_found' USING ERRCODE = 'P0002';
  END IF;
  SELECT * INTO r FROM rides WHERE id = o.ride_id;
  v_h     := (city_param(r.city_id,'PRM-anti.janela_h','24') #>> '{}')::int;
  v_limit := (city_param(r.city_id,'PRM-anti.reincidencia','3') #>> '{}')::int;

  SELECT count(DISTINCT x.id) INTO v_n
    FROM rides x
    JOIN negotiations n ON n.ride_id = x.id
   WHERE x.passenger_user_id = r.passenger_user_id
     AND x.partner_user_id = o.partner_user_id
     AND x.id <> r.id
     AND n.created_at > now() - make_interval(hours => v_h);

  RETURN jsonb_build_object(
    'ride_id', r.id,
    'partner_user_id', o.partner_user_id,
    'negotiated', r.proposed_amount IS NOT NULL,
    -- Só corrida NEGOCIADA entra na regra: tarifa cheia não é colusão.
    'blocked', r.proposed_amount IS NOT NULL AND v_n >= v_limit,
    'pair_rides', v_n, 'limit', v_limit, 'window_h', v_h);
END $$;

CREATE OR REPLACE FUNCTION api_pair_negotiation_status(p_offer uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_uid uuid := app_uid(); v_out jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated' USING ERRCODE = '28000';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM offers WHERE id = p_offer
                  AND partner_user_id = v_uid) THEN
    RAISE EXCEPTION 'offer_not_found' USING ERRCODE = 'P0002';
  END IF;
  v_out := fn_pair_negotiation(p_offer);
  RETURN v_out;
END $$;

-- Registra a tentativa bloqueada (a recusa em si é feita pela borda, para o
-- flag sobreviver — um RAISE desfaria a escrita na mesma transação).
CREATE OR REPLACE FUNCTION api_flag_pair_block(p_offer uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_uid uuid := app_uid(); v_st jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated' USING ERRCODE = '28000';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM offers WHERE id = p_offer
                  AND partner_user_id = v_uid) THEN
    RAISE EXCEPTION 'offer_not_found' USING ERRCODE = 'P0002';
  END IF;
  v_st := fn_pair_negotiation(p_offer);
  IF NOT (v_st->>'blocked')::boolean THEN
    RETURN v_st || jsonb_build_object('flagged', false);
  END IF;
  RETURN fn_flag_ride_audit((v_st->>'ride_id')::uuid, 'PAIR_NEGOTIATION_BLOCK',
    jsonb_build_object('partner_user_id', v_uid,
                       'pair_rides', (v_st->>'pair_rides')::int,
                       'window_h', (v_st->>'window_h')::int,
                       'limit', (v_st->>'limit')::int), v_uid)
         || jsonb_build_object('flagged', true, 'pair', v_st);
END $$;

-- -----------------------------------------------------------------------------
-- 4. Anti-dumping na proposta: preço muito abaixo da tarifa não é recusado
--    (o piso da cidade é quem manda), mas a corrida fica marcada.
--    Corpo igual ao da migração da negociação + o bloco de auditoria.
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
  v_offer_timeout int;
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

  v_rounds := (city_param(r.city_id,'PRM-neg.rounds','3') #>> '{}')::int;
  v_ttl    := (city_param(r.city_id,'PRM-neg.round_ttl','60') #>> '{}')::int;
  v_max_h  := (city_param(r.city_id,'PRM-neg.max_h','3') #>> '{}')::int;

  -- Limite por hora: corridas DIFERENTES com negociação aberta na última hora.
  SELECT count(DISTINCT n.ride_id) INTO v_open_rides
    FROM negotiations n JOIN rides rr ON rr.id = n.ride_id
   WHERE rr.passenger_user_id = p_actor
     AND n.ride_id <> p_ride
     AND n.created_at > now() - interval '1 hour';
  IF v_open_rides >= v_max_h THEN
    RAISE EXCEPTION 'rate_limited' USING ERRCODE = '22023';
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

  -- Anti-dumping (SPECS §3): preço muito abaixo da tarifa fica para revisão.
  v_dump := (city_param(r.city_id,'PRM-anti.dumping.fator','0.5') #>> '{}')::numeric;
  IF p_amount < v_tariff * v_dump THEN
    PERFORM fn_flag_ride_audit(p_ride, 'NEGOTIATED_BELOW_TARIFF',
      jsonb_build_object('proposed', p_amount, 'tariff', v_tariff,
                         'ratio', round(p_amount / v_tariff, 3),
                         'round_no', v_round), p_actor);
  END IF;

  -- A oferta viva passa a valer o novo valor (e ganha o timeout de novo): o
  -- parceiro vê a contraproposta no próximo poll, sem esperar a oferta morrer.
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

  RETURN jsonb_build_object(
    'negotiation_id', v_id, 'ride_id', p_ride, 'round_no', v_round,
    'amount', p_amount, 'kind', p_kind, 'status', 'OPEN',
    'expires_at', v_exp,
    'floor', v_floor, 'ceiling', v_ceiling,
    'rounds_left', GREATEST(0, v_rounds - v_round));
END $$;

-- -----------------------------------------------------------------------------
-- 5. Anti-dumping no preço final. Corpo igual ao da negociação (teto do preço
--    combinado + dinheiro declarado) + o bloco de auditoria.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api_ride_transition(
  p_ride uuid, p_to text, p_fare numeric DEFAULT NULL,
  p_cash_declared boolean DEFAULT false
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_uid uuid := app_uid(); v_pay uuid; r rides%ROWTYPE;
  v_tariff numeric; v_dump numeric; v_audit boolean := false;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated' USING ERRCODE = '28000';
  END IF;
  SELECT * INTO r FROM rides WHERE id = p_ride;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ride_not_found' USING ERRCODE = 'P0002';
  END IF;
  IF r.partner_user_id IS DISTINCT FROM v_uid THEN
    RAISE EXCEPTION 'not_your_ride' USING ERRCODE = '42501';
  END IF;

  IF p_to = 'FINALIZADA' THEN
    IF p_fare IS NULL OR p_fare <= 0 THEN
      RAISE EXCEPTION 'invalid_fare' USING ERRCODE = '22023';
    END IF;
    IF r.proposed_amount IS NOT NULL AND p_fare > r.proposed_amount + 0.005 THEN
      RAISE EXCEPTION 'above_agreed' USING ERRCODE = '22023';
    END IF;
    -- Tarifa de referência: a cotada no pedido (o `fare_total` vira o cobrado).
    v_tariff := COALESCE((r.pricing->>'fare_total')::numeric, 0);
    v_dump   := (city_param(r.city_id,'PRM-anti.dumping.fator','0.5') #>> '{}')::numeric;
    v_audit  := v_tariff > 0 AND p_fare < v_tariff * v_dump;

    PERFORM fn_ride_finish(p_ride, v_uid, p_fare);
    UPDATE partner_presence SET online_status = 'ONLINE_DISPONIVEL',
           idle_since = now(), updated_at = now()
     WHERE partner_user_id = v_uid;
    IF p_cash_declared THEN
      -- ADR-003: o parceiro recebeu em espécie; a comissão vira débito da
      -- carteira dele no MESMO caminho de ledger do PIX (nada de atalho).
      v_pay := api_ride_cash_declare(p_ride, p_fare);
    END IF;
    IF v_audit THEN
      PERFORM fn_flag_ride_audit(p_ride, 'FARE_BELOW_TARIFF',
        jsonb_build_object('declared', p_fare, 'tariff', v_tariff,
                           'ratio', round(p_fare / v_tariff, 3),
                           'method', CASE WHEN p_cash_declared THEN 'CASH' ELSE NULL END),
        v_uid);
    END IF;
  ELSE
    PERFORM fn_ride_transition(p_ride, v_uid, p_to);
  END IF;
  RETURN api_ride_get(p_ride);
END $$;

-- -----------------------------------------------------------------------------
-- 6. GRANTS — as duas funções novas são chamadas pela borda com o token do
--    parceiro (SECURITY DEFINER: o corpo não escolhe ator).
-- -----------------------------------------------------------------------------
GRANT EXECUTE ON FUNCTION api_pair_negotiation_status(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION api_flag_pair_block(uuid) TO authenticated;
