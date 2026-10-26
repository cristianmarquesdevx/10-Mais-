-- =============================================================================
-- 10 é + — seed de DESENVOLVIMENTO (não é dado de produção)
--
-- Cria a praça piloto e duas contas fixas para o radar local:
--   passageiro  11111111-1111-4111-8111-111111111111
--   parceiro    22222222-2222-4222-8222-222222222222
--
-- O JWT de desenvolvimento é gerado por `python scripts/dev_jwt.py --role ...`
-- (mesmo sub). Sem token, o radar responde 401 — não há identidade implícita.
--
-- Os parâmetros semeados são os já aprovados no GATE 2 (oferta 15 s, raio 2→8 km,
-- comissão 12%, passe R$ 10). Preço por km/min NÃO é semeado aqui: a política
-- tarifária é a Fase 4 e depende de aprovação.
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
  ('PRM-passe.preco',    '10'::jsonb)
) AS c(k, v)
WHERE NOT EXISTS (
  SELECT 1 FROM city_configs cc
   WHERE cc.city_id = '33333333-3333-4333-8333-333333333333'
     AND cc.param_key = c.k
);

-- --- contas de desenvolvimento ------------------------------------------------
INSERT INTO users (id, phone_e164, role) VALUES
  ('11111111-1111-4111-8111-111111111111', '+5596990000001', 'PASSENGER'),
  ('22222222-2222-4222-8222-222222222222', '+5596990000002', 'PARTNER')
ON CONFLICT (id) DO NOTHING;

INSERT INTO profiles (user_id, full_name) VALUES
  ('11111111-1111-4111-8111-111111111111', 'Passageiro dev'),
  ('22222222-2222-4222-8222-222222222222', 'Parceiro dev')
ON CONFLICT (user_id) DO NOTHING;

INSERT INTO partners (user_id, city_id, kyc_status, monetization_mode)
VALUES ('22222222-2222-4222-8222-222222222222',
        '33333333-3333-4333-8333-333333333333', 'APPROVED', 'COMISSAO')
ON CONFLICT (user_id) DO NOTHING;

INSERT INTO partner_presence (partner_user_id)
VALUES ('22222222-2222-4222-8222-222222222222')
ON CONFLICT (partner_user_id) DO NOTHING;

INSERT INTO vehicles (partner_user_id, plate, brand, model, color, category, service_type_id)
SELECT '22222222-2222-4222-8222-222222222222', 'PVH0A10', 'Honda', 'Biz 125',
       'Verde', 'MOTO', '44444444-4444-4444-8444-444444444444'
WHERE NOT EXISTS (
  SELECT 1 FROM vehicles WHERE plate = 'PVH0A10'
);
