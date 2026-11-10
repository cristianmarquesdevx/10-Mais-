-- =============================================================================
-- 10 é + — identidade real (Supabase Auth / GoTrue)
--
-- O DDL da Fase 2 modelou identidade por telefone: `users.phone_e164` era
-- NOT NULL. Com o Supabase Auth deste projeto o provedor de SMS está
-- desligado (sem credencial de operadora), então a identidade nasce por
-- E-MAIL no auth.users. Para não inventar telefone, `phone_e164` passa a ser
-- opcional e `users` ganha `email`, com a regra de que toda linha precisa de
-- pelo menos uma das duas identidades.
--
-- O vínculo auth.users → users/profiles/partners é por trigger: a conta é
-- criada pelo GoTrue e o perfil nasce no mesmo instante, com o papel vindo do
-- metadata do cadastro (`role`), nunca de parâmetro de requisição.
-- =============================================================================

-- --- identidade: e-mail opcional, telefone opcional, pelo menos um ---------
ALTER TABLE users ADD COLUMN IF NOT EXISTS email text;
ALTER TABLE users ALTER COLUMN phone_e164 DROP NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS users_email_key
  ON users (lower(email)) WHERE email IS NOT NULL;

ALTER TABLE users DROP CONSTRAINT IF EXISTS users_identity_present;
ALTER TABLE users ADD CONSTRAINT users_identity_present
  CHECK (email IS NOT NULL OR phone_e164 IS NOT NULL);

-- --- auth.users → perfil do produto ----------------------------------------
CREATE OR REPLACE FUNCTION fn_sync_auth_user() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_role text := upper(coalesce(new.raw_user_meta_data ->> 'role', 'PASSENGER'));
  v_name text := coalesce(
    nullif(btrim(new.raw_user_meta_data ->> 'full_name'), ''),
    nullif(split_part(coalesce(new.email, ''), '@', 1), ''),
    'Usuário 10 é +'
  );
  v_city uuid;
BEGIN
  -- Papel só entre os dois que o app cria; qualquer outra coisa vira passageiro
  -- (AGENT/ADMIN/AUDITOR são de operação e nunca nascem por cadastro público).
  IF v_role NOT IN ('PASSENGER', 'PARTNER') THEN
    v_role := 'PASSENGER';
  END IF;

  INSERT INTO users (id, email, phone_e164, role)
  VALUES (new.id, nullif(new.email, ''), nullif(new.phone, ''), v_role)
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

DROP TRIGGER IF EXISTS trg_auth_user_created ON auth.users;
CREATE TRIGGER trg_auth_user_created
  AFTER INSERT OR UPDATE OF email, phone, raw_user_meta_data ON auth.users
  FOR EACH ROW EXECUTE FUNCTION fn_sync_auth_user();

-- --- backfill: contas que já existiam no GoTrue antes do trigger --------------
INSERT INTO users (id, email, phone_e164, role)
SELECT u.id, nullif(u.email, ''), nullif(u.phone, ''),
       CASE WHEN upper(coalesce(u.raw_user_meta_data ->> 'role', '')) = 'PARTNER'
            THEN 'PARTNER' ELSE 'PASSENGER' END
FROM auth.users u
WHERE NOT EXISTS (SELECT 1 FROM users x WHERE x.id = u.id);

INSERT INTO profiles (user_id, full_name)
SELECT u.id,
       coalesce(nullif(btrim(u.raw_user_meta_data ->> 'full_name'), ''),
                nullif(split_part(coalesce(u.email, ''), '@', 1), ''),
                'Usuário 10 é +')
FROM auth.users u
WHERE NOT EXISTS (SELECT 1 FROM profiles p WHERE p.user_id = u.id);

-- --- contas de desenvolvimento ------------------------------------------------
-- O seed da Fase 2 criou users/profiles/partners com UUID fixo, mas sem conta
-- correspondente no GoTrue (auth.users vazio). Aqui a mesma identidade ganha a
-- conta de e-mail correspondente, para que o radar local e o login real
-- apontem para a MESMA pessoa.
INSERT INTO auth.users (id, instance_id, aud, role, email, email_confirmed_at,
                        created_at, updated_at, raw_app_meta_data, raw_user_meta_data)
VALUES
  ('11111111-1111-4111-8111-111111111111', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'passageiro@dezemais.local', now(), now(), now(),
   '{"provider":"email","providers":["email"]}'::jsonb,
   '{"role":"PASSENGER","full_name":"Passageiro dev"}'::jsonb),
  ('22222222-2222-4222-8222-222222222222', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'parceiro@dezemais.local', now(), now(), now(),
   '{"provider":"email","providers":["email"]}'::jsonb,
   '{"role":"PARTNER","full_name":"Parceiro dev"}'::jsonb)
ON CONFLICT (id) DO NOTHING;

UPDATE users SET email = 'passageiro@dezemais.local'
 WHERE id = '11111111-1111-4111-8111-111111111111' AND email IS NULL;
UPDATE users SET email = 'parceiro@dezemais.local'
 WHERE id = '22222222-2222-4222-8222-222222222222' AND email IS NULL;
