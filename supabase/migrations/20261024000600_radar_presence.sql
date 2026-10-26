-- =============================================================================
-- 10 é + — Radar real: presença do parceiro + motoristas próximos
-- Fase 3 (base real), sobre 0001–0004.
--
-- Regras:
--   * Só o próprio parceiro autenticado escreve sua presença (SECURITY DEFINER,
--     auth.uid() obrigatório, KYC aprovado, status permitido).
--   * Heartbeat fresco (90 s) é condição de elegibilidade — posição antiga não
--     aparece no radar.
--   * Privacidade: a posição sai "snapada" (~110 m) e a distância arredondada;
--     o id do parceiro é pseudônimo diário (não permite rastrear entre dias).
--   * Nada de motorista sintético: sem presença real, a função devolve 0 linhas.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Atualização de presença (online / pausa / offline / heartbeat)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_presence_update(
  p_status text,
  p_lat double precision DEFAULT NULL,
  p_lon double precision DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid    uuid := auth.uid();
  v_kyc    text;
  v_city   uuid;
  v_ts     timestamptz := now();
  v_point  geography;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated' USING ERRCODE = '28000';
  END IF;

  IF p_status NOT IN ('ONLINE_DISPONIVEL', 'PAUSA', 'OFFLINE') THEN
    RAISE EXCEPTION 'invalid_status' USING ERRCODE = '22023';
  END IF;

  SELECT p.kyc_status, p.city_id
    INTO v_kyc, v_city
    FROM partners p
   WHERE p.user_id = v_uid AND p.deleted_at IS NULL;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'not_a_partner' USING ERRCODE = '42501';
  END IF;

  -- Offline é sempre permitido (inclusive KYC pendente); ficar visível não é.
  IF p_status <> 'OFFLINE' AND v_kyc <> 'APPROVED' THEN
    RAISE EXCEPTION 'kyc_not_approved' USING ERRCODE = '42501';
  END IF;

  IF p_status IN ('ONLINE_DISPONIVEL', 'PAUSA') THEN
    IF p_lat IS NULL OR p_lon IS NULL
       OR p_lat < -90 OR p_lat > 90 OR p_lon < -180 OR p_lon > 180 THEN
      RAISE EXCEPTION 'invalid_position' USING ERRCODE = '22023';
    END IF;
    v_point := ST_SetSRID(ST_MakePoint(p_lon, p_lat), 4326)::geography;
  END IF;

  INSERT INTO partner_presence (
    partner_user_id, online_status, last_position, last_position_at,
    stale_after, last_heartbeat_at, updated_at
  ) VALUES (
    v_uid, p_status, v_point,
    CASE WHEN v_point IS NULL THEN NULL ELSE v_ts END,
    CASE WHEN p_status = 'ONLINE_DISPONIVEL' THEN v_ts + interval '90 seconds' END,
    CASE WHEN p_status = 'OFFLINE' THEN NULL ELSE v_ts END,
    v_ts
  )
  ON CONFLICT (partner_user_id) DO UPDATE SET
    online_status     = EXCLUDED.online_status,
    -- OFFLINE apaga a posição: não deixamos rastro visível de quem saiu.
    last_position     = CASE WHEN EXCLUDED.online_status = 'OFFLINE'
                             THEN NULL ELSE EXCLUDED.last_position END,
    last_position_at  = CASE WHEN EXCLUDED.online_status = 'OFFLINE'
                             THEN NULL ELSE EXCLUDED.last_position_at END,
    stale_after       = EXCLUDED.stale_after,
    last_heartbeat_at = EXCLUDED.last_heartbeat_at,
    updated_at        = EXCLUDED.updated_at;

  RETURN jsonb_build_object(
    'status', p_status,
    'updated_at', v_ts,
    'has_position', v_point IS NOT NULL
  );
END;
$$;

REVOKE ALL ON FUNCTION public.fn_presence_update(text, double precision, double precision) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_presence_update(text, double precision, double precision) TO authenticated;

-- -----------------------------------------------------------------------------
-- 2. Motoristas próximos (radar) — somente ONLINE_DISPONIVEL com heartbeat fresco
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_nearby_partners(
  p_lat double precision,
  p_lon double precision,
  p_radius_km double precision DEFAULT 5.0,
  p_limit integer DEFAULT 30
) RETURNS TABLE (
  driver_id    text,
  lat          double precision,
  lon          double precision,
  distance_km  double precision,
  vehicle      text,
  eligible_total bigint
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_g   geography;
  v_r   double precision := least(greatest(coalesce(p_radius_km, 5.0), 0.5), 20.0);
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated' USING ERRCODE = '28000';
  END IF;
  IF p_lat IS NULL OR p_lon IS NULL
     OR p_lat < -90 OR p_lat > 90 OR p_lon < -180 OR p_lon > 180 THEN
    RAISE EXCEPTION 'invalid_position' USING ERRCODE = '22023';
  END IF;

  v_g := ST_SetSRID(ST_MakePoint(p_lon, p_lat), 4326)::geography;

  RETURN QUERY
  WITH candidates AS (
    SELECT
      p.user_id,
      -- ~110 m: suficiente para o radar, insuficiente para achar a porta.
      ST_SnapToGrid(pr.last_position::geometry, 0.001) AS snapped,
      ST_Distance(pr.last_position, v_g) / 1000.0 AS dist_km,
      (SELECT v.model FROM vehicles v
        WHERE v.partner_user_id = p.user_id AND v.active
        ORDER BY v.created_at LIMIT 1) AS vehicle_model
      FROM partners p
      JOIN partner_presence pr ON pr.partner_user_id = p.user_id
     WHERE p.kyc_status = 'APPROVED'
       AND p.deleted_at IS NULL
       AND pr.online_status = 'ONLINE_DISPONIVEL'
       AND pr.last_position IS NOT NULL
       AND pr.last_heartbeat_at > now() - interval '90 seconds'
       AND pr.last_position IS NOT NULL
       AND ST_DWithin(pr.last_position, v_g, v_r * 1000)
       AND p.user_id <> v_uid
  )
  SELECT
    -- pseudônimo diário: não permite rastrear o mesmo parceiro entre dias
    'p_' || substr(md5(c.user_id::text || to_char(now(), 'YYYY-MM-DD')), 1, 10),
    ST_Y(c.snapped),
    ST_X(c.snapped),
    round(c.dist_km::numeric, 1)::double precision,
    c.vehicle_model,
    count(*) OVER ()
  FROM candidates c
  ORDER BY c.dist_km
  LIMIT least(greatest(coalesce(p_limit, 30), 1), 100);
END;
$$;

REVOKE ALL ON FUNCTION public.fn_nearby_partners(double precision, double precision, double precision, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_nearby_partners(double precision, double precision, double precision, integer) TO authenticated;

-- Índice de leitura do radar (o GiST existente cobre ST_DWithin; este cobre o
-- filtro de frescor/status sem varrer presença antiga).
CREATE INDEX IF NOT EXISTS idx_presence_fresh
  ON partner_presence (last_heartbeat_at DESC)
  WHERE online_status = 'ONLINE_DISPONIVEL';

COMMENT ON FUNCTION public.fn_nearby_partners(double precision, double precision, double precision, integer)
  IS 'Radar: parceiros ONLINE_DISPONIVEL, KYC aprovado, heartbeat <90s, posição snapada ~110m, id pseudônimo diário.';
