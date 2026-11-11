-- =============================================================================
-- 10 é + — seed de DESENVOLVIMENTO (não é dado de produção)
--
-- Cria a praça piloto e as contas fixas do stack local:
--   passageiro  11111111-1111-4111-8111-111111111111
--   parceiro    22222222-2222-4222-8222-222222222222
--   agente      66666666-6666-4666-8666-666666666666  (operação: fila do KYC)
--   parceiro KYC 77777777-7777-4777-8777-777777777777 (sem KYC: smoke do KYC)
--
-- O JWT de desenvolvimento é gerado por `python scripts/dev_jwt.py --role ...`
-- (mesmo sub). Sem token, o radar responde 401 — não há identidade implícita.
--
-- Os parâmetros semeados são os já aprovados no GATE 2 (oferta 15 s, raio 2→8 km,
-- comissão 12%, passe R$ 10) e os do KYC (janela humana de revisão 7h–23h no
-- fuso da praça, antecedência mínima do SLA de 2 h). Preço por km/min NÃO é
-- semeado aqui: a política tarifária é a Fase 4 e depende de aprovação.
-- =============================================================================

INSERT INTO cities (id, name, uf, status, timezone)
VALUES ('33333333-3333-4333-8333-333333333333', 'Porto Velho', 'RO', 'PILOT',
        'America/Porto_Velho')
ON CONFLICT (id) DO NOTHING;

INSERT INTO service_types (id, code, display_name) VALUES
  ('44444444-4444-4444-8444-444444444444', 'RIDE_CAR', 'Corrida'),
  ('55555555-5555-4555-8555-555555555555', 'DELIVERY_MOTO', 'Entrega')
ON CONFLICT (code) DO NOTHING;

INSERT INTO city_configs (city_id, param_key, param_value, valid_from)
SELECT '33333333-3333-4333-8333-333333333333', k, v, now() - interval '1 day'
FROM (VALUES
  ('PRM-oferta.timeout', '15'::jsonb),
  ('PRM-match.r0',       '2'::jsonb),
  ('PRM-match.passo',    '1'::jsonb),
  ('PRM-match.rmax',     '8'::jsonb),
  ('PRM-hb.intervalo',   '30'::jsonb),
  ('PRM-comissao.pct',   '12'::jsonb),
  ('PRM-passe.preco',    '10'::jsonb),
  -- KYC: janela humana de revisão (7h-23h no fuso da praça) e antecedência
  -- mínima do SLA (2 h). O prazo de um caso é o primeiro instante que
  -- cumpre a antecedência dentro da janela — ver fn_kyc_sla_due.
  ('PRM-kyc.review_inicio_h',       '7'::jsonb),
  ('PRM-kyc.review_fim_h',          '23'::jsonb),
  ('PRM-kyc.sla_antecedencia_h',    '2'::jsonb)
) AS c(k, v)
WHERE NOT EXISTS (
  SELECT 1 FROM city_configs cc
   WHERE cc.city_id = '33333333-3333-4333-8333-333333333333'
     AND cc.param_key = c.k
);

-- Reconcilia o valor da cidade piloto com o deste arquivo (que é o contrato:
-- SPECS §1.1). O INSERT acima só põe o que FALTA — sem este UPDATE, um
-- valor antigo continuava valendo para sempre, e foi assim que a janela da
-- oferta ficou em 60 s no banco local enquanto o SPEC, o seed e a API de
-- demonstração diziam 15 s (o passageiro esperava 4× mais por um motorista
-- que talvez nunca visse a oferta).
--
-- Só a linha que o `city_config_current` enxerga (a mais recente em vigor).
UPDATE city_configs cc
   SET param_value = v.param_value
  FROM (VALUES
    ('PRM-oferta.timeout', '15'::jsonb),
    ('PRM-match.r0',       '2'::jsonb),
    ('PRM-match.passo',    '1'::jsonb),
    ('PRM-match.rmax',     '8'::jsonb),
    ('PRM-hb.intervalo',   '30'::jsonb),
    ('PRM-comissao.pct',   '12'::jsonb),
    ('PRM-passe.preco',    '10'::jsonb),
    ('PRM-kyc.review_inicio_h',       '7'::jsonb),
    ('PRM-kyc.review_fim_h',          '23'::jsonb),
    ('PRM-kyc.sla_antecedencia_h',    '2'::jsonb)
  ) AS v(param_key, param_value)
 WHERE cc.city_id = '33333333-3333-4333-8333-333333333333'
   AND cc.param_key = v.param_key
   AND cc.valid_from = (
        SELECT max(c2.valid_from)
          FROM city_configs c2
         WHERE c2.city_id = cc.city_id
           AND c2.param_key = cc.param_key
           AND now() >= c2.valid_from
           AND (c2.valid_to IS NULL OR now() < c2.valid_to));

