-- =============================================================================
-- 10 é + — preferência de serviço com o código real do serviço
--
-- O despacho passou a comparar a corrida com o `service_types.code` da
-- corrida (RIDE_CAR / DELIVERY_MOTO) e o veículo do parceiro pelo
-- `vehicles.service_type_id` — a modelagem que o schema sempre teve.
--
-- As linhas semeadas antes disso ainda carregam a lista antiga de serviços
-- ('MOTO', 'MOTO_NEGOCIA'), vinda da fase em que o produto era só moto. Com a
-- lista antiga, o parceiro que aceita 'MOTO' NÃO recebia a corrida de carro
-- (RIDE_CAR) — e a corrida de carro era oferecida a quem tem veículo de
-- qualquer tipo. Aqui a lista e o default passam a falar a língua do schema.
-- =============================================================================

-- Linhas existentes com a lista antiga → lista do serviço real.
UPDATE partner_preferences
   SET services = '{RIDE_CAR}'::text[]
 WHERE services = '{MOTO,MOTO_NEGOCIA}'::text[];

UPDATE partners
   SET service_prefs = '{RIDE_CAR}'::text[]
 WHERE service_prefs = '{MOTO,MOTO_NEGOCIA}'::text[];

-- Default das colunas (vale para quem entrar depois).
ALTER TABLE partner_preferences ALTER COLUMN services SET DEFAULT '{RIDE_CAR}'::text[];
ALTER TABLE partners ALTER COLUMN service_prefs SET DEFAULT '{RIDE_CAR}'::text[];

COMMENT ON COLUMN partner_preferences.services IS
  'Códigos de service_types que o parceiro aceita (RIDE_CAR, DELIVERY_MOTO).';
