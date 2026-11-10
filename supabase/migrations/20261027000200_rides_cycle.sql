-- =============================================================================
-- 10 é + — 20261027000200_rides_cycle.sql
-- O CICLO DE CORRIDA no Postgres, com a identidade vinda do TOKEN.
--
-- A demo (scripts/demo_api.py) mantinha corridas, ofertas, despacho e preço em
-- memória. Aqui eles passam a viver no banco, com estas regras:
--
--   * toda operação do app é uma função `api_*` que DERIVA o ator de app_uid()
--     (o `sub` do JWT verificado). Nenhum id de usuário vem do corpo: o cliente
--     não consegue pedir corrida, aceitar oferta ou cancelar em nome de outro;
--   * preço, ranking de despacho, oferta, recusa com reoferta, transições e
--     pagamento rodam no SERVIDOR, no relógio do servidor;
--   * leitura passa por RLS *e* por checagem explícita de participante;
--   * a demanda do preço é lida do que está GRAVADO (pedidos recentes), não de
--     um dicionário em memória que zera a cada reinício.
--
-- Conteúdo:
--   1. consertos de base que o ciclo exige (carteira do parceiro, ociosidade,
--      preferências do parceiro, unidade da comissão);
--   2. preço (fn_quote);
--   3. despacho (fn_dispatch_evaluate / fn_dispatch_next) com os MESMOS pesos
--      de scripts/dispatch.py;
--   4. recusa/timeout com reoferta (fn_offer_decline / fn_dispatch_tick);
--   5. API do ciclo: api_quote, api_ride_request, api_rides_mine, api_ride_get,
--      api_ride_cancel, api_ride_dispatch, api_offers_mine, api_offer_get,
--      api_offer_accept, api_offer_decline, api_ride_transition,
--      api_payment_intent, api_payment_get, api_ride_cash_declare.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1.1 Carteira do parceiro.
--
-- `fn_payment_confirm_ride` lança em PARTNER/WALLET e `fn_ledger_post` RECUSA
-- conta inexistente — sem esta conta a primeira corrida paga morria com
-- "ledger account missing". A conta é do produto, não do teste: nasce com o
-- parceiro (trigger) e o backfill cobre quem já existia.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_partner_accounts() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  INSERT INTO ledger_accounts (owner_type, owner_user_id, kind)
  SELECT 'PARTNER', NEW.user_id, 'WALLET'
  WHERE NOT EXISTS (
    SELECT 1 FROM ledger_accounts
     WHERE owner_type = 'PARTNER' AND owner_user_id = NEW.user_id AND kind = 'WALLET');
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_partner_accounts ON partners;
CREATE TRIGGER trg_partner_accounts AFTER INSERT ON partners
FOR EACH ROW EXECUTE FUNCTION fn_partner_accounts();

INSERT INTO ledger_accounts (owner_type, owner_user_id, kind)
SELECT 'PARTNER', p.user_id, 'WALLET'
  FROM partners p
 WHERE NOT EXISTS (
   SELECT 1 FROM ledger_accounts a
    WHERE a.owner_type = 'PARTNER' AND a.owner_user_id = p.user_id AND a.kind = 'WALLET');

-- -----------------------------------------------------------------------------
-- 1.2 Ociosidade real (entrada do ranking).
--
-- "Tempo ocioso" precisa de um marco confiável. `partner_presence` guarda
-- status e heartbeat, mas não desde quando o parceiro está esperando; sem isso
-- o anti-inanição do despacho virava chute. Um trigger mantém a coluna sem
-- tocar em `fn_presence_update` (a regra de presença segue num lugar só).
-- -----------------------------------------------------------------------------
ALTER TABLE partner_presence ADD COLUMN IF NOT EXISTS idle_since timestamptz;

CREATE OR REPLACE FUNCTION trg_presence_idle() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.online_status IN ('OFFLINE','EM_CORRIDA','EM_ENTREGA') THEN
    NEW.idle_since := NULL;                 -- fora da fila não acumula ociosidade
  ELSIF NEW.idle_since IS NULL THEN
    NEW.idle_since := now();                -- entrou na fila agora (ou acaba de voltar)
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_presence_idle ON partner_presence;
CREATE TRIGGER trg_presence_idle BEFORE INSERT OR UPDATE ON partner_presence
FOR EACH ROW EXECUTE FUNCTION trg_presence_idle();

UPDATE partner_presence
   SET idle_since = COALESCE(updated_at, now())
 WHERE online_status IN ('ONLINE_DISPONIVEL','OFERTA_PENDENTE','PAUSA')
   AND idle_since IS NULL;