-- --- contas de desenvolvimento ------------------------------------------------
INSERT INTO users (id, phone_e164, role) VALUES
  ('11111111-1111-4111-8111-111111111111', '+5596990000001', 'PASSENGER'),
  ('22222222-2222-4222-8222-222222222222', '+5596990000002', 'PARTNER'),
  -- Operação: é quem enxerga a fila do KYC e decide (api_kyc_queue /
  -- api_kyc_review exigem papel AGENT/ADMIN).
  ('66666666-6666-4666-8666-666666666666', '+5596990000003', 'AGENT'),
  -- Parceiro QUE AINDA NÃO SUBMETEU o KYC: é o parceiro do smoke do KYC
  -- (novo cadastro -> em análise -> fila -> recusa -> reenvio -> aprovação).
  ('77777777-7777-4777-8777-777777777777', '+5596990000004', 'PARTNER')
ON CONFLICT (id) DO NOTHING;

INSERT INTO profiles (user_id, full_name) VALUES
  ('11111111-1111-4111-8111-111111111111', 'Passageiro dev'),
  ('22222222-2222-4222-8222-222222222222', 'Parceiro dev'),
  ('66666666-6666-4666-8666-666666666666', 'Agente dev'),
  ('77777777-7777-4777-8777-777777777777', 'Parceiro KYC dev')
ON CONFLICT (user_id) DO NOTHING;

INSERT INTO partners (user_id, city_id, kyc_status, monetization_mode)
VALUES ('22222222-2222-4222-8222-222222222222',
        '33333333-3333-4333-8333-333333333333', 'APPROVED', 'COMISSAO')
ON CONFLICT (user_id) DO NOTHING;

-- Parceiro ainda sem KYC submetido (o smoke do KYC começa por aqui).
INSERT INTO partners (user_id, city_id, kyc_status, monetization_mode)
VALUES ('77777777-7777-4777-8777-777777777777',
        '33333333-3333-4333-8333-333333333333', 'NOT_STARTED', 'COMISSAO')
ON CONFLICT (user_id) DO NOTHING;

-- --- contas no GoTrue -------------------------------------------------------
--
-- O JWT de desenvolvimento só autentica quem EXISTE no GoTrue (`/auth/v1/user`
-- procura o `sub`): sem esta linha, o smoke do KYC e o da fila não têm
-- identidade. O trigger `fn_sync_auth_user` mantém `users`/`profiles` em
-- dia — e o papel de operação é corrigido logo abaixo, porque o trigger só
-- aceita PASSENGER/PARTNER (AGENT/ADMIN nunca nascem por cadastro público).
INSERT INTO auth.users (id, instance_id, aud, role, email, email_confirmed_at,
                        created_at, updated_at, raw_app_meta_data, raw_user_meta_data)
VALUES
  ('66666666-6666-4666-8666-666666666666', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'agente@dezemais.local', now(), now(), now(),
   '{"provider":"email","providers":["email"]}'::jsonb,
   '{"role":"AGENT","full_name":"Agente dev"}'::jsonb),
  ('77777777-7777-4777-8777-777777777777', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'parceiro.kyc@dezemais.local', now(), now(), now(),
   '{"provider":"email","providers":["email"]}'::jsonb,
   '{"role":"PARTNER","full_name":"Parceiro KYC dev"}'::jsonb)
ON CONFLICT (id) DO NOTHING;

-- O GoTrue lê as colunas de token em `string` (não `*string`): NULL quebra o
-- GET /auth/v1/user com 500. Onde a coluna existe, ela vale ''.
--
-- A normalização é DINÂMICA: o schema `auth` é do GoTrue (não do produto) e
-- muda de versão — o seed não pode quebrar quando isso acontecer.
DO $$
DECLARE
  c text;
BEGIN
  FOREACH c IN ARRAY ARRAY[
    'confirmation_token', 'recovery_token', 'email_change_token_new',
    'email_change', 'phone_change', 'phone_change_token',
    'email_change_token_current', 'reauthentication_token'
  ] LOOP
    IF EXISTS (SELECT 1 FROM information_schema.columns
                WHERE table_schema = 'auth' AND table_name = 'users'
                  AND column_name = c) THEN
      EXECUTE format(
        'UPDATE auth.users SET %I = %L WHERE %I IS NULL AND id = ANY(%L::uuid[])',
        c, '', c,
        ARRAY['11111111-1111-4111-8111-111111111111',
              '22222222-2222-4222-8222-222222222222',
              '66666666-6666-4666-8666-666666666666',
              '77777777-7777-4777-8777-777777777777']);
    END IF;
  END LOOP;
END $$;

UPDATE users SET role = 'AGENT'
 WHERE id = '66666666-6666-4666-8666-666666666666'
   AND role <> 'AGENT';

UPDATE users SET email = 'agente@dezemais.local'
 WHERE id = '66666666-6666-4666-8666-666666666666' AND email IS NULL;
UPDATE users SET email = 'parceiro.kyc@dezemais.local'
 WHERE id = '77777777-7777-4777-8777-777777777777' AND email IS NULL;

INSERT INTO partner_presence (partner_user_id)
VALUES ('22222222-2222-4222-8222-222222222222')
ON CONFLICT (partner_user_id) DO NOTHING;

INSERT INTO vehicles (partner_user_id, plate, brand, model, color, category, service_type_id)
SELECT '22222222-2222-4222-8222-222222222222', 'PVH0A10', 'Honda', 'Biz 125',
       'Verde', 'MOTO', '44444444-4444-4444-8444-444444444444'
WHERE NOT EXISTS (
  SELECT 1 FROM vehicles WHERE plate = 'PVH0A10'
);
