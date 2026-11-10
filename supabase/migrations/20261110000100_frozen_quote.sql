-- =============================================================================
-- 10 é + — cotação congelada no servidor (Postgres)
--
-- O preço da corrida é decidido pelo SERVIDOR, em dois lugares e nunca no
-- cliente:
--
--   GET  /quote  →  emite uma COTAÇÃO: id (`quote_id`), valor e validade
--                   (`expires_in`, 90 s por padrão na config da cidade).
--   POST /rides  →  apresenta o `quote_id`. O servidor cobra o valor GRAVADO
--                   na cotação, uma única vez, só na mesma rota e só dentro
--                   da validade. O `quoted_fare` do corpo é INFORMATIVO: se
--                   divergir do valor gravado, o pedido é recusado
--                   (422 `quote_fare_mismatch`) — o cliente nunca escolhe o
--                   preço.
--
-- Sem `quote_id`, o servidor recalcula pela rota (mesma fórmula, valor de
-- agora) e ignora o `quoted_fare` do corpo — também é o que a demo faz.
--
-- A cotação mora numa tabela (`ride_quotes`) e é consumida por DELETE dentro
-- da mesma transação do pedido: uso único por construção (replay cai em
-- `quote_not_found`). O cliente não escreve nessa tabela — a RLS só permite
-- ler as próprias linhas.
--
-- Tolerância de rota: 5e-4 em graus (~55 m), a mesma folga da demo, para
-- absorver o jitter do GPS entre a cotação e o pedido.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Tabela das cotações
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ride_quotes (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  city_id      uuid NOT NULL REFERENCES cities(id) ON DELETE CASCADE,
  origin       geography(Point, 4326) NOT NULL,
  destination  geography(Point, 4326) NOT NULL,
  fare_total   numeric(10,2) NOT NULL CHECK (fare_total >= 0),
  distance_km  numeric(10,1),
  pricing      jsonb NOT NULL DEFAULT '{}'::jsonb,
  breakdown    jsonb NOT NULL DEFAULT '{}'::jsonb,
  expires_at   timestamptz NOT NULL,
  consumed_at  timestamptz,
  created_at   timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ride_quotes_user_created_idx
  ON ride_quotes (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS ride_quotes_expires_idx
  ON ride_quotes (expires_at);

ALTER TABLE ride_quotes ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS ride_quotes_own_select ON ride_quotes;
CREATE POLICY ride_quotes_own_select ON ride_quotes
  FOR SELECT TO authenticated
  USING (user_id = auth.uid());

GRANT SELECT ON ride_quotes TO authenticated;
GRANT ALL ON ride_quotes TO service_role;

-- -----------------------------------------------------------------------------
-- 2. Tolerância de ponto (mesma do cliente: jitter de GPS)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_same_point(
  p_a geography, p_b geography, p_tol float8 DEFAULT 5e-4
) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$
  SELECT p_a IS NOT NULL AND p_b IS NOT NULL
     AND abs(ST_Y(p_a::geometry) - ST_Y(p_b::geometry)) <= p_tol
     AND abs(ST_X(p_a::geometry) - ST_X(p_b::geometry)) <= p_tol;
$$;

-- -----------------------------------------------------------------------------
-- 3. Emitir a cotação (GET /quote)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api_quote(p_origin jsonb, p_destination jsonb)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_uid uuid := app_uid();
  v_city uuid;
  v_q jsonb;
  v_id uuid;
  v_ttl int;
  v_org geography;
  v_dst geography;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated' USING ERRCODE = '28000';
  END IF;
  IF p_origin->>'lat' IS NULL OR p_destination->>'lat' IS NULL THEN
    RAISE EXCEPTION 'invalid_points' USING ERRCODE = '22023';
  END IF;

  v_city := fn_city_for_caller();
  v_org  := fn_geog((p_origin->>'lat')::float8, (p_origin->>'lon')::float8);
  v_dst  := fn_geog((p_destination->>'lat')::float8, (p_destination->>'lon')::float8);

  v_q := fn_quote(v_city, v_org, v_dst);
  v_ttl := COALESCE((v_q->>'expires_in')::int, 90);

  -- Limpa as cotações vencidas do próprio usuário (o resto expira sozinho:
  -- a validação checa o prazo, não precisa de job).
  DELETE FROM ride_quotes
   WHERE user_id = v_uid AND expires_at < now() - interval '10 minutes';

  INSERT INTO ride_quotes
    (user_id, city_id, origin, destination, fare_total, distance_km,
     pricing, breakdown, expires_at)
  VALUES
    (v_uid, v_city, v_org, v_dst, (v_q->>'fare_total')::numeric,
     (v_q->'breakdown'->>'distance_km')::numeric,
     v_q->'pricing', v_q->'breakdown', now() + make_interval(secs => v_ttl))
  RETURNING id INTO v_id;

  RETURN (v_q || jsonb_build_object('quote_id', v_id, 'expires_in', v_ttl));
END $$;

-- -----------------------------------------------------------------------------
-- 4. Consumir a cotação (POST /rides)
--
-- Uso único: a linha é apagada na validação. Se a cotação não existir (id
-- errado ou já consumida) → `quote_not_found`; vencida → `quote_expired`;
-- outra rota → `quote_mismatch`; valor divergente do cliente →
-- `quote_fare_mismatch`.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_quote_resolve(
  p_quote_id uuid,
  p_origin jsonb,
  p_destination jsonb,
  p_client_quoted numeric DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  q ride_quotes%ROWTYPE;
  v_uid uuid := app_uid();
  v_org geography;
  v_dst geography;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated' USING ERRCODE = '28000';
  END IF;

  DELETE FROM ride_quotes
   WHERE id = p_quote_id AND user_id = v_uid
   RETURNING * INTO q;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'quote_not_found' USING ERRCODE = '22023';
  END IF;
  IF q.expires_at < now() THEN
    RAISE EXCEPTION 'quote_expired' USING ERRCODE = '22023';
  END IF;

  v_org := fn_geog((p_origin->>'lat')::float8, (p_origin->>'lon')::float8);
  v_dst := fn_geog((p_destination->>'lat')::float8, (p_destination->>'lon')::float8);
  IF NOT (fn_same_point(q.origin, v_org) AND fn_same_point(q.destination, v_dst)) THEN
    RAISE EXCEPTION 'quote_mismatch' USING ERRCODE = '22023';
  END IF;

  -- O `quoted_fare` do cliente é informativo: divergência é recusada, nunca
  -- aceita como preço.
  IF p_client_quoted IS NOT NULL
     AND abs(p_client_quoted - q.fare_total) > 0.005 THEN
    RAISE EXCEPTION 'quote_fare_mismatch' USING ERRCODE = '22023';
  END IF;

  RETURN jsonb_build_object(
    'quote_id', q.id,
    'fare_total', q.fare_total,
    'distance_km', q.distance_km,
    'pricing', q.pricing,
    'breakdown', q.breakdown);
END $$;

-- -----------------------------------------------------------------------------
-- 5. Pedido de corrida: preço vem da cotação (ou é recalculado)
--
-- A assinatura ganha `p_quote_id`. A versão anterior (sem o parâmetro) é
-- removida para não deixar duas sobrecargas com o mesmo nome — o PostgREST
-- resolveria a errada.
-- -----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS api_ride_request(
  jsonb, jsonb, text, text, numeric, numeric, uuid);

CREATE OR REPLACE FUNCTION api_ride_request(
  p_origin jsonb, p_destination jsonb,
  p_origin_address text DEFAULT NULL,
  p_destination_address text DEFAULT NULL,
  p_proposed numeric DEFAULT NULL,
  p_client_quoted numeric DEFAULT NULL,
  p_city uuid DEFAULT NULL,
  p_quote_id uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_uid uuid := app_uid(); v_city uuid; v_quote jsonb; v_rid uuid; v_pricing jsonb;
  v_org geography; v_dst geography;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated' USING ERRCODE = '28000';
  END IF;
  IF p_origin->>'lat' IS NULL OR p_destination->>'lat' IS NULL THEN
    RAISE EXCEPTION 'invalid_points' USING ERRCODE = '22023';
  END IF;
  v_city := COALESCE(p_city, fn_city_for_caller());
  v_org  := fn_geog((p_origin->>'lat')::float8, (p_origin->>'lon')::float8);
  v_dst  := fn_geog((p_destination->>'lat')::float8, (p_destination->>'lon')::float8);
  PERFORM fn_dispatch_tick();

  -- Com cotação: vale o valor GRAVADO (mesma rota, dentro da validade, uma
  -- vez). Sem cotação: o servidor recalcula pela rota — e o `quoted_fare` do
  -- corpo é ignorado nos dois casos.
  IF p_quote_id IS NOT NULL THEN
    v_quote := fn_quote_resolve(p_quote_id, p_origin, p_destination, p_client_quoted);
  ELSE
    v_quote := fn_quote(v_city, v_org, v_dst);
  END IF;

  v_pricing := (v_quote->'pricing')
             || jsonb_build_object('fare_total', (v_quote->>'fare_total')::numeric,
                                   'quoted_at', now())
             || CASE WHEN p_client_quoted IS NOT NULL
                     THEN jsonb_build_object('client_quoted', p_client_quoted)
                     ELSE '{}'::jsonb END;

  v_rid := fn_ride_request(
      v_uid, v_city, v_org, v_dst, v_pricing, p_proposed);

  UPDATE rides
     SET distance_km = (v_quote->'breakdown'->>'distance_km')::numeric,
         origin_address = p_origin_address,
         destination_address = p_destination_address,
         fare_total = CASE WHEN p_proposed IS NULL
                           THEN (v_quote->>'fare_total')::numeric ELSE NULL END
   WHERE id = v_rid;

  PERFORM fn_dispatch_next(v_rid);   -- melhor candidato já recebe a oferta
  RETURN api_ride_get(v_rid);
END $$;

-- -----------------------------------------------------------------------------
-- 6. Permissões
--
-- Só as duas portas HTTP (api_quote / api_ride_request) ficam acessíveis ao
-- usuário autenticado. Os auxiliares (`fn_same_point`, `fn_quote_resolve`)
-- ficam com o dono: são chamados de dentro das funções SECURITY DEFINER e
-- não precisam — nem devem — ser chamáveis direto.
-- -----------------------------------------------------------------------------
REVOKE ALL ON FUNCTION fn_same_point(geography, geography, float8) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION fn_quote_resolve(uuid, jsonb, jsonb, numeric) FROM PUBLIC, anon, authenticated;

DO $$
DECLARE f record;
BEGIN
  FOR f IN
    SELECT p.oid::regprocedure AS sig
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname IN ('api_quote', 'api_ride_request')
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon', f.sig);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated, service_role', f.sig);
  END LOOP;
END $$;
