-- =============================================================================
-- 10 é + — stub do schema `auth` para rodar a cadeia de migrations fora do
-- Supabase (container PostGIS puro do CI).
--
-- O GoTrue (serviço de autenticação do Supabase) é dono do schema `auth` e da
-- tabela `auth.users`. As migrations do produto criam TRIGGERS e colunas em
-- `auth.users` (vínculo da conta -> perfil/passageiro/parceiro), então a
-- cadeia não roda num Postgres puro: ela precisa da tabela para existir.
--
-- Este stub cria a MESMA forma de `auth.users` (só as colunas usadas pelas
-- migrations; o bloco de tokens é dinâmico e ignora as ausentes) para que o
-- CI prove a cadeia de deploy de ponta a ponta. Ele NÃO substitui o GoTrue:
-- no stack local e na nuvem, o schema `auth` é do Supabase e este arquivo
-- nunca é aplicado.
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS auth;

CREATE TABLE IF NOT EXISTS auth.users (
  id                 uuid PRIMARY KEY,
  instance_id        uuid,
  aud                text,
  role               text,
  email              text,
  phone              text,
  email_confirmed_at timestamptz,
  phone_confirmed_at timestamptz,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  raw_app_meta_data  jsonb NOT NULL DEFAULT '{}'::jsonb,
  raw_user_meta_data jsonb NOT NULL DEFAULT '{}'::jsonb
);

-- O GoTrue usa o email como identidade única (lower).
CREATE UNIQUE INDEX IF NOT EXISTS auth_users_email_key
  ON auth.users (lower(email)) WHERE email IS NOT NULL;
