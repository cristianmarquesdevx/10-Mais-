-- =============================================================================
-- 10 é + — stub do schema `storage` para rodar a cadeia de migrations fora do
-- Supabase (container PostGIS puro do CI).
--
-- O Storage (serviço de arquivos do Supabase) é dono do schema `storage`, das
-- tabelas `storage.buckets` / `storage.objects` e da função
-- `storage.foldername`. A cadeia de deploy do KYC precisa das três coisas:
--
--   * do bucket `kyc-docs` PRIVADO — é onde o app do parceiro sobe a foto do
--     documento (`kyc/<uid>/<case>/<doc>_<ms>.jpg`);
--   * das políticas de RLS em `storage.objects` — o parceiro só enxerga (e só
--     escreve) o que está na PASTA DELE; o `service_role` ignora a RLS
--     (BYPASSRLS) e a operação lê tudo;
--   * da lista de objetos existentes — o servidor recusa um `storage_path`
--     que não corresponde a um arquivo de verdade (a referência pointing to
--     the void era o buraco de segurança que esta cadeia fecha).
--
-- Este stub cria essa forma MÍNIMA para o CI provar a cadeia do zero. Ele
-- NÃO substitui o Storage do Supabase: no stack local e na nuvem o schema
-- `storage` é do Supabase e este arquivo nunca é aplicado.
--
-- A implementação de `storage.foldername` é a MESMA do Supabase (a pasta do
-- objeto: tudo menos o último segmento) — se divergisse, o CI provaria um
-- predicado que a nuvem não aplica.
--
-- Precedente: o schema `auth` é stubado por `scripts/supabase_auth_stub.sql`
-- (aplicado pelo CI ANTES das migrations, pelo mesmo motivo).
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS storage;

-- Os buckets: o `public = false` é o que torna o bucket PRIVADO (o GET do
-- objeto passa a exigir JWT + política de RLS).
CREATE TABLE IF NOT EXISTS storage.buckets (
  id         text PRIMARY KEY,
  name       text,
  public     boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- Os objetos: `bucket_id` + `name` identificam o arquivo; `owner` é quem
-- subiu. A chave estrangeira para `storage.buckets` é proposital — no
-- Supabase ela existe, e um objeto de um bucket inexistente é erro lá
-- também.
CREATE TABLE IF NOT EXISTS storage.objects (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  bucket_id  text REFERENCES storage.buckets(id),
  name       text,
  owner      uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  metadata   jsonb NOT NULL DEFAULT '{}'::jsonb
);

CREATE INDEX IF NOT EXISTS idx_storage_objects_bucket_name
  ON storage.objects (bucket_id, name);

-- `storage.foldername('kyc/<uid>/<case>/<file>.jpg')` -> {kyc,<uid>,<case>}.
-- Cópia da implementação do Supabase: a PASTA do objeto (tudo menos o
-- último segmento). O predicado de RLS depende do elemento [2] ser o uid
-- do dono — com uma implementação diferente, o CI mentiria.
CREATE OR REPLACE FUNCTION storage.foldername(name text)
RETURNS text[]
LANGUAGE plpgsql
AS $fn$
DECLARE
    _parts text[];
BEGIN
    -- Split on "/" to get path segments
    SELECT string_to_array(name, '/') INTO _parts;
    -- Return everything except the last segment
    RETURN _parts[1 : array_length(_parts,1) - 1];
END
$fn$;
