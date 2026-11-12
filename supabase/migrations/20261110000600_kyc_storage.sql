-- =============================================================================
-- 10 é + — o Storage do KYC: bucket privado, RLS por dono e referência honesta
--
-- O QUE ESTA MIGRATION FECHA
-- --------------------------
-- A migration `20261110000500_kyc_api.sql` gravava em `kyc_documents` o
-- `storage_path` que o app mandava — QUALQUER string. Um parceiro podia
-- apontar o documento para o arquivo de outro parceiro (ou para um path que
-- não existe), e a operação revisava uma referência que não era dele. Era um
-- buraco de segurança conhecido, sem dono.
--
-- Aqui a referência passa a ser verificada pelo SERVIDOR, em duas camadas:
--
--   1. RLS no `storage.objects` (bucket `kyc-docs`): o parceiro só enxerga e
--      só escreve o que está na pasta DELE (`kyc/<uid>/...`). O
--      `service_role` ignora a RLS (BYPASSRLS) — a operação lê tudo.
--
--   2. `api_kyc_case_document`: antes de gravar a referência, o servidor
--      confere que (a) o path começa exatamente com `kyc/<uid do chamador>/`
--      e (b) existe um objeto com esse nome no bucket `kyc-docs`. Path de
--      outro dono -> `storage_path_not_owned`; path de ninguém ->
--      `document_not_found`; sem o schema `storage` no banco ->
--      `storage_unavailable` (erro claro, não "relation does not exist").
--
-- O MODO DEMO/LEGADO CONTINUA VIVO: sem `storage_path` (o app ainda não sobe
-- o arquivo em toda hipótese), a referência continua sendo o marcador
-- `PENDENTE/<case>/<doc>` com `quality_flags.upload_pending = true` — o
-- registro honesto de "o documento ainda não chegou".
--
-- T7: o bucket (`kyc-docs`) e o prefixo do path (`kyc`) são CONTRATO — a
-- fonte única é `scripts/contract.py` e `scripts/test_contract.py` confere
-- que o SQL desta migration continua dizendo a mesma coisa.
--
-- POR QUE A MIGRATION APLICA EM DOIS MUNDO DIFFERENTES
-- ---------------------------------------------------
-- No CI (container PostGIS puro) o schema `storage` é o STUB
-- (`scripts/supabase_storage_stub.sql`); no stack local e na nuvem ele é do
-- Supabase (mesma forma de tabela, função `storage.foldername` idêntica).
-- Por isso o bucket e as políticas são criados sob `to_regclass`: se o
-- schema `storage` não existir, a migration NÃO quebra a cadeia — ela
-- degrada com o erro claro `storage_unavailable` na hora de usar.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. O bucket do KYC: privado, idempotente.
--
-- `public = false` é o que fecha o bucket: o GET do objeto passa a exigir
-- JWT + política de RLS (nenhuma URL anônima entrega documento de parceiro).
--
-- `ON CONFLICT (id) DO UPDATE` torna a migration repetível: rodar duas
-- vezes não cria bucket duplicado nem falha.
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  IF to_regclass('storage.buckets') IS NULL THEN
    RAISE NOTICE 'schema storage.buckets ausente: o bucket kyc-docs será criado quando o Storage existir';
    RETURN;
  END IF;

  INSERT INTO storage.buckets (id, name, public)
  VALUES ('kyc-docs', 'kyc-docs', false)
  ON CONFLICT (id) DO UPDATE
    SET name   = EXCLUDED.name,
        public = false;
END $$;