-- -----------------------------------------------------------------------------
-- 1.3 Preferências do parceiro (serviços ligados, valor mínimo, raio).
--
-- São FILTROS do despacho (SPECS §1.3) e existiam só na memória da demo — sem
-- eles o motorista receberia corrida que ele desligou e abaixo do mínimo dele.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS partner_preferences (
  partner_user_id uuid PRIMARY KEY REFERENCES partners(user_id) ON DELETE CASCADE,
  -- Códigos de `service_types` que o parceiro aceita (RIDE_CAR, DELIVERY_MOTO).
  services        text[] NOT NULL DEFAULT '{RIDE_CAR}',
  min_fare        numeric(10,2) NOT NULL DEFAULT 0
                  CHECK (min_fare >= 0 AND min_fare <= 500),
  radius_km       numeric(5,1) NOT NULL DEFAULT 5
                  CHECK (radius_km > 0 AND radius_km <= 30),
  updated_at      timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE partner_preferences ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS p_prefs_own_read ON partner_preferences;
CREATE POLICY p_prefs_own_read ON partner_preferences FOR SELECT
  USING (partner_user_id = app_uid() OR app_is_agent());

DROP POLICY IF EXISTS p_prefs_own_write ON partner_preferences;
CREATE POLICY p_prefs_own_write ON partner_preferences FOR ALL
  USING (partner_user_id = app_uid())
  WITH CHECK (partner_user_id = app_uid());

GRANT SELECT, INSERT, UPDATE, DELETE ON partner_preferences TO authenticated;

-- Toda conta de parceiro tem preferências desde o início (defaults do produto).
CREATE OR REPLACE FUNCTION fn_partner_prefs() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  INSERT INTO partner_preferences (partner_user_id) VALUES (NEW.user_id)
  ON CONFLICT (partner_user_id) DO NOTHING;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_partner_prefs ON partners;
CREATE TRIGGER trg_partner_prefs AFTER INSERT ON partners
FOR EACH ROW EXECUTE FUNCTION fn_partner_prefs();

INSERT INTO partner_preferences (partner_user_id)
SELECT p.user_id FROM partners p
ON CONFLICT (partner_user_id) DO NOTHING;

-- -----------------------------------------------------------------------------
-- 1.4 Unidade da comissão.
--
-- O seed gravava `PRM-comissao.pct = 12` e `fn_payment_confirm_ride` multiplica
-- o valor bruto por esse número: uma corrida de R$ 20 lançava R$ 240 de
-- comissão. O contrato da função é FRAÇÃO (default 0.12 = 12%, conforme
-- "Comissão aprovada: 12%" no PRODUTO-MESTRE). Corrigimos o dado existente e a
-- origem (supabase/seed.sql) fica com o mesmo contrato.
-- -----------------------------------------------------------------------------
UPDATE city_configs
   SET param_value = to_jsonb(
         round(((param_value #>> '{}')::numeric) / 100.0, 4))
 WHERE param_key = 'PRM-comissao.pct'
   AND (param_value #>> '{}') ~ '^[0-9]+(\.[0-9]+)?$'
   AND (param_value #>> '{}')::numeric > 1;

-- Parâmetros do preço e do despacho (calibráveis por cidade; defaults do produto).
--
-- Precisa ser uma FUNÇÃO chamada por gatilho, e não um INSERT único: no install
-- limpo as migrações rodam ANTES do seed, então `cities` está vazia e um INSERT
-- "SELECT ... FROM cities" não gravaria nada — a cidade nasceria sem parâmetro
-- nenhum (o código cairia nos defaults embutidos e ninguém veria a configuração
-- para calibrar). Com o gatilho, toda cidade nova já nasce parametrizada.
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
    ('PRM-pagamento.validade_s',       '900'::jsonb)
  ) AS t(k, v)
  LOOP
    INSERT INTO city_configs (city_id, param_key, param_value, valid_from)
    SELECT p_city, p.k, p.v, now() - interval '1 day'
    WHERE NOT EXISTS (
      SELECT 1 FROM city_configs cc
       WHERE cc.city_id = p_city AND cc.param_key = p.k);
  END LOOP;
END $$;

CREATE OR REPLACE FUNCTION trg_city_defaults() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM fn_city_defaults(NEW.id);
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_city_defaults ON cities;
CREATE TRIGGER trg_city_defaults AFTER INSERT ON cities
FOR EACH ROW EXECUTE FUNCTION trg_city_defaults();

-- Cidades que já existem (install em cima de um banco com dados)
SELECT fn_city_defaults(c.id) FROM cities c;

-- -----------------------------------------------------------------------------
-- 2. PREÇO — cotação do servidor.
--
-- Distância estimada pela geodésica × fator de via (o OSRM entra no lugar do
-- fator quando a rota por ruas for medida no servidor — front já isolado em
-- `lib/src/api/route_service.dart`). A demanda sai de pedidos GRAVADOS perto da
-- origem nos últimos 15 min: duas execuções seguidas do mesmo ponto dão o mesmo
-- preço, e o preço não desaparece quando o processo reinicia.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_quote(
  p_city uuid,
  p_origin geography,
  p_destination geography,
  p_service text DEFAULT 'RIDE_CAR'
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_base numeric; v_km_price numeric; v_floor numeric; v_factor numeric;
  v_km numeric; v_heat int; v_demand numeric; v_rush numeric; v_hour int;
  v_validity int; v_fare numeric; v_tz text; v_window int; v_radius int;
  v_weight numeric; v_cap numeric;
BEGIN
  IF app_uid() IS NULL THEN
    RAISE EXCEPTION 'not_authenticated' USING ERRCODE = '28000';
  END IF;

  v_base     := (city_param(p_city,'PRM-preco.base','5.00') #>> '{}')::numeric;
  v_km_price := (city_param(p_city,'PRM-preco.km','2.20') #>> '{}')::numeric;
  v_floor    := (city_param(p_city,'PRM-preco.piso','8.00') #>> '{}')::numeric;
  v_factor   := (city_param(p_city,'PRM-preco.fator_via','1.35') #>> '{}')::numeric;
  v_validity := (city_param(p_city,'PRM-preco.validade','90') #>> '{}')::int;
  v_window   := (city_param(p_city,'PRM-demanda.janela_min','15') #>> '{}')::int;
  v_radius   := (city_param(p_city,'PRM-demanda.raio_m','1500') #>> '{}')::int;
  v_weight   := (city_param(p_city,'PRM-demanda.peso','0.07') #>> '{}')::numeric;
  v_cap      := (city_param(p_city,'PRM-demanda.teto','0.35') #>> '{}')::numeric;

  -- km que o card exibe (1 casa): a conta do preço fecha com o número na tela
  v_km := GREATEST(0.1, round((ST_Distance(p_origin, p_destination) / 1000.0
                               * v_factor)::numeric, 1));

  SELECT count(*) INTO v_heat
    FROM rides r
   WHERE r.city_id = p_city
     AND r.requested_at > now() - make_interval(mins => v_window)
     AND r.status NOT IN ('CRIADA','CANCELADA_CLIENTE','CANCELADA_PARCEIRO',
                          'CANCELADA_SISTEMA','CANCELADA_SUPORTE','EXPIRADA')
     AND ST_DWithin(r.origin, p_origin, v_radius);

  SELECT COALESCE(timezone,'America/Porto_Velho') INTO v_tz FROM cities WHERE id = p_city;
  v_hour := EXTRACT(hour FROM (now() AT TIME ZONE COALESCE(v_tz,'America/Porto_Velho')))::int;
  v_demand := round((1.0 + LEAST(v_cap, v_weight * v_heat))::numeric, 2);
  v_rush := CASE WHEN v_hour IN (7,8,9,17,18,19) THEN 1.18
                 WHEN v_hour <= 5 THEN 0.88
                 ELSE 1.00 END;
  v_fare := GREATEST(v_floor, round((v_base + v_km_price * v_km) * v_demand * v_rush, 2));

  RETURN jsonb_build_object(
    'fare_total', v_fare,
    'currency', 'BRL',
    'expires_in', v_validity,
    'breakdown', jsonb_build_object(
      'distance_km', v_km,
      'base', round(v_base + v_km_price * v_km, 2),
      'base_fare', v_base,
      'per_km', v_km_price,
      'floor', v_floor,
      'demand_multiplier', v_demand,
      'rush_multiplier', v_rush,
      'live_requests_nearby', v_heat),
    'pricing', jsonb_build_object(
      'base', v_base, 'per_km', v_km_price, 'floor', v_floor,
      'demand', v_demand, 'rush', v_rush, 'distance_km', v_km));
END $$;

-- -----------------------------------------------------------------------------
-- 3. DESPACHO — mesmos pesos de scripts/dispatch.py, agora no servidor.
--
--   ETA 0.40 · avaliação 0.20 · taxa de aceite 0.15 · tempo ocioso 0.15 ·
--   experiência 0.05 · qualidade da posição 0.05
--
-- Filtros (eliminam, não pontuam): KYC aprovado, posição fresca, serviço
-- ligado nas preferências, veículo compatível, valor mínimo do parceiro, raio
-- da rodada e quem já recebeu esta corrida na rodada.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_partner_acceptance_recalc(p_partner uuid)
RETURNS numeric
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_rate numeric;
BEGIN
  SELECT CASE WHEN count(*) FILTER (WHERE status IN ('ACCEPTED','DECLINED','EXPIRED')) = 0
              THEN NULL
              ELSE round(
                (count(*) FILTER (WHERE status = 'ACCEPTED'))::numeric
                / (count(*) FILTER (WHERE status IN ('ACCEPTED','DECLINED','EXPIRED'))),
                4) END
    INTO v_rate
    FROM offers
   WHERE partner_user_id = p_partner
     AND sent_at > now() - interval '30 days';
  IF v_rate IS NOT NULL THEN
    UPDATE partners SET acceptance_rate = v_rate WHERE user_id = p_partner;
  END IF;
  RETURN v_rate;
END $$;

CREATE OR REPLACE FUNCTION fn_dispatch_evaluate(p_ride uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  r rides%ROWTYPE;
  v_offered int; v_r0 numeric; v_step numeric; v_max numeric; v_radius numeric;
  v_tol int; v_speed numeric; v_eta_ref numeric; v_idle_cap numeric;
  v_newcomer numeric; v_notes_min int;
  v_service text; v_fare numeric;
  v_out jsonb := '[]'::jsonb;
  rec record;
  v_dist numeric; v_eta numeric; v_idle numeric; v_completed int;
  v_f_eta numeric; v_f_rating numeric; v_f_acc numeric; v_f_idle numeric;
  v_f_exp numeric; v_f_route numeric; v_score numeric;
  v_eligible boolean; v_reason text;
BEGIN
  SELECT * INTO r FROM rides WHERE id = p_ride;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ride_not_found' USING ERRCODE = 'P0002';
  END IF;

  v_offered   := (SELECT count(*) FROM offers WHERE ride_id = p_ride);
  v_r0        := (city_param(r.city_id,'PRM-match.r0','2')       #>> '{}')::numeric;
  v_step      := (city_param(r.city_id,'PRM-match.passo','1')    #>> '{}')::numeric;
  v_max       := (city_param(r.city_id,'PRM-match.rmax','8')     #>> '{}')::numeric;
  v_tol       := (city_param(r.city_id,'PRM-hb.tolerancia','90') #>> '{}')::int;
  v_speed     := (city_param(r.city_id,'PRM-despacho.velocidade','22') #>> '{}')::numeric;
  v_eta_ref   := (city_param(r.city_id,'PRM-despacho.eta_ref_min','15') #>> '{}')::numeric;
  v_idle_cap  := (city_param(r.city_id,'PRM-despacho.ocioso_teto_s','1800') #>> '{}')::numeric;
  v_newcomer  := (city_param(r.city_id,'PRM-despacho.novato_corridas','500') #>> '{}')::numeric;
  v_notes_min := (city_param(r.city_id,'PRM-despacho.notas_min','20') #>> '{}')::int;
  -- Raio da rodada cresce a cada oferta enviada: r0, r0+passo, ... até rmax.
  v_radius := LEAST(v_r0 + v_step * v_offered, v_max);

  -- O serviço vem da CORRIDA (service_types), não de um nome fixo: uma corrida
  -- de carro (RIDE_CAR) só é oferecida a quem aceita aquele serviço. A
  -- negociação muda o PREÇO, não o serviço.
  v_service := (SELECT st.code FROM service_types st WHERE st.id = r.service_type_id);
  v_fare    := COALESCE(r.proposed_amount, (r.pricing->>'fare_total')::numeric, 0);

  FOR rec IN
    SELECT p.user_id AS partner_id,
           p.rating_avg, p.rating_count, p.acceptance_rate, p.kyc_status,
           pr.online_status, pr.last_position, pr.last_heartbeat_at,
           COALESCE(pr.idle_since, pr.updated_at) AS idle_since,
           COALESCE(prf.services, '{RIDE_CAR}'::text[]) AS services,
           COALESCE(prf.min_fare, 0) AS min_fare,
           (SELECT count(*) FROM rides x
             WHERE x.partner_user_id = p.user_id AND x.status = 'FINALIZADA') AS completed,
           (SELECT string_agg(DISTINCT v.brand || ' ' || v.model, ', ')
              FROM vehicles v
             WHERE v.partner_user_id = p.user_id AND v.active) AS fleet,
           (SELECT count(*) FROM offers o
             WHERE o.ride_id = p_ride AND o.partner_user_id = p.user_id) AS already_offered,
           (SELECT max(o.sent_at) FROM offers o
             WHERE o.ride_id = p_ride AND o.partner_user_id = p.user_id) AS last_offer_at,
           (SELECT o.status FROM offers o
             WHERE o.ride_id = p_ride AND o.partner_user_id = p.user_id
             ORDER BY o.sent_at DESC LIMIT 1) AS last_offer_status,
           ST_Y(pr.last_position::geometry) AS lat,
           ST_X(pr.last_position::geometry) AS lon
      FROM partners p
      JOIN partner_presence pr ON pr.partner_user_id = p.user_id
      LEFT JOIN partner_preferences prf ON prf.partner_user_id = p.user_id
     WHERE p.deleted_at IS NULL
       AND pr.last_position IS NOT NULL
  LOOP
    v_dist := round((ST_Distance(
                 rec.last_position,
                 r.origin) / 1000.0)::numeric, 2);
    v_eta := CASE WHEN v_speed > 0 THEN round(v_dist / v_speed * 60.0, 1) ELSE 0 END;
    v_idle := GREATEST(0, EXTRACT(epoch FROM now() - rec.idle_since));
    v_completed := rec.completed;

    v_eligible := true;
    v_reason := NULL;
    IF rec.kyc_status <> 'APPROVED' THEN
      v_eligible := false; v_reason := 'kyc_not_approved';
    ELSIF rec.online_status NOT IN ('ONLINE_DISPONIVEL','OFERTA_PENDENTE') THEN
      v_eligible := false; v_reason := 'not_available';
    ELSIF rec.last_heartbeat_at IS NULL
       OR rec.last_heartbeat_at < now() - make_interval(secs => v_tol) THEN
      v_eligible := false; v_reason := 'stale_position';
    ELSIF NOT (v_service = ANY(rec.services)) THEN
      v_eligible := false; v_reason := 'service_disabled';
    ELSIF NOT EXISTS (SELECT 1 FROM vehicles v
                       WHERE v.partner_user_id = rec.partner_id AND v.active
                         AND v.service_type_id = r.service_type_id) THEN
      v_eligible := false; v_reason := 'vehicle_mismatch';
    ELSIF v_fare < rec.min_fare THEN
      v_eligible := false; v_reason := 'below_min_fare';
    ELSIF v_dist > v_radius THEN
      v_eligible := false; v_reason := 'out_of_radius';
    ELSIF rec.already_offered > 0 THEN
      v_eligible := false; v_reason := 'already_offered';
    END IF;

    -- componentes normalizados (0..1), iguais aos de dispatch.py
    v_f_eta    := 1.0 - LEAST(1.0, GREATEST(0.0, v_eta / NULLIF(v_eta_ref,0)));
    v_f_rating := CASE WHEN rec.rating_count < v_notes_min THEN 0.7
                       ELSE LEAST(1.0, GREATEST(0.0,
                              (rec.rating_avg - 3.5) / 1.5)) END;
    v_f_acc    := LEAST(1.0, GREATEST(0.0, rec.acceptance_rate));
    v_f_idle   := LEAST(1.0, GREATEST(0.0, v_idle / NULLIF(v_idle_cap,0)));
    v_f_exp    := 1.0 - LEAST(1.0, GREATEST(0.0, v_completed / NULLIF(v_newcomer,0)));
    -- Sem matriz de rota no servidor este componente é neutro (1.0). Ele passa
    -- a discriminar quando a distância RODOVIÁRIA por candidato for medida no
    -- servidor (OSRM/Valhalla), como o preço já faz para a rota do trecho.
    v_f_route  := 1.0;

    v_score := round(0.40 * v_f_eta + 0.20 * v_f_rating + 0.15 * v_f_acc
                   + 0.15 * v_f_idle + 0.05 * v_f_exp + 0.05 * v_f_route, 6);

    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'partner_id', rec.partner_id,
      'eligible', v_eligible,
      'reason', v_reason,
      'score', v_score,
      'distance_km', v_dist,
      'eta_min', v_eta,
      'idle_seconds', round(v_idle),
      'online_status', rec.online_status,
      'rating', rec.rating_avg,
      'rating_count', rec.rating_count,
      'acceptance_rate', rec.acceptance_rate,
      'completed_rides', v_completed,
      'vehicle', rec.fleet,
      'min_fare', rec.min_fare,
      'last_offer_at', rec.last_offer_at,
      'last_offer_status', rec.last_offer_status,
      'offers_count', rec.already_offered,
      'lat', rec.lat,
      'lon', rec.lon,
      'components', jsonb_build_object(
        'eta', round(v_f_eta,4), 'rating', round(v_f_rating,4),
        'acceptance', round(v_f_acc,4), 'idle', round(v_f_idle,4),
        'experience', round(v_f_exp,4), 'route', round(v_f_route,4))));
  END LOOP;

  -- Ordena por elegíveis, score, ociosidade (desempate de justiça), ETA e id
  -- estável — a mesma ordem do dispatch.py, para a tela não variar entre polls.
  SELECT COALESCE(jsonb_agg(e ORDER BY (e->>'eligible')::boolean DESC,
                                    (e->>'score')::numeric DESC,
                                    (e->>'idle_seconds')::numeric DESC,
                                    (e->>'eta_min')::numeric ASC,
                                    (e->>'partner_id') ASC), '[]'::jsonb)
    INTO v_out
    FROM jsonb_array_elements(v_out) AS e;
  RETURN v_out;
END $$;

-- Envia a próxima oferta. Três tentativas, na ordem:
--   1. o melhor elegível que AINDA NÃO recebeu esta corrida;
--   2. quem já recebeu, passado o cooldown da rodada (PRM-match.retry_s) e sem
--      ter sido o último a recusar agora;
--   3. liquidez: se existe UM único candidato elegível no raio, ele volta a
--      receber — sem isso, uma praça com um motorista só morreria a corrida
--      após a primeira recusa. A recusa continua pesando na taxa de aceite.
CREATE OR REPLACE FUNCTION fn_dispatch_next(p_ride uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  r rides%ROWTYPE; v_eval jsonb; v_pick jsonb; v_offers int; v_retry int;
  v_reason text := 'best_never_offered'; v_eligible int;
  v_off uuid; v_fare numeric; v_timeout timestamptz; v_rank int; v_pool int;
BEGIN
  SELECT * INTO r FROM rides WHERE id = p_ride FOR UPDATE;
  IF NOT FOUND OR r.status <> 'BUSCANDO' THEN
    RETURN jsonb_build_object('skipped', true, 'status', r.status);
  END IF;
  IF EXISTS (SELECT 1 FROM offers WHERE ride_id = p_ride AND status = 'SENT') THEN
    RETURN jsonb_build_object('skipped', true, 'reason', 'offer_live');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM partner_presence
                  WHERE online_status IN ('ONLINE_DISPONIVEL','OFERTA_PENDENTE')
                    AND last_position IS NOT NULL) THEN
    RETURN jsonb_build_object('skipped', true, 'reason', 'no_partner_online');
  END IF;

  v_eval := fn_dispatch_evaluate(p_ride);
  v_offers := (SELECT count(*) FROM offers WHERE ride_id = p_ride);
  v_retry := (city_param(r.city_id,'PRM-match.retry_s','20') #>> '{}')::int;

  SELECT e INTO v_pick
    FROM jsonb_array_elements(v_eval) AS e
   WHERE (e->>'eligible')::boolean
   ORDER BY (e->>'score')::numeric DESC, (e->>'idle_seconds')::numeric DESC
   LIMIT 1;

  IF v_pick IS NULL THEN
    -- 2) rodada seguinte: quem já recebeu, passado o cooldown, desde que não
    --    tenha recusado há menos que o cooldown.
    v_reason := 'retry_after_cooldown';
    SELECT e INTO v_pick
      FROM jsonb_array_elements(v_eval) AS e
     WHERE (e->>'reason') = 'already_offered'
       AND ((e->>'last_offer_at')::timestamptz IS NULL
            OR (e->>'last_offer_at')::timestamptz < now() - make_interval(secs => v_retry))
     ORDER BY (e->>'score')::numeric DESC, (e->>'offers_count')::int ASC
     LIMIT 1;
  END IF;

  IF v_pick IS NULL THEN
    -- 3) liquidez: um único candidato no raio volta a receber (o passageiro
    --    não fica preso por causa de um candidato só). Quem RECUSOU espera o
    --    cooldown como todo mundo: sem isso a mesma corrida voltaria na tela
    --    dele no instante seguinte, o que é o oposto de "vai para o próximo".
    SELECT count(*) INTO v_eligible FROM jsonb_array_elements(v_eval) AS e
     WHERE (e->>'eligible')::boolean OR (e->>'reason') = 'already_offered';
    IF v_eligible = 1 THEN
      SELECT e INTO v_pick FROM jsonb_array_elements(v_eval) AS e
       WHERE ((e->>'eligible')::boolean OR (e->>'reason') = 'already_offered')
         AND ((e->>'last_offer_status') IS DISTINCT FROM 'DECLINED'
              OR (e->>'last_offer_at')::timestamptz
                 < now() - make_interval(secs => v_retry))
       ORDER BY (e->>'score')::numeric DESC LIMIT 1;
      IF v_pick IS NOT NULL THEN
        v_reason := 'single_candidate_retry';
      END IF;
    END IF;
  END IF;

  IF v_pick IS NULL THEN
    RETURN jsonb_build_object('ride_id', p_ride, 'offered', false,
                              'reason', 'no_eligible_candidate',
                              'candidates', v_eval);
  END IF;

  v_fare := COALESCE(r.proposed_amount, (r.pricing->>'fare_total')::numeric, 0);
  v_off := fn_dispatch_offer(p_ride, (v_pick->>'partner_id')::uuid, v_fare);
  -- O parceiro escolhido fica "com oferta pendente"; sem isso ele apareceria
  -- livre para receber outra corrida enquanto esta ainda está na tela dele.
  UPDATE partner_presence SET online_status = 'OFERTA_PENDENTE', updated_at = now()
   WHERE partner_user_id = (v_pick->>'partner_id')::uuid;

  SELECT timeout_at INTO v_timeout FROM offers WHERE id = v_off;
  v_pool := jsonb_array_length(v_eval);
  SELECT ord INTO v_rank FROM (
    SELECT (e->>'partner_id') AS pid, row_number() OVER () AS ord
      FROM jsonb_array_elements(v_eval) AS e) t
   WHERE pid = v_pick->>'partner_id';

  RETURN jsonb_build_object(
    'ride_id', p_ride, 'offered', true, 'offer_id', v_off,
    'partner_user_id', (v_pick->>'partner_id')::uuid,
    'amount', v_fare, 'timeout_at', v_timeout, 'selection', v_reason,
    'dispatch', jsonb_build_object(
      'rank', v_rank, 'pool', v_pool,
      'score', (v_pick->>'score')::numeric,
      'components', v_pick->'components',
      'distance_km', (v_pick->>'distance_km')::numeric,
      'eta_min', (v_pick->>'eta_min')::numeric,
      'idle_seconds', (v_pick->>'idle_seconds')::numeric,
      'rating', (v_pick->>'rating')::numeric,
      'rating_count', (v_pick->>'rating_count')::int,
      'acceptance_rate', (v_pick->>'acceptance_rate')::numeric,
      'vehicle', v_pick->>'vehicle'));
END $$;

-- Recusa do parceiro: a oferta fecha, a taxa de aceite cai e a corrida segue
-- para o PRÓXIMO da lista (nunca para o mesmo).
CREATE OR REPLACE FUNCTION fn_offer_decline(p_offer uuid, p_partner uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE o offers%ROWTYPE; v_next jsonb;
BEGIN
  SELECT * INTO o FROM offers WHERE id = p_offer FOR UPDATE;
  IF NOT FOUND OR o.partner_user_id <> p_partner THEN
    RAISE EXCEPTION 'offer_not_found' USING ERRCODE = 'P0002';
  END IF;
  IF o.status <> 'SENT' THEN
    RETURN jsonb_build_object('declined', false, 'status', o.status);
  END IF;
  UPDATE offers SET status = 'DECLINED', responded_at = now() WHERE id = p_offer;
  PERFORM fn_emit_event(o.ride_id, 'offer.declined', NULL, p_partner, 'decline:' || p_offer);
  PERFORM fn_partner_acceptance_recalc(p_partner);
  UPDATE partner_presence SET online_status = 'ONLINE_DISPONIVEL', updated_at = now()
   WHERE partner_user_id = p_partner AND online_status = 'OFERTA_PENDENTE';
  IF NOT EXISTS (SELECT 1 FROM offers WHERE ride_id = o.ride_id AND status = 'SENT') THEN
    UPDATE rides SET status = 'BUSCANDO' WHERE id = o.ride_id AND status = 'OFERTADA';
  END IF;
  v_next := fn_dispatch_next(o.ride_id);
  RETURN jsonb_build_object('declined', true, 'next', v_next);
END $$;

-- -----------------------------------------------------------------------------
-- 4. RELÓGIO DO SERVIDOR — timeout de oferta, reoferta e corrida sem aceite.
--
-- A demo fazia isso de forma preguiçosa ("qualquer request avança o relógio").
-- Aqui a regra fica explícita e idempotente: pode ser chamada por qualquer
-- operação do ciclo e por um agendador (pg_cron em produção).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_dispatch_tick()
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  rec record; v_expired int := 0; v_offered int := 0; v_stale int := 0;
  v_res jsonb;
BEGIN
  -- 4.1 ofertas vencidas (o relógio da oferta é do servidor)
  FOR rec IN SELECT id, partner_user_id, ride_id FROM offers
              WHERE status = 'SENT' AND timeout_at < now() LOOP
    PERFORM fn_offer_expire(rec.id);
    PERFORM fn_partner_acceptance_recalc(rec.partner_user_id);
    UPDATE partner_presence SET online_status = 'ONLINE_DISPONIVEL', updated_at = now()
     WHERE partner_user_id = rec.partner_user_id AND online_status = 'OFERTA_PENDENTE';
    v_expired := v_expired + 1;
  END LOOP;

  -- 4.2 corrida buscando sem oferta viva: manda para o próximo candidato
  FOR rec IN
    SELECT r.id, r.city_id FROM rides r
     WHERE r.status = 'BUSCANDO'
       AND NOT EXISTS (SELECT 1 FROM offers o WHERE o.ride_id = r.id AND o.status = 'SENT')
     ORDER BY r.requested_at
     LIMIT 50
  LOOP
    v_res := fn_dispatch_next(rec.id);
    IF COALESCE((v_res->>'offered')::boolean, false) THEN
      v_offered := v_offered + 1;
    END IF;
  END LOOP;

  -- 4.3 ninguém aceitou dentro da janela: a corrida expira (o passageiro é
  -- avisado pelo status, não por silêncio na tela)
  FOR rec IN
    SELECT r.id, r.city_id FROM rides r
     WHERE r.status IN ('BUSCANDO','OFERTADA')
       AND r.requested_at < now() - make_interval(secs =>
             (city_param(r.city_id,'PRM-corrida.busca_max_s','600') #>> '{}')::int)
     LIMIT 50
  LOOP
    UPDATE rides SET status = 'EXPIRADA' WHERE id = rec.id
      AND status IN ('BUSCANDO','OFERTADA');
    UPDATE offers SET status = 'EXPIRED', responded_at = now()
     WHERE ride_id = rec.id AND status = 'SENT';
    UPDATE partner_presence SET online_status = 'ONLINE_DISPONIVEL', updated_at = now()
     WHERE partner_user_id IN (SELECT partner_user_id FROM offers WHERE ride_id = rec.id)
       AND online_status = 'OFERTA_PENDENTE';
    PERFORM fn_emit_event(rec.id, 'ride.expired', NULL, NULL, 'expired:' || rec.id);
    v_stale := v_stale + 1;
  END LOOP;

  RETURN jsonb_build_object('offers_expired', v_expired,
                            'offers_sent', v_offered,
                            'rides_expired', v_stale);
END $$;

-- -----------------------------------------------------------------------------
-- 5. API DO CICLO — o ator vem SEMPRE de app_uid().
-- -----------------------------------------------------------------------------

-- 5.0 cidade do chamador: a do parceiro, quando houver; senão a praça piloto.
CREATE OR REPLACE FUNCTION fn_city_for_caller() RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT COALESCE(
    (SELECT city_id FROM partners WHERE user_id = app_uid() AND deleted_at IS NULL),
    (SELECT id FROM cities WHERE status = 'PILOT' ORDER BY name LIMIT 1),
    (SELECT id FROM cities ORDER BY name LIMIT 1));
$$;

CREATE OR REPLACE FUNCTION fn_geog(p_lat double precision, p_lon double precision)
RETURNS geography LANGUAGE sql IMMUTABLE AS $$
  SELECT ST_SetSRID(ST_MakePoint(p_lon, p_lat), 4326)::geography;
$$;

CREATE OR REPLACE FUNCTION api_quote(p_origin jsonb, p_destination jsonb)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF app_uid() IS NULL THEN
    RAISE EXCEPTION 'not_authenticated' USING ERRCODE = '28000';
  END IF;
  RETURN fn_quote(fn_city_for_caller(),
                  fn_geog((p_origin->>'lat')::float8, (p_origin->>'lon')::float8),
                  fn_geog((p_destination->>'lat')::float8, (p_destination->>'lon')::float8));
END $$;

-- 5.1 pedir corrida: o preço é RECALCULADO no servidor (o valor que o app
-- mostrou é registrado só para auditoria — o cliente não escolhe preço), o
-- passageiro é app_uid() e o despacho já sai na mesma chamada.
CREATE OR REPLACE FUNCTION api_ride_request(
  p_origin jsonb, p_destination jsonb,
  p_origin_address text DEFAULT NULL,
  p_destination_address text DEFAULT NULL,
  p_proposed numeric DEFAULT NULL,
  p_client_quoted numeric DEFAULT NULL,
  p_city uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_uid uuid := app_uid(); v_city uuid; v_quote jsonb; v_rid uuid; v_pricing jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated' USING ERRCODE = '28000';
  END IF;
  IF p_origin->>'lat' IS NULL OR p_destination->>'lat' IS NULL THEN
    RAISE EXCEPTION 'invalid_points' USING ERRCODE = '22023';
  END IF;
  v_city := COALESCE(p_city, fn_city_for_caller());
  PERFORM fn_dispatch_tick();

  v_quote := fn_quote(v_city,
                fn_geog((p_origin->>'lat')::float8, (p_origin->>'lon')::float8),
                fn_geog((p_destination->>'lat')::float8, (p_destination->>'lon')::float8));

  v_pricing := (v_quote->'pricing')
             || jsonb_build_object('fare_total', (v_quote->>'fare_total')::numeric,
                                   'quoted_at', now())
             || CASE WHEN p_client_quoted IS NOT NULL
                     THEN jsonb_build_object('client_quoted', p_client_quoted)
                     ELSE '{}'::jsonb END;

  v_rid := fn_ride_request(
      v_uid, v_city,
      fn_geog((p_origin->>'lat')::float8, (p_origin->>'lon')::float8),
      fn_geog((p_destination->>'lat')::float8, (p_destination->>'lon')::float8),
      v_pricing, p_proposed);

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

-- 5.2 corrida por id (só participante ou agente)
CREATE OR REPLACE FUNCTION api_ride_get(p_ride uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  r rides%ROWTYPE; v_uid uuid := app_uid(); v_out jsonb; v_pos jsonb;
  v_speed numeric; v_name text; v_rating numeric; v_vehicle text;
  v_pos_geog geography; v_remaining numeric; v_eta int;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated' USING ERRCODE = '28000';
  END IF;
  PERFORM fn_dispatch_tick();
  SELECT * INTO r FROM rides WHERE id = p_ride;
  IF NOT FOUND
     OR (r.passenger_user_id <> v_uid AND r.partner_user_id IS DISTINCT FROM v_uid
         AND NOT app_is_agent()) THEN
    RAISE EXCEPTION 'ride_not_found' USING ERRCODE = 'P0002';   -- não vaza existência
  END IF;

  v_out := jsonb_build_object(
    'ride_id', r.id, 'status', r.status,
    'pricing_mode', r.pricing_mode_snapshot,
    'fare_total', r.fare_total,
    'proposed_amount', r.proposed_amount,
    'distance_km', r.distance_km,
    'origin', jsonb_build_object('lat', ST_Y(r.origin::geometry),
                                 'lon', ST_X(r.origin::geometry)),
    'destination', jsonb_build_object('lat', ST_Y(r.destination::geometry),
                                      'lon', ST_X(r.destination::geometry)),
    'origin_address', r.origin_address,
    'destination_address', r.destination_address,
    'payment_status', r.payment_status,
    'created_at', r.created_at, 'accepted_at', r.accepted_at,
    'finished_at', r.finished_at, 'cancelled_at', r.cancelled_at,
    'price_multiplier', round(
      COALESCE((r.pricing->>'demand')::numeric, 1.0)
      * COALESCE((r.pricing->>'rush')::numeric, 1.0), 2));

  IF r.partner_user_id IS NOT NULL THEN
    SELECT full_name INTO v_name FROM profiles WHERE user_id = r.partner_user_id;
    SELECT round(avg(stars)::numeric, 2), COALESCE((SELECT string_agg(DISTINCT brand || ' ' || model, ', ')
              FROM vehicles WHERE partner_user_id = r.partner_user_id AND active), '')
      INTO v_rating, v_vehicle
      FROM ratings WHERE rated_user_id = r.partner_user_id;
    v_out := v_out || jsonb_build_object('partner', jsonb_build_object(
      'name', COALESCE(v_name, 'Parceiro'), 'rating', v_rating,
      'vehicle', NULLIF(v_vehicle, '')));
  END IF;

  -- posição do parceiro (o passageiro acompanha a aproximação no mapa)
  SELECT last_position INTO v_pos_geog FROM partner_presence
   WHERE partner_user_id = r.partner_user_id;
  IF v_pos_geog IS NOT NULL
     AND r.status IN ('ACEITA','A_CAMINHO','CHEGOU','EM_VIAGEM') THEN
    v_speed := (city_param(r.city_id,'PRM-despacho.velocidade_viagem','30') #>> '{}')::numeric;
    v_remaining := round((ST_Distance(v_pos_geog,
        CASE WHEN r.status IN ('ACEITA','A_CAMINHO','CHEGOU')
             THEN r.origin ELSE r.destination END) / 1000.0)::numeric, 2);
    v_eta := CASE WHEN v_speed > 0 THEN round(v_remaining / v_speed * 3600)::int ELSE NULL END;
    v_pos := jsonb_build_object(
      'lat', ST_Y(v_pos_geog::geometry), 'lon', ST_X(v_pos_geog::geometry));
    v_out := v_out || jsonb_build_object('partner_position', v_pos,
                                        'partner_remaining_km', v_remaining,
                                        'eta_seconds', v_eta);
  END IF;
  RETURN v_out;
END $$;

-- 5.3 minhas corridas. `active=1` devolve as abertas. O filtro é pelo token:
-- era exatamente aqui que a demo mostrava corrida de outro passageiro.
CREATE OR REPLACE FUNCTION api_rides_mine(p_active boolean DEFAULT false)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_uid uuid := app_uid(); v_out jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated' USING ERRCODE = '28000';
  END IF;
  PERFORM fn_dispatch_tick();
  SELECT COALESCE(jsonb_agg(x.ride ORDER BY x.created_at DESC), '[]'::jsonb)
    INTO v_out
    FROM (
      SELECT r.created_at, api_ride_get(r.id) AS ride
        FROM rides r
       WHERE (r.passenger_user_id = v_uid OR r.partner_user_id = v_uid)
         AND (NOT p_active OR r.status IN ('CRIADA','BUSCANDO','OFERTADA','ACEITA',
                                           'A_CAMINHO','CHEGOU','EM_VIAGEM'))
       ORDER BY r.created_at DESC
       LIMIT 20
    ) x;
  RETURN jsonb_build_object('rides', v_out);
END $$;

CREATE OR REPLACE FUNCTION api_ride_cancel(p_ride uuid, p_reason text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_uid uuid := app_uid(); r rides%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated' USING ERRCODE = '28000';
  END IF;
  SELECT * INTO r FROM rides WHERE id = p_ride;
  -- Mesma resposta para "não é sua" e "não existe": ninguém usa o erro para
  -- descobrir quais ids de corrida existem.
  IF NOT FOUND
     OR (r.passenger_user_id <> v_uid AND r.partner_user_id IS DISTINCT FROM v_uid
         AND NOT app_is_agent()) THEN
    RAISE EXCEPTION 'ride_not_found' USING ERRCODE = 'P0002';
  END IF;
  PERFORM fn_ride_cancel(p_ride, v_uid, p_reason);   -- a função valida o ator
  UPDATE offers SET status = 'REASSIGNED', responded_at = now()
   WHERE ride_id = p_ride AND status = 'SENT';
  UPDATE partner_presence SET online_status = 'ONLINE_DISPONIVEL',
         idle_since = now(), updated_at = now()
   WHERE partner_user_id = r.partner_user_id AND online_status IN ('OFERTA_PENDENTE','EM_CORRIDA');
  RETURN api_ride_get(p_ride);
END $$;

-- 5.4 exposição do despacho (justificativa por candidato) — só participante
CREATE OR REPLACE FUNCTION api_ride_dispatch(p_ride uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE r rides%ROWTYPE; v_uid uuid := app_uid(); v_eval jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated' USING ERRCODE = '28000';
  END IF;
  SELECT * INTO r FROM rides WHERE id = p_ride;
  IF NOT FOUND
     OR (r.passenger_user_id <> v_uid AND r.partner_user_id IS DISTINCT FROM v_uid
         AND NOT app_is_agent()) THEN
    RAISE EXCEPTION 'ride_not_found' USING ERRCODE = 'P0002';
  END IF;
  v_eval := fn_dispatch_evaluate(p_ride);
  RETURN jsonb_build_object(
    'ride_id', r.id, 'status', r.status,
    'offers_sent', (SELECT count(*) FROM offers WHERE ride_id = p_ride),
    'fare', COALESCE(r.proposed_amount, (r.pricing->>'fare_total')::numeric),
    'service', (SELECT st.code FROM service_types st WHERE st.id = r.service_type_id),
    'candidates', v_eval);
END $$;

-- 5.5 oferta como o parceiro vê, com o PORQUÊ de ter sido escolhido
CREATE OR REPLACE FUNCTION api_offers_mine()
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_uid uuid := app_uid(); v_out jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated' USING ERRCODE = '28000';
  END IF;
  PERFORM fn_dispatch_tick();
  SELECT COALESCE(jsonb_agg(o.view ORDER BY o.sent_at), '[]'::jsonb) INTO v_out
    FROM (
      SELECT of.sent_at, api_offer_get(of.id) AS view
        FROM offers of
       WHERE of.partner_user_id = v_uid AND of.status = 'SENT' AND of.timeout_at > now()
       ORDER BY of.sent_at LIMIT 20
    ) o;
  RETURN jsonb_build_object('offers', v_out);
END $$;

CREATE OR REPLACE FUNCTION api_offer_get(p_offer uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  o offers%ROWTYPE; r rides%ROWTYPE; v_uid uuid := app_uid();
  v_eval jsonb; v_me jsonb; v_rank int; v_pool int;
  v_speed numeric; v_trip_min int; v_name text; v_p_rating numeric; v_area text;
  v_parts text[];
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated' USING ERRCODE = '28000';
  END IF;
  SELECT * INTO o FROM offers WHERE id = p_offer;
  IF NOT FOUND OR (o.partner_user_id <> v_uid AND NOT app_is_agent()) THEN
    RAISE EXCEPTION 'offer_not_found' USING ERRCODE = 'P0002';
  END IF;
  SELECT * INTO r FROM rides WHERE id = o.ride_id;

  v_eval := fn_dispatch_evaluate(o.ride_id);
  v_pool := jsonb_array_length(v_eval);
  SELECT e, t.ord INTO v_me, v_rank
    FROM jsonb_array_elements(v_eval) WITH ORDINALITY AS t(e, ord)
   WHERE e->>'partner_id' = o.partner_user_id::text;
  -- O parceiro pode ter saído do conjunto (ficou offline) entre a oferta e a
  -- leitura: a oferta continua válida até o timeout, e a tela explica isso.
  IF v_me IS NULL THEN
    v_me := jsonb_build_object('eligible', false, 'reason', 'not_available',
                              'components', '{}'::jsonb);
  END IF;

  v_speed := (city_param(r.city_id,'PRM-despacho.velocidade_viagem','30') #>> '{}')::numeric;
  v_trip_min := CASE WHEN v_speed > 0 AND r.distance_km IS NOT NULL
                     THEN round(r.distance_km / v_speed * 60.0)::int ELSE NULL END;

  SELECT full_name INTO v_name FROM profiles WHERE user_id = r.passenger_user_id;
  SELECT round(avg(stars)::numeric, 2) INTO v_p_rating
    FROM ratings WHERE rated_user_id = r.passenger_user_id;
  -- Privacidade: o parceiro vê a ÁREA do destino (bairro), não o endereço com
  -- número antes do aceite. "Rua da Beira, 500 - Embratel, Porto Velho" vira
  -- "Embratel". Sem bairro reconhecível, cai na coordenada arredondada.
  v_parts := string_to_array(COALESCE(r.destination_address, ''), ',');
  IF array_length(v_parts, 1) >= 2 THEN
    v_area := NULLIF(trim(regexp_replace(
                trim(v_parts[array_length(v_parts, 1) - 1]),
                '^\d+\s*-\s*', '')), '');
  ELSE
    v_area := NULLIF(trim(COALESCE(r.destination_address, '')), '');
  END IF;
  IF v_area IS NULL THEN
    v_area := 'zona ' || round(ST_Y(r.destination::geometry)::numeric, 2) || ', '
                       || round(ST_X(r.destination::geometry)::numeric, 2);
  END IF;

  RETURN jsonb_build_object(
    'offer_id', o.id, 'ride_id', o.ride_id,
    'amount', o.offered_amount,
    'status', o.status,
    'pickup_distance_km', (v_me->>'distance_km')::numeric,
    'pickup_eta_min', (v_me->>'eta_min')::numeric,
    'trip_distance_km', r.distance_km,
    'trip_duration_min', v_trip_min,
    'destination_area', v_area,
    'service', (SELECT st.code FROM service_types st WHERE st.id = r.service_type_id),
    'price_multiplier', CASE WHEN r.proposed_amount IS NOT NULL THEN NULL ELSE
      round(COALESCE((r.pricing->>'demand')::numeric,1.0)
            * COALESCE((r.pricing->>'rush')::numeric,1.0), 2) END,
    'origin', jsonb_build_object('lat', ST_Y(r.origin::geometry), 'lon', ST_X(r.origin::geometry)),
    'destination', jsonb_build_object('lat', ST_Y(r.destination::geometry),
                                      'lon', ST_X(r.destination::geometry)),
    'passenger_name', COALESCE(v_name, 'Passageiro'),
    'passenger_rating', v_p_rating,
    'timeout_at', o.timeout_at, 'sent_at', o.sent_at,
    'dispatch', jsonb_build_object(
      'rank', v_rank, 'pool', v_pool,
      'score', (v_me->>'score')::numeric,
      'components', v_me->'components',
      'online_seconds', COALESCE(
        (SELECT EXTRACT(epoch FROM now() - idle_since)::bigint
           FROM partner_presence WHERE partner_user_id = o.partner_user_id), 0),
      'rating', (v_me->>'rating')::numeric,
      'rating_count', (v_me->>'rating_count')::int,
      'acceptance_rate', (v_me->>'acceptance_rate')::numeric,
      'vehicle', v_me->>'vehicle',
      'eligible', (v_me->>'eligible')::boolean,
      'reason', v_me->>'reason'));
END $$;

CREATE OR REPLACE FUNCTION api_offer_accept(p_offer uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_uid uuid := app_uid(); v_ride uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated' USING ERRCODE = '28000';
  END IF;
  v_ride := fn_offer_accept(p_offer, v_uid);        -- valida dono e timeout
  PERFORM fn_partner_acceptance_recalc(v_uid);
  UPDATE partner_presence SET online_status = 'EM_CORRIDA', idle_since = NULL,
         updated_at = now()
   WHERE partner_user_id = v_uid;
  UPDATE offers SET status = 'REASSIGNED', responded_at = now()
   WHERE ride_id = v_ride AND status = 'SENT' AND id <> p_offer;
  RETURN api_ride_get(v_ride);
END $$;

CREATE OR REPLACE FUNCTION api_offer_decline(p_offer uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF app_uid() IS NULL THEN
    RAISE EXCEPTION 'not_authenticated' USING ERRCODE = '28000';
  END IF;
  RETURN fn_offer_decline(p_offer, app_uid());
END $$;

-- 5.6 fases da corrida (o parceiro da corrida, sempre pelo token)
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

-- 5.7 pagamento da corrida: quem paga é o passageiro do token
CREATE OR REPLACE FUNCTION api_payment_intent(
  p_ride uuid, p_method text DEFAULT 'PIX'
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_uid uuid := app_uid(); r rides%ROWTYPE; v_id uuid; v_exp int; v_amount numeric;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated' USING ERRCODE = '28000';
  END IF;
  IF p_method NOT IN ('PIX','CARD','CASH') THEN
    RAISE EXCEPTION 'invalid_method' USING ERRCODE = '22023';
  END IF;
  SELECT * INTO r FROM rides WHERE id = p_ride;
  IF NOT FOUND OR r.passenger_user_id <> v_uid THEN
    RAISE EXCEPTION 'ride_not_found' USING ERRCODE = 'P0002';
  END IF;
  IF r.status <> 'FINALIZADA' THEN
    RAISE EXCEPTION 'ride_not_finished' USING ERRCODE = '40900';
  END IF;
  IF r.payment_status = 'CONFIRMED' THEN
    RAISE EXCEPTION 'already_paid' USING ERRCODE = '40900';
  END IF;

  -- idempotência real: uma cobrança pendente por corrida/método (o "Já paguei"
  -- do app pode ser tocado duas vezes, o webhook pode ser reentregue)
  SELECT id INTO v_id FROM payments
   WHERE ride_id = p_ride AND method = p_method AND status = 'PENDING';
  IF v_id IS NULL THEN
    v_amount := COALESCE(r.fare_total, 0);
    IF v_amount <= 0 THEN
      RAISE EXCEPTION 'invalid_amount' USING ERRCODE = '22023';
    END IF;
    v_exp := (city_param(r.city_id,'PRM-pagamento.validade_s','900') #>> '{}')::int;
    INSERT INTO payments (ride_id, payer_user_id, method, amount, status,
                          psp_provider, idempotency_key, expires_at)
    VALUES (p_ride, v_uid, p_method, v_amount, 'PENDING',
            CASE WHEN p_method = 'CASH' THEN 'cash' ELSE 'dev_pix' END,
            'ride:' || p_ride || ':' || p_method, now() + make_interval(secs => v_exp))
    RETURNING id INTO v_id;
  END IF;

  RETURN jsonb_build_object(
    'payment_id', v_id, 'ride_id', p_ride, 'method', p_method,
    'amount', (SELECT amount FROM payments WHERE id = v_id),
    'status', (SELECT status FROM payments WHERE id = v_id),
    'expires_at', (SELECT expires_at FROM payments WHERE id = v_id),
    -- O QR/copia-e-cola é do PSP. Enquanto não há PSP contratado (ADR-005), o
    -- provedor é declarado como `dev_pix`: NENHUM caminho daqui confirma o
    -- pagamento — a confirmação é o webhook do PSP (fn_payment_confirm_ride).
    'psp_provider', (SELECT psp_provider FROM payments WHERE id = v_id));
END $$;

CREATE OR REPLACE FUNCTION api_payment_get(p_payment uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE p payments%ROWTYPE; v_uid uuid := app_uid(); r rides%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated' USING ERRCODE = '28000';
  END IF;
  SELECT * INTO p FROM payments WHERE id = p_payment;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'payment_not_found' USING ERRCODE = 'P0002';
  END IF;
  SELECT * INTO r FROM rides WHERE id = p.ride_id;
  IF p.payer_user_id <> v_uid AND r.partner_user_id IS DISTINCT FROM v_uid
     AND NOT app_is_agent() THEN
    RAISE EXCEPTION 'payment_not_found' USING ERRCODE = 'P0002';
  END IF;
  RETURN jsonb_build_object(
    'payment_id', p.id, 'ride_id', p.ride_id, 'method', p.method,
    'amount', p.amount, 'status', p.status, 'confirmed_at', p.confirmed_at,
    'expires_at', p.expires_at, 'psp_provider', p.psp_provider,
    'ride_payment_status', r.payment_status);
END $$;

-- 5.7b pagamento da corrida por corrida (o app só tem o ride_id). Escopado ao
-- participante: passageiro pagador ou parceiro da corrida.
CREATE OR REPLACE FUNCTION api_payment_get_by_ride(p_ride uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE r rides%ROWTYPE; p payments%ROWTYPE; v_uid uuid := app_uid();
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated' USING ERRCODE = '28000';
  END IF;
  SELECT * INTO r FROM rides WHERE id = p_ride;
  IF NOT FOUND
     OR (r.passenger_user_id <> v_uid AND r.partner_user_id IS DISTINCT FROM v_uid
         AND NOT app_is_agent()) THEN
    RAISE EXCEPTION 'ride_not_found' USING ERRCODE = 'P0002';
  END IF;
  SELECT * INTO p FROM payments WHERE ride_id = p_ride
   ORDER BY created_at DESC LIMIT 1;
  IF p.id IS NULL THEN
    RETURN jsonb_build_object('ride_id', p_ride, 'payment_id', NULL,
                              'status', NULL, 'ride_payment_status', r.payment_status);
  END IF;
  RETURN jsonb_build_object(
    'payment_id', p.id, 'ride_id', p_ride, 'method', p.method,
    'amount', p.amount, 'status', p.status, 'confirmed_at', p.confirmed_at,
    'expires_at', p.expires_at, 'psp_provider', p.psp_provider,
    'ride_payment_status', r.payment_status);
END $$;

-- 5.8 dinheiro em espécie declarado pelo parceiro (ADR-003): cria a cobrança e
-- fecha pelo MESMO caminho do PSP (fn_payment_confirm_ride), que é quem lança
-- comissão em débito na carteira do parceiro.
CREATE OR REPLACE FUNCTION api_ride_cash_declare(p_ride uuid, p_amount numeric)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_uid uuid := app_uid(); r rides%ROWTYPE; v_pay uuid; v_status text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated' USING ERRCODE = '28000';
  END IF;
  SELECT * INTO r FROM rides WHERE id = p_ride;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ride_not_found' USING ERRCODE = 'P0002';
  END IF;
  IF r.partner_user_id IS DISTINCT FROM v_uid AND NOT app_is_agent() THEN
    RAISE EXCEPTION 'not_your_ride' USING ERRCODE = '42501';
  END IF;
  IF r.status <> 'FINALIZADA' THEN
    RAISE EXCEPTION 'ride_not_finished' USING ERRCODE = '40900';
  END IF;
  SELECT id, status INTO v_pay, v_status
    FROM payments WHERE ride_id = p_ride AND method = 'CASH' LIMIT 1;
  IF v_pay IS NULL THEN
    INSERT INTO payments (ride_id, payer_user_id, method, amount, status,
                          psp_provider, idempotency_key)
    VALUES (p_ride, r.passenger_user_id, 'CASH', COALESCE(p_amount, r.fare_total),
            'PENDING', 'cash', 'cash:' || p_ride)
    RETURNING id INTO v_pay;
    v_status := 'PENDING';
  END IF;
  -- Confirma pelo MESMO caminho do PSP (idempotente: reentrega não duplica).
  IF v_status <> 'CONFIRMED' THEN
    PERFORM fn_payment_confirm_ride(v_pay, 'CASH_DECLARED');
  END IF;
  RETURN v_pay;
END $$;

-- -----------------------------------------------------------------------------
-- 5.9 Idempotência: a tabela `idempotency_keys` é escrita pelo próprio dono
-- (RLS `p_idem_self`), então `authenticated` precisa do GRANT — sem ele o
-- PostgREST recusa em silêncio e um replay de POST /rides virava
-- "active_ride_exists" em vez de devolver a corrida original.
-- -----------------------------------------------------------------------------
GRANT SELECT, INSERT, UPDATE ON idempotency_keys TO authenticated;

-- -----------------------------------------------------------------------------
-- 6. GRANTS — só `authenticated` chama a API do ciclo; `anon` não entra.
--    (`anon` existe no Supabase; em Postgres puro ele nasce aqui, como já
--    acontece com `authenticated` na migração 0002.)
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'anon') THEN
    CREATE ROLE anon NOLOGIN;
  END IF;
END $$;

--    (As checagens de dono estão DENTRO de cada função, porque SECURITY
--    DEFINER ignora RLS: o token define o ator, o corpo não define nada.)
-- -----------------------------------------------------------------------------
DO $$
DECLARE f record;
BEGIN
  FOR f IN
    SELECT p.oid::regprocedure AS sig
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname IN ('fn_quote','fn_dispatch_evaluate','fn_dispatch_next',
                         'fn_dispatch_tick','fn_offer_decline','fn_partner_acceptance_recalc',
                         'fn_city_for_caller','fn_geog','api_quote','api_ride_request',
                         'api_ride_get','api_rides_mine','api_ride_cancel',
                         'api_ride_dispatch','api_offers_mine','api_offer_get',
                         'api_offer_accept','api_offer_decline','api_ride_transition',
                         'api_payment_intent','api_payment_get','api_payment_get_by_ride',
                         'api_ride_cash_declare')
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon', f.sig);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated, service_role', f.sig);
  END LOOP;
END $$;
