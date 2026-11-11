-- =============================================================================
-- 10 é + — a janela da oferta volta ao contrato (PRM-oferta.timeout = 15 s)
--
-- O QUE ACONTECEU
-- ---------------
-- A janela de resposta da oferta (`offers.timeout_at`) sai de
-- `city_param(city_id, 'PRM-oferta.timeout', '15')`. O padrão da função e o
-- contrato (SPECS §1.1, `supabase/seed.sql`, `scripts/demo_api.py`) dizem
-- **15 s**.
--
-- No banco local, porém, a cidade piloto (Porto Velho) tinha a config
-- gravada com **60 s** — um desvio de uma seeding antiga (25/10/2026), que
-- o `WHERE NOT EXISTS` do seed nunca reconciliou (o seed só insere o que
-- falta). Resultado: o produto real esperava 4× mais por um motorista que
-- talvez nunca visse a oferta, enquanto a API de demonstração e o SPEC
-- diziam 15 s. Divergência de contrato é bug: passageiro esperando mais,
-- motorista com a oferta "quente" por mais tempo, e o E2E real "passando"
-- só porque a janela estava inflada (o harness levou 43 s para responder).
--
-- O QUE ESTA MIGRATION FAZ
-- -----------------------
-- 1. Corrige a config da cidade piloto para o valor do contrato (15 s).
-- 2. **Impede a repetição**: passa a recusar, no próprio banco, uma config
--    de janela da oferta fora do contrato. Uma praça nova pode ter o seu
--    valor — mas só dentro da faixa combinada (10 s a 60 s); fora dela a
--    config é rejeitada na hora, e não dias depois em produção.
--
-- A migration é segura num banco novo: a cidade piloto nasce no seed, então
-- o UPDATE abaixo não encontra linha (0 linhas alteradas) e o `city_param`
-- cai no padrão de 15 s da própria função.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Corrige o valor divergente da cidade piloto
-- -----------------------------------------------------------------------------

UPDATE city_configs cc
   SET param_value = to_jsonb(15::int)
  FROM cities c
 WHERE cc.city_id = c.id
   AND c.status = 'PILOT'
   AND cc.param_key = 'PRM-oferta.timeout'
   AND cc.param_value IS DISTINCT FROM to_jsonb(15::int);

-- -----------------------------------------------------------------------------
-- 2. Trava a janela da oferta no contrato
-- -----------------------------------------------------------------------------
-- Por que a trava no BANCO e não só no SPEC: `city_configs` é a única
-- fonte de verdade em tempo de execução — o valor do SPEC só entra no
-- caminho se ninguém mexer na config. A trava faz o desvio falhar no
-- instante em que alguém tenta gravar (e a mensagem diz o contrato), em
-- vez de aparecer semanas depois como "o passageiro espera demais".
--
-- Duas regras:
--   * cidade PILOT (a que vai ao ar): exatamente o valor do contrato (15 s);
--   * qualquer outra praça: dentro da faixa combinada (10 s a 60 s) — a
--     janela é um parâmetro por cidade, mas não pode ser absurda.

CREATE OR REPLACE FUNCTION public.fn_city_config_check_window()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_segundos int;
  v_min int := 10;
  v_max int := 60;
  v_contrato int := 15;
  v_pilot boolean := false;
BEGIN
  IF NEW.param_key <> 'PRM-oferta.timeout' THEN
    RETURN NEW;
  END IF;

  BEGIN
    v_segundos := (NEW.param_value #>> '{}')::int;
  EXCEPTION WHEN others THEN
    RAISE EXCEPTION
      'PRM-oferta.timeout precisa ser um número inteiro de segundos (recebido: %)',
      NEW.param_value;
  END;

  SELECT EXISTS (SELECT 1 FROM cities c
                  WHERE c.id = NEW.city_id AND c.status = 'PILOT')
    INTO v_pilot;

  IF v_pilot AND v_segundos <> v_contrato THEN
    RAISE EXCEPTION
      'PRM-oferta.timeout da cidade piloto é %s s (SPECS §1.1); recebido: %s s',
      v_contrato, v_segundos;
  END IF;

  IF v_segundos < v_min OR v_segundos > v_max THEN
    RAISE EXCEPTION
      'PRM-oferta.timeout fora da faixa do contrato: %s (aceito: %s..%s s)',
      v_segundos, v_min, v_max;
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.fn_city_config_check_window() IS
  'Trava a janela da oferta no contrato (cidade piloto: 15 s; outras praças: '
  '10..60 s — SPECS §1.1). Sem isso, uma config divergente mudava o tempo de '
  'espera do passageiro sem deixar rastro no código.';

DROP TRIGGER IF EXISTS trg_city_config_window ON city_configs;

CREATE TRIGGER trg_city_config_window
  BEFORE INSERT OR UPDATE ON city_configs
  FOR EACH ROW EXECUTE FUNCTION public.fn_city_config_check_window();