-- -----------------------------------------------------------------------------
-- 2. As políticas de RLS do bucket.
--
-- O predicado é o MESMO para as quatro operações: o objeto precisa estar no
-- bucket `kyc-docs` E a sua pasta precisa ser a do chamador.
--
-- `storage.foldername('kyc/<uid>/<case>/<file>.jpg')` devolve
-- {kyc, <uid>, <case>} — o elemento [2] é o uid do dono. O `service_role`
-- não passa por RLS (BYPASSRLS), então a operação vê tudo; o `anon` não tem
-- política nenhuma e, com o bucket privado, não chega nem a ler.
--
-- O `ALTER TABLE ... ENABLE ROW LEVEL SECURITY` só roda quando a RLS ainda
-- não está ligada: no stack do Supabase ela já vem ligada, e o `ALTER` é
-- exclusivo do DONO da tabela (o `postgres` local não é dono de
-- `storage.objects`). No CI (stub) a RLS nasce desligada e o `ALTER` roda —
-- lá o `postgres` é dono.
--
-- O DDL de política (`CREATE POLICY`) exige o dono da tabela até o
-- PostgreSQL 15; do 17 em diante basta o privilégio da operação no table.
-- Se faltar permissão, a migration PARA com uma mensagem que diz o que
-- fazer — silenciar isso seria trocar "a política não existe" (o app não
-- consegue subir o arquivo) por um deploy que parece certo.
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  IF to_regclass('storage.objects') IS NULL THEN
    RAISE NOTICE 'schema storage.objects ausente: as políticas de RLS do KYC serão criadas quando o Storage existir';
    RETURN;
  END IF;

  BEGIN
    -- Deny-by-default: sem política, o `authenticated` não enxerga nada.
    IF NOT EXISTS (SELECT 1
                     FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                    WHERE n.nspname = 'storage' AND c.relname = 'objects'
                      AND c.relrowsecurity) THEN
      EXECUTE 'ALTER TABLE storage.objects ENABLE ROW LEVEL SECURITY';
    END IF;

    EXECUTE 'DROP POLICY IF EXISTS kyc_docs_select ON storage.objects';
    EXECUTE 'CREATE POLICY kyc_docs_select ON storage.objects
               FOR SELECT TO authenticated
               USING (bucket_id = ''kyc-docs''
                      AND (storage.foldername(name))[2] = auth.uid()::text)';

    EXECUTE 'DROP POLICY IF EXISTS kyc_docs_insert ON storage.objects';
    EXECUTE 'CREATE POLICY kyc_docs_insert ON storage.objects
               FOR INSERT TO authenticated
               WITH CHECK (bucket_id = ''kyc-docs''
                           AND (storage.foldername(name))[2] = auth.uid()::text)';

    EXECUTE 'DROP POLICY IF EXISTS kyc_docs_update ON storage.objects';
    EXECUTE 'CREATE POLICY kyc_docs_update ON storage.objects
               FOR UPDATE TO authenticated
               USING (bucket_id = ''kyc-docs''
                      AND (storage.foldername(name))[2] = auth.uid()::text)
               WITH CHECK (bucket_id = ''kyc-docs''
                           AND (storage.foldername(name))[2] = auth.uid()::text)';

    EXECUTE 'DROP POLICY IF EXISTS kyc_docs_delete ON storage.objects';
    EXECUTE 'CREATE POLICY kyc_docs_delete ON storage.objects
               FOR DELETE TO authenticated
               USING (bucket_id = ''kyc-docs''
                      AND (storage.foldername(name))[2] = auth.uid()::text)';
  EXCEPTION WHEN insufficient_privilege THEN
    RAISE EXCEPTION
      'sem permissão para criar a política do KYC em storage.objects: o DDL de política exige o DONO da tabela (no Supabase, a role supabase_storage_admin) ou PostgreSQL 17+'
      USING ERRCODE = '42501',
            HINT = 'aplique o DDL de política com um usuário dono de storage.objects (ou atualize o projeto para PostgreSQL 17+)';
  END;
END $$;

-- -----------------------------------------------------------------------------
-- 3. Os privilégios do `authenticated` sobre o Storage.
--
-- No stack do Supabase eles já existem; no CI (stub) não — e sem eles as
-- políticas não valeriam nada. `GRANT` é idempotente.
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  IF to_regclass('storage.objects') IS NULL THEN
    RETURN;
  END IF;

  EXECUTE 'GRANT USAGE ON SCHEMA storage TO authenticated, service_role';
  EXECUTE 'GRANT SELECT, INSERT, UPDATE, DELETE ON storage.objects TO authenticated, service_role';
END $$;

-- -----------------------------------------------------------------------------
-- 4. O predicado do path — isolado, para ser testável e para ter UM só lugar
--    onde a regra mora.
--
-- O path do KYC é `kyc/<partner_user_id>/<case_id>/<doc_type>_<ms>.jpg`:
-- o chamador só pode apontar para a PASTA DELE. `starts_with` (e não LIKE)
-- porque a comparação tem que ser literal — sem curinga.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_kyc_storage_path_allowed(p_uid uuid, p_path text)
RETURNS boolean
LANGUAGE sql STABLE
SET search_path = public, pg_temp AS $$
  SELECT p_uid IS NOT NULL
     AND p_path IS NOT NULL
     AND starts_with(p_path, 'kyc/' || p_uid::text || '/');
