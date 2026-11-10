-- =============================================================================
-- 10 é + — avaliação da corrida (fecha o ciclo no backend real).
--
-- A demo guardava a nota num dicionário global e movia a média do parceiro "de
-- tela". Aqui a avaliação entra em `ratings` (uma por corrida e por avaliador,
-- regra do índice único) e a nota que o DESPACHO usa (`partners.rating_avg` /
-- `rating_count`) é recalculada a partir das avaliações reais.
--
-- Regras: só participante da corrida avalia, só corrida FINALIZADA, de 1 a 5
-- estrelas. O avaliado é sempre o OUTRO lado — nunca o próprio usuário.
-- =============================================================================
CREATE OR REPLACE FUNCTION api_ride_rate(
  p_ride uuid,
  p_stars smallint,
  p_comment text DEFAULT NULL,
  p_tags text[] DEFAULT '{}'
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  r rides%ROWTYPE;
  v_uid uuid := app_uid();
  v_rated uuid; v_avg numeric; v_cnt int;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated' USING ERRCODE = '28000';
  END IF;
  SELECT * INTO r FROM rides WHERE id = p_ride;
  IF NOT FOUND
     OR (r.passenger_user_id <> v_uid AND r.partner_user_id IS DISTINCT FROM v_uid) THEN
    RAISE EXCEPTION 'ride_not_found' USING ERRCODE = 'P0002';
  END IF;
  IF r.status <> 'FINALIZADA' THEN
    RAISE EXCEPTION 'ride_not_finished' USING ERRCODE = '40900';
  END IF;
  IF p_stars IS NULL OR p_stars < 1 OR p_stars > 5 THEN
    RAISE EXCEPTION 'invalid_rating' USING ERRCODE = '22023';
  END IF;

  v_rated := CASE WHEN v_uid = r.passenger_user_id
                  THEN r.partner_user_id ELSE r.passenger_user_id END;
  IF v_rated IS NULL THEN
    RAISE EXCEPTION 'invalid_rating' USING ERRCODE = '22023';
  END IF;

  IF EXISTS (SELECT 1 FROM ratings WHERE ride_id = p_ride AND rater_user_id = v_uid) THEN
    RAISE EXCEPTION 'already_rated' USING ERRCODE = '23505';
  END IF;

  INSERT INTO ratings (ride_id, rater_user_id, rated_user_id, stars, tags, comment)
  VALUES (p_ride, v_uid, v_rated, p_stars, COALESCE(p_tags, '{}'),
          NULLIF(btrim(COALESCE(p_comment, '')), ''));

  -- A nota do despacho sai das avaliações, não de um número escolhido na tela.
  SELECT round(avg(stars)::numeric, 2), count(*)::int
    INTO v_avg, v_cnt
    FROM ratings WHERE rated_user_id = v_rated;
  UPDATE partners SET rating_avg = v_avg, rating_count = v_cnt
   WHERE user_id = v_rated;

  RETURN jsonb_build_object(
    'ride_id', p_ride, 'rated_user_id', v_rated, 'stars', p_stars,
    'rating_avg', v_avg, 'rating_count', v_cnt);
END $$;
