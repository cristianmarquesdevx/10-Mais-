-- =============================================================================
-- 10 é + — a perda da oferta, calculada pelo servidor.
--
-- O app do parceiro explica a consequência de recusar (ou deixar o tempo
-- estourar): quanto ele deixou de ganhar, qual era a corrida e como a taxa de
-- aceite — critério do despacho — ficou depois. Esses números NÃO podem sair da
-- tela: o valor é o que o despacho congelou na oferta e a taxa é a que o
-- `fn_partner_acceptance_recalc` aplicou. Por isso nascem aqui.
--
-- A visão da oferta (`api_offer_get`) passa a trazer `loss` quando a oferta já
-- morreu (DECLINED/EXPIRED), e a recusa devolve `loss` na mesma resposta — a
-- tela não precisa de uma segunda chamada para saber o que perdeu.
-- =============================================================================

CREATE OR REPLACE FUNCTION fn_offer_loss(p_offer uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  o offers%ROWTYPE; r rides%ROWTYPE;
  v_speed numeric; v_timeout int;
  v_pickup numeric; v_pickup_eta numeric; v_trip_min numeric;
  v_before numeric; v_after numeric;
BEGIN
  SELECT * INTO o FROM offers WHERE id = p_offer;
  IF NOT FOUND THEN RETURN NULL; END IF;
  SELECT * INTO r FROM rides WHERE id = o.ride_id;

  v_speed   := (city_param(r.city_id,'PRM-despacho.velocidade_viagem','30') #>> '{}')::numeric;
  v_timeout := (city_param(r.city_id,'PRM-oferta.timeout','15') #>> '{}')::int;

  -- Distância de coleta no instante da leitura (a mesma que o despacho usou
  -- para ranquear); sem posição conhecida o campo fica nulo, não zero.
  SELECT round((ST_Distance(pr.last_position, r.origin) / 1000.0)::numeric, 2)
    INTO v_pickup
    FROM partner_presence pr
   WHERE pr.partner_user_id = o.partner_user_id;
  v_pickup_eta := CASE WHEN v_speed > 0 AND v_pickup IS NOT NULL
                       THEN round(v_pickup / v_speed * 60)::int END;
  v_trip_min   := CASE WHEN v_speed > 0 AND r.distance_km IS NOT NULL
                       THEN round(r.distance_km / v_speed * 60)::int END;

  -- Taxa de aceite ANTES desta oferta (sem ela) e DEPOIS (como o despacho
  -- aplicou). A janela é a mesma do recálculo: 30 dias.
  SELECT CASE WHEN count(*) FILTER (WHERE status IN ('ACCEPTED','DECLINED','EXPIRED')) = 0
              THEN NULL
              ELSE round(
                (count(*) FILTER (WHERE status = 'ACCEPTED'))::numeric
                / (count(*) FILTER (WHERE status IN ('ACCEPTED','DECLINED','EXPIRED'))), 4)
         END
    INTO v_before
    FROM offers
   WHERE partner_user_id = o.partner_user_id
     AND id <> o.id
     AND sent_at > now() - interval '30 days';
  SELECT acceptance_rate INTO v_after FROM partners WHERE user_id = o.partner_user_id;

  RETURN jsonb_build_object(
    'offer_id', o.id,
    'ride_id', o.ride_id,
    'reason', CASE WHEN o.status = 'EXPIRED' THEN 'EXPIRED' ELSE 'DECLINED' END,
    'lost_amount', o.offered_amount,
    'pickup_distance_km', v_pickup,
    'pickup_eta_min', v_pickup_eta,
    'trip_distance_km', r.distance_km,
    'trip_duration_min', v_trip_min,
    'timeout_s', v_timeout,
    'acceptance_rate_before', v_before,
    'acceptance_rate', v_after);
END $$;

-- Recusa: mesma resposta de antes (`declined`, `next`) + a perda. A perda só
-- entra quando a oferta realmente saiu de SENT — responder "você perdeu" numa
-- oferta que já tinha sido aceita seria mentira.
CREATE OR REPLACE FUNCTION api_offer_decline(p_offer uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_out jsonb;
BEGIN
  IF app_uid() IS NULL THEN
    RAISE EXCEPTION 'not_authenticated' USING ERRCODE = '28000';
  END IF;
  v_out := fn_offer_decline(p_offer, app_uid());
  IF (v_out->>'declined')::boolean IS TRUE THEN
    v_out := v_out || jsonb_build_object('loss', fn_offer_loss(p_offer));
  END IF;
  RETURN v_out;
END $$;

-- A visão da oferta vira `api_offer_view` (mesmo corpo, sem alteração) e
-- `api_offer_get` passa a anexar `loss` quando a oferta já morreu. Assim o
-- fechamento do timeout (a oferta some de /offers/mine) continua explicável.
DO $$
BEGIN
  IF to_regprocedure('public.api_offer_view(uuid)') IS NULL THEN
    ALTER FUNCTION public.api_offer_get(uuid) RENAME TO api_offer_view;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION api_offer_get(p_offer uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_out jsonb; v_status text;
BEGIN
  v_out := api_offer_view(p_offer);          -- valida dono (token) e devolve a visão
  SELECT status INTO v_status FROM offers WHERE id = p_offer;
  IF v_status IN ('DECLINED', 'EXPIRED') THEN
    v_out := v_out || jsonb_build_object('loss', fn_offer_loss(p_offer));
  END IF;
  RETURN v_out;
END $$;