$$;

COMMENT ON FUNCTION fn_kyc_storage_path_allowed(uuid, text) IS
  'Verdadeiro quando o path do documento está na pasta do próprio parceiro '
  '(kyc/<uid>/...). Regra única do dono do arquivo — T7: prefixo ''kyc'' vem '
  'de scripts/contract.py (KYC_STORAGE_PATH_PREFIX).';

-- -----------------------------------------------------------------------------
-- 5. O Storage está disponível?
--
-- A cadeia roda em banco sem o schema `storage` (CI sem stub, instalação
-- sem o Storage). Aí a referência real NÃO pode ser validada — e o servidor
-- precisa dizer isso (`storage_unavailable`), não estourar "relation does
-- not exist" no meio do plpgsql.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_kyc_storage_available()
RETURNS boolean
LANGUAGE sql STABLE
SET search_path = public, pg_temp AS $$
  SELECT to_regclass('storage.objects') IS NOT NULL;
$$;

-- -----------------------------------------------------------------------------
-- 6. O objeto existe?
--
-- `storage.objects` é referenciado com o schema EXPLÍCITO: a função é
-- SECURITY DEFINER com `search_path = public, pg_temp` — sem o schema
-- explícito, o nome resolveria para o `public` (e o predicado cairia).
--
-- A função NÃO é SECURITY DEFINER de propósito: chamada de dentro da
-- `api_kyc_case_document` (que é), ela enxerga o Storage inteiro; chamada
-- direto pelo `authenticated`, as políticas de RLS valem — o parceiro não
-- consegue sondar a pasta de outro.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_kyc_storage_object_exists(p_bucket text, p_path text)
RETURNS boolean
LANGUAGE plpgsql STABLE
SET search_path = public, pg_temp AS $$
DECLARE
  v_existe boolean;
BEGIN
  IF to_regclass('storage.objects') IS NULL THEN
    RAISE EXCEPTION 'storage_unavailable' USING ERRCODE = '22023';
  END IF;

  SELECT EXISTS (SELECT 1 FROM storage.objects o
                  WHERE o.bucket_id = p_bucket AND o.name = p_path)
    INTO v_existe;

  RETURN v_existe;
END $$;

