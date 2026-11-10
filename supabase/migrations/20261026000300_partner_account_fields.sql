-- ---------------------------------------------------------------------------
-- Conta do parceiro: o que o app mantém e o schema ainda não tinha coluna.
--
-- `partners` já guarda KYC e modo de monetização; o app também configura o piso
-- por corrida, os tipos que aceita e o cadastro (CNH/placa/modelo). Como são
-- atributos do parceiro — não do despacho nem da presença — moram na própria
-- linha dele, e não numa tabela paralela.
--
-- `partners` é uma tabela por parceiro: as colunas abaixo não mudam nenhuma
-- regra de despacho (o piso continua sendo entrada do ranking, agora com
-- origem persistida em vez de memória do servidor de demonstração).
-- ---------------------------------------------------------------------------

ALTER TABLE partners
  ADD COLUMN IF NOT EXISTS min_fare numeric(10,2) NOT NULL DEFAULT 0
    CONSTRAINT partners_min_fare_range CHECK (min_fare >= 0 AND min_fare <= 500);

ALTER TABLE partners
  ADD COLUMN IF NOT EXISTS service_prefs text[] NOT NULL
    DEFAULT ARRAY['RIDE_CAR']::text[];

COMMENT ON COLUMN partners.min_fare IS
  'Piso que o parceiro aceita por corrida (Configurar solicitações). 0 = sem piso.';
COMMENT ON COLUMN partners.service_prefs IS
  'Códigos de service_types que o parceiro quer receber (RIDE_CAR, DELIVERY_MOTO).';

ALTER TABLE partners
  ADD COLUMN IF NOT EXISTS profile_details jsonb;

COMMENT ON COLUMN partners.profile_details IS
  'Cadastro vindo do app (nome, CNH, placa, modelo). Dado do parceiro; o KYC '
  'em si continua em kyc_cases.';
