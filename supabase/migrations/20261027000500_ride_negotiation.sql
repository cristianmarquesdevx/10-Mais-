-- =============================================================================
-- 10 é + — negociação de preço (D2) no backend real.
--
-- A demo aceitava qualquer valor acima de R$ 15 fixos e não guardava nada: não
-- havia rodada, teto, limite por hora nem histórico. Aqui a regra é a do
-- SPECS §3, e ela vive no banco — a tela não decide preço aceitável:
--
--   * piso = 0.7 × tarifa e teto = 3 × tarifa (parâmetros da cidade);
--   * no máximo 3 rodadas por corrida, cada uma válida por 60 s;
--   * no máximo 3 corridas com negociação aberta por passageiro em 1 h;
--   * toda proposta vira linha em `negotiations` (histórico auditável), e a
--     oferta viva passa a valer o novo valor — o parceiro não espera timeout;
--   * o preço combinado é um TETO para a finalização: o parceiro pode cobrar
--     menos, nunca mais.
--
-- Quem negocia é o passageiro dono da corrida (é o único lado com essa tela);
-- o parceiro responde aceitando ou recusando a oferta, que já carrega o valor.
-- =============================================================================

-- Parâmetros novos (a função de defaults é a fonte: toda cidade nova nasce
-- com eles, e o SELECT abaixo cobre as que já existem).
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
    ('PRM-despacho.velocidade',        '22'::jsonb),  -- km/h até o embarque
    ('PRM-despacho.velocidade_viagem', '30'::jsonb),  -- km/h do trecho (igual ao app)
    ('PRM-despacho.eta_ref_min',       '15'::jsonb),
    ('PRM-despacho.ocioso_teto_s',     '1800'::jsonb),
    ('PRM-despacho.novato_corridas',   '500'::jsonb),
    ('PRM-despacho.notas_min',         '20'::jsonb),
    ('PRM-hb.tolerancia',              '90'::jsonb),  -- heartbeat fresco
    ('PRM-match.retry_s',              '20'::jsonb),  -- espera antes de reofertar
    ('PRM-corrida.busca_max_s',        '600'::jsonb), -- BUSCANDO sem aceite expira
    ('PRM-pagamento.validade_s',       '900'::jsonb),
    -- negociação (D2): piso/teto sobre a tarifa cotada, 3 rodadas de 60 s
    ('PRM-neg.piso_fator',             '0.7'::jsonb),
    ('PRM-neg.teto_fator',             '3.0'::jsonb),
    ('PRM-neg.rounds',                 '3'::jsonb),
    ('PRM-neg.round_ttl',              '60'::jsonb),
    ('PRM-neg.max_h',                  '3'::jsonb)
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

CREATE INDEX IF NOT EXISTS idx_negotiations_open
  ON negotiations (ride_id) WHERE status = 'OPEN';

-- -----------------------------------------------------------------------------
-- Regra da rodada. Devolve a proposta aceita com os limites que o servidor
-- aplicou (a tela mostra os mesmos números que valeram).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_negotiate(
  p_ride uuid, p_actor uuid, p_amount numeric, p_kind text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  r rides%ROWTYPE; o offers%ROWTYPE;
  v_tariff numeric; v_floor numeric; v_ceiling numeric;
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
    RAISE EXCEPTION 'invalid_amount' USING ERRCODE = '22023';
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
  -- Contar por corrida (não por rodada) impede abrir negociação em série sem
  -- punir quem está apenas contrapropondo dentro da mesma corrida.
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
    PERFORM fn_dispatch_next(p_ride);   -- sem oferta viva: procura parceiro já com o novo valor
  END IF;

  RETURN jsonb_build_object(
    'negotiation_id', v_id, 'ride_id', p_ride, 'round_no', v_round,
    'amount', p_amount, 'kind', p_kind, 'status', 'OPEN',
    'expires_at', v_exp,
    'floor', v_floor, 'ceiling', v_ceiling,
    'rounds_left', GREATEST(0, v_rounds - v_round));
END $$;

-- -----------------------------------------------------------------------------
-- Borda: o passageiro do token.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api_ride_negotiate(
  p_ride uuid, p_amount numeric, p_kind text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_uid uuid := app_uid();
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated' USING ERRCODE = '28000';
  END IF;
  RETURN fn_negotiate(p_ride, v_uid, p_amount, p_kind);
END $$;

-- -----------------------------------------------------------------------------
-- Histórico das rodadas — só participante da corrida.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api_ride_negotiations(p_ride uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  r rides%ROWTYPE; v_uid uuid := app_uid();
  v_tariff numeric; v_rounds int; v_out jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated' USING ERRCODE = '28000';
  END IF;
  PERFORM fn_negotiation_tick();   -- relógio do servidor antes de ler o histórico
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

  v_tariff := COALESCE((r.pricing->>'fare_total')::numeric, r.fare_total, 0);
  v_rounds := (city_param(r.city_id,'PRM-neg.rounds','3') #>> '{}')::int;

  RETURN jsonb_build_object(
    'ride_id', p_ride,
    'tariff', v_tariff,
    'floor', round(v_tariff * (city_param(r.city_id,'PRM-neg.piso_fator','0.7') #>> '{}')::numeric, 2),
    'ceiling', round(v_tariff * (city_param(r.city_id,'PRM-neg.teto_fator','3.0') #>> '{}')::numeric, 2),
    'rounds_allowed', v_rounds,
    'rounds_used', jsonb_array_length(v_out),
    'proposed_amount', r.proposed_amount,
    'rounds', v_out);
END $$;

-- -----------------------------------------------------------------------------
-- O preço combinado é um TETO ao finalizar: cobrar mais do que o passageiro
-- aceitou seria justamente o que a negociação existe para impedir.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api_ride_transition(
  p_ride uuid, p_to text, p_fare numeric DEFAULT NULL,
  p_cash_declared boolean DEFAULT false
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_uid uuid := app_uid(); v_pay uuid; r rides%ROWTYPE;
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
    PERFORM fn_ride_finish(p_ride, v_uid, p_fare);
    UPDATE partner_presence SET online_status = 'ONLINE_DISPONIVEL',
           idle_since = now(), updated_at = now()
     WHERE partner_user_id = v_uid;
    IF p_cash_declared THEN
      -- ADR-003: o parceiro recebeu em espécie; a comissão vira débito da
      -- carteira dele no MESMO caminho de ledger do PIX (nada de atalho).
      v_pay := api_ride_cash_declare(p_ride, p_fare);
    END IF;
  ELSE
    PERFORM fn_ride_transition(p_ride, v_uid, p_to);
  END IF;
  RETURN api_ride_get(p_ride);
END $$;

-- -----------------------------------------------------------------------------
-- Relógio do servidor: rodada vencida vira EXPIRED no histórico (a oferta
-- segue valendo pelo valor combinado — quem decide isso é o timeout da oferta).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_negotiation_tick()
RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_n int;
BEGIN
  UPDATE negotiations SET status = 'EXPIRED'
   WHERE status = 'OPEN' AND expires_at < now();
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $$;