-- -----------------------------------------------------------------------------
-- 7. O PARCEIRO reenvia a documentação (após uma recusa) — COM VALIDAÇÃO.
--
-- A assinatura NÃO muda (o CI tem assert de assinatura: 5 parâmetros), e o
-- comportamento do modo demo/legado (sem `storage_path`) é preservado.
--
-- A ordem das conferências é deliberada:
--   1. o Storage está disponível?  -> 503 `storage_unavailable` (o servidor
--      não consegue validar nada agora — honestidade antes de tudo);
--   2. o path é da pasta do chamador? -> 422 `storage_path_not_owned`;
--   3. o objeto existe?               -> 422 `document_not_found`.
--
-- Ao aceitar um path real, `upload_pending` vai para FALSE (o arquivo está
-- lá) preservando as flags de qualidade que o app mandou (blur, reflexo...).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api_kyc_case_document(
  p_case uuid,
  p_doc_type text,
  p_storage_path text DEFAULT NULL,
  p_expires_at date DEFAULT NULL,
  p_quality_flags jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_uid  uuid := app_uid();
  v_case kyc_cases%ROWTYPE;
  v_city uuid;
  v_path text;
  v_flags jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated' USING ERRCODE = '28000';
  END IF;

  IF p_doc_type IS NULL
     OR p_doc_type NOT IN ('CNH','CRLV','SELFIE','PROOF_ADDRESS','OTHER') THEN
    RAISE EXCEPTION 'invalid_doc_type' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_case FROM kyc_cases c WHERE c.id = p_case;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'kyc_case_not_found' USING ERRCODE = 'P0002';
  END IF;
  IF v_case.partner_user_id <> v_uid THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;
  IF v_case.status IN ('AUTO_APPROVED','APPROVED') THEN
    RAISE EXCEPTION 'kyc_already_approved' USING ERRCODE = '22023';
  END IF;

  v_path := NULLIF(btrim(COALESCE(p_storage_path,'')), '');
  v_flags := COALESCE(p_quality_flags, '{}'::jsonb);

  IF v_path IS NULL THEN
    -- MODO DEMO/LEGADO: o app ainda não sobe o arquivo. A referência é o
    -- marcador `PENDENTE/...` e a flag diz que o upload NÃO aconteceu —
    -- registro honesto, não download fingido.
    v_path  := 'PENDENTE/' || v_case.id::text || '/' || p_doc_type;
    v_flags := v_flags || jsonb_build_object('upload_pending', true);
  ELSE
    -- O app subiu o arquivo: o servidor confere antes de aceitar a
    -- referência (path do dono + objeto existente no bucket).
    IF NOT fn_kyc_storage_available() THEN
      RAISE EXCEPTION 'storage_unavailable' USING ERRCODE = '22023';
    END IF;
    IF NOT fn_kyc_storage_path_allowed(v_uid, v_path) THEN
      RAISE EXCEPTION 'storage_path_not_owned' USING ERRCODE = '22023';
    END IF;
    IF NOT fn_kyc_storage_object_exists('kyc-docs', v_path) THEN
      RAISE EXCEPTION 'document_not_found' USING ERRCODE = '22023';
    END IF;
    -- O arquivo está lá: `upload_pending` é FALSE. As flags de qualidade do
    -- app (blur, reflexo, corte) são preservadas.
    v_flags := v_flags || jsonb_build_object('upload_pending', false);
  END IF;

  INSERT INTO kyc_documents (case_id, doc_type, storage_path, expires_at, quality_flags)
  VALUES (v_case.id, p_doc_type, v_path, p_expires_at, v_flags);

  SELECT p.city_id INTO v_city FROM partners p WHERE p.user_id = v_uid;

  -- Recusado/reescrito: o caso volta para a fila com prazo novo.
  IF v_case.status IN ('REJECTED','RESUBMIT') THEN
    UPDATE kyc_cases c
       SET status = 'RESUBMIT',
           sla_due_at = fn_kyc_sla_due(v_city, now()),
           decided_at = NULL,
           decided_by = NULL,
           rejection_code = NULL
     WHERE c.id = v_case.id
     RETURNING * INTO v_case;

    UPDATE partners p SET kyc_status = 'RESUBMIT' WHERE p.user_id = v_uid;

    PERFORM fn_emit_event(NULL, 'kyc.resubmitted',
      jsonb_build_object('case_id', v_case.id, 'doc_type', p_doc_type),
      v_uid, 'kyc-resubmit:' || v_case.id || ':' || p_doc_type);
  END IF;

  RETURN jsonb_build_object(
    'case_id', v_case.id,
    'status',  v_case.status,
    'position', CASE WHEN v_case.status IN ('IN_REVIEW','RESUBMIT')
                     THEN fn_kyc_queue_position(v_case.id) END,
    'sla',     v_case.sla_due_at);
END $$;

-- -----------------------------------------------------------------------------
-- 8. GRANTS — a API do KYC é do `authenticated`; `anon` não entra.
--
-- Mesma política da migration `20261110000500_kyc_api.sql`, com a lista
-- atualizada: os predicados novos (`fn_kyc_storage_*`) entram no bloco
-- porque são chamados de dentro da API e precisam ser executáveis pelo
-- `authenticated` (e não pelo `anon`).
-- -----------------------------------------------------------------------------
DO $$
DECLARE f record;
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'anon') THEN
    CREATE ROLE anon NOLOGIN;
  END IF;
END $$;

DO $$
DECLARE f record;
BEGIN
  FOR f IN
    SELECT p.oid::regprocedure AS sig
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname IN ('fn_kyc_sla_due','fn_kyc_queue_position',
                         'api_kyc_case_create','api_kyc_case_get',
                         'api_kyc_case_document','api_kyc_queue','api_kyc_review',
                         'fn_kyc_storage_path_allowed','fn_kyc_storage_available',
                         'fn_kyc_storage_object_exists')
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon', f.sig);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated, service_role', f.sig);
  END LOOP;
END $$;
