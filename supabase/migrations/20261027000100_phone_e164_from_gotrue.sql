-- =============================================================================
-- 10 é + — phone_e164 a partir do telefone do GoTrue
--
-- O GoTrue guarda o telefone do usuário como SÓ DÍGITOS (`5569900000001`), sem
-- o `+` — é o formato que o próprio Supabase usa nos números de teste. O
-- produto, porém, definiu `users.phone_e164` como E.164 com o `+` inicial
-- (`^\+[1-9]\d{6,14}$`, Fase 2). O vínculo auth.users → users copiava o valor
-- cru e o cadastro por telefone morria na constraint:
--
--   23514 new row for relation "users" violates check constraint
--         "users_phone_e164_check"
--
-- Aqui a normalização passa a acontecer na entrada: o trigger acrescenta o `+`
-- que o GoTrue omite, e as linhas já gravadas são corrigidas. Nenhuma
-- identidade muda de dono — só a forma do mesmo número.
-- =============================================================================

-- --- trigger: normaliza o telefone ao criar/atualizar a conta ----------------
CREATE OR REPLACE FUNCTION fn_sync_auth_user() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_role text := upper(coalesce(new.raw_user_meta_data ->> 'role', 'PASSENGER'));
  v_name text := coalesce(
    nullif(btrim(new.raw_user_meta_data ->> 'full_name'), ''),
    nullif(split_part(coalesce(new.email, ''), '@', 1), ''),
    'Usuário 10 é +'
  );
  v_digits text;
  v_phone  text;
  v_city uuid;
BEGIN
  -- Papel só entre os dois que o app cria; qualquer outra coisa vira passageiro
  -- (AGENT/ADMIN/AUDITOR são de operação e nunca nascem por cadastro público).
  IF v_role NOT IN ('PASSENGER', 'PARTNER') THEN
    v_role := 'PASSENGER';
  END IF;

  -- GoTrue grava só dígitos; E.164 precisa do `+`. O regexp também aceita o
  -- valor já normalizado (com `+`) e qualquer pontuação, sem duplicar o sinal.
  v_digits := nullif(regexp_replace(coalesce(new.phone, ''), '\D', '', 'g'), '');
  v_phone  := CASE WHEN v_digits IS NULL THEN NULL ELSE '+' || v_digits END;

  INSERT INTO users (id, email, phone_e164, role)
  VALUES (new.id, nullif(new.email, ''), v_phone, v_role)
  ON CONFLICT (id) DO UPDATE
    SET email      = coalesce(excluded.email, users.email),
        phone_e164 = coalesce(excluded.phone_e164, users.phone_e164);

  INSERT INTO profiles (user_id, full_name)
  VALUES (new.id, v_name)
  ON CONFLICT (user_id) DO NOTHING;

  IF v_role = 'PARTNER' THEN
    SELECT id INTO v_city FROM cities WHERE status = 'PILOT' ORDER BY name LIMIT 1;
    IF v_city IS NOT NULL THEN
      INSERT INTO partners (user_id, city_id, kyc_status)
      VALUES (new.id, v_city, 'IN_REVIEW')
      ON CONFLICT (user_id) DO NOTHING;
    END IF;
  END IF;

  RETURN new;
END $$;

-- --- backfill: o MESMO formato nas linhas que já existem ---------------------
UPDATE users
   SET phone_e164 = '+' || phone_e164
 WHERE phone_e164 IS NOT NULL
   AND phone_e164 !~ '^\+';
