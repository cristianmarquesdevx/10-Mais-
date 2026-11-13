-- 10 é + — a operação precisa de um "ARQUIVO OK" HONESTO, e a fila precisa
-- dos casos mais urgentes primeiro.
--
-- DOIS defeitos da migration `20261110000800_kyc_console_docs.sql`:
--
--   1. `has_file` MENTIA. A 00800 calculou o campo como "o caminho não é o
--      marcador `PENDENTE/`" — mas o nome (e a tela) dizem outra coisa: o
--      console pintava **ARQUIVO OK** (verde) para um documento cujo objeto
--      NÃO existia no bucket, e o preview falhava logo abaixo ("Não foi
--      possível carregar o documento"). Duas afirmações contrárias na mesma
--      tela. Agora `has_file` consulta o BUCKET de verdade;
--
--   2. A FILA PODIA OMITIR os casos mais urgentes. O `LIMIT` estava dentro
--      do subquery **sem `ORDER BY`**: o Postgres devolvia 50 linhas
--      arbitrárias (ordem de heap) e só depois o `jsonb_agg` ordenava. Com
--      mais de 50 casos na fila, o caso que vence primeiro podia não estar
--      na tela — numa fila de atendimento, isso é esconder trabalho.
--      O `ORDER BY` vai para DENTRO do subquery, antes do `LIMIT`, na mesma
--      chave do ranking (`fn_kyc_queue_position`: `sla_due_at, created_at,
--      id`).
--
-- O que NÃO muda: a política do bucket, a identidade do parceiro, a
-- autorização (dono ou `app_is_agent()`) e o caminho do produto (sem
-- service role, sem URL assinada).

-- -----------------------------------------------------------------------------
-- 1. O objeto existe? (versão que NÃO estoura)
--
-- `fn_kyc_storage_object_exists` (00600) LEVANTA `storage_unavailable`
-- quando o schema `storage` não existe — certo para quem está SUBINDO um
-- arquivo, errado para quem está só perguntando "esse arquivo está lá?".
-- Esta versão devolve `false` (a ausência do Storage é degradação, não
-- erro) e é o que a tela da operação consome.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_kyc_storage_object_present(p_bucket text, p_path text)
RETURNS boolean
LANGUAGE plpgsql STABLE
SET search_path = public, pg_temp AS $$
DECLARE
  v_existe boolean := false;
BEGIN
  IF to_regclass('storage.objects') IS NULL THEN
    RETURN false;
  END IF;

  SELECT EXISTS (SELECT 1 FROM storage.objects o
                  WHERE o.bucket_id = p_bucket AND o.name = p_path)
    INTO v_existe;

  RETURN v_existe;
END $$;

COMMENT ON FUNCTION fn_kyc_storage_object_present(text, text) IS
  'o objeto existe no bucket? false quando o Storage nao esta instalado (degradacao, nao erro)';

-- A função é de **leitura de metadado do bucket**, e o bucket é PRIVADO.
-- Sem o revoke, ela fica executável por PUBLIC/anon: qualquer visitante
-- da API poderia perguntar "esse path existe?" e transformar a função em
-- oráculo de existência de documento de parceiro (mesmo que a RLS do
-- `storage.objects` devolva 0 linhas para quem não é dono — o endpoint
-- público em si é que não devia existir).
--
-- A 00600 já faz esse revoke para as funções do KYC; a 00900 repete o
-- padrão para a função nova (mesmo `DO` sobre `pg_proc`, que é
-- idempotente).
DO $$
DECLARE f record;
BEGIN
  FOR f IN
    SELECT p.oid::regprocedure AS sig
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname = 'fn_kyc_storage_object_present'
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon', f.sig);
    EXECUTE format(
      'GRANT EXECUTE ON FUNCTION %s TO authenticated, service_role', f.sig);
  END LOOP;
END $$;

-- -----------------------------------------------------------------------------
-- 2. O caso com a documentação — agora com o `has_file` HONESTO.
--
-- A função é SECURITY DEFINER: a consulta ao `storage.objects` roda com o
-- papel do dono da função (o `postgres` do Supabase tem BYPASSRLS), e quem
-- chega aqui já passou pela autorização do caso (dono ou operação).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api_kyc_case_get(p_case uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_uid  uuid := app_uid();
  v_case kyc_cases%ROWTYPE;
  v_docs jsonb;
  v_name text;
  v_phone text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated' USING ERRCODE = '28000';
  END IF;

  SELECT * INTO v_case FROM kyc_cases c WHERE c.id = p_case;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'kyc_case_not_found' USING ERRCODE = 'P0002';
  END IF;

  -- O dono vê o seu caso; a operação vê todos.
  IF v_case.partner_user_id <> v_uid AND NOT app_is_agent() THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  -- A identidade do parceiro: o NOME vem do perfil e o TELEFONE da conta.
  -- Sem eles, a operação só tinha um uuid truncado ("Parceiro 77777777").
  SELECT p.full_name, u.phone_e164
    INTO v_name, v_phone
    FROM users u
    LEFT JOIN profiles p ON p.user_id = u.id
   WHERE u.id = v_case.partner_user_id;

  -- O `jsonb_strip_nulls` do RETURN (abaixo) alcança o array `documents`:
  -- um caminho VAZIO vira `null` (o `NULLIF` acima) e some da resposta —
  -- nunca `"storage_path": null`. (Verificado no PG 16.4 e no 17.11; o
  -- CI guarda esse comportamento — se uma versão do Postgres deixar de
  -- recursar, o assert do `ci_migrations.sh` acusa.)
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'doc_type', d.doc_type,
           'created_at', d.created_at,
           -- O caminho do arquivo: o app monta a URL do bucket com o token
           -- do chamador. `PENDENTE/...` é o marcador honesto do registro
           -- SEM arquivo — não é um objeto, e por isso não vira URL.
           'storage_path', NULLIF(d.storage_path, ''),
           -- O objeto EXISTE no bucket? (a pergunta é feita ao bucket, não
           -- ao nome do caminho: um path que não aponta para objeto nenhum
           -- é "sem arquivo", e a tela não pode pintar "ARQUIVO OK")
           'has_file', fn_kyc_storage_object_present('kyc-docs', d.storage_path),
           'upload_pending', COALESCE((d.quality_flags->>'upload_pending')::boolean, false))
         ORDER BY d.created_at), '[]'::jsonb)
    INTO v_docs
    FROM kyc_documents d
   WHERE d.case_id = v_case.id;

  RETURN jsonb_strip_nulls(jsonb_build_object(
    'case_id',  v_case.id,
    'status',   v_case.status,
    'position', CASE WHEN v_case.status IN ('IN_REVIEW','RESUBMIT')
                     THEN fn_kyc_queue_position(v_case.id) END,
    'sla',      v_case.sla_due_at,
    'rejection_code', v_case.rejection_code,
    'decided_at', v_case.decided_at,
    'partner_user_id', v_case.partner_user_id,
    'partner_name', v_name,
    'partner_phone', v_phone,
    'documents', v_docs));
END $$;

-- -----------------------------------------------------------------------------
-- 3. A fila — a mesma identidade, e os casos mais urgentes PRIMEIRO.
--
-- O `ORDER BY` vem antes do `LIMIT`: é a ordem do ranking
-- (`fn_kyc_queue_position`): prazo, entrada e id. Sem ele, a fila devolvia
-- 50 casos ARBITRÁRIOS e o console podia não mostrar o caso que vence
-- primeiro.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api_kyc_queue(p_limit integer DEFAULT 50)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_uid uuid := app_uid();
  v_out jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated' USING ERRCODE = '28000';
  END IF;
  IF NOT app_is_agent() THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  -- A ordenação FINAL (o `jsonb_agg` externo) usa a MESMA chave do
  -- ranking: prazo, entrada e id. Sem o `q.id`, dois casos com o mesmo
  -- prazo e a mesma hora de entrada saíam em ordem arbitrária na tela.
  SELECT COALESCE(jsonb_agg(row_to_json(q) ORDER BY q.sla_due_at, q.created_at, q.case_id), '[]'::jsonb)
    INTO v_out
    FROM (
      SELECT c.id AS case_id,
             c.partner_user_id,
             prof.full_name AS partner_name,
             u.phone_e164 AS partner_phone,
             c.status,
             c.sla_due_at,
             c.created_at,
             fn_kyc_queue_position(c.id) AS position,
             (SELECT count(*)::int FROM kyc_documents d WHERE d.case_id = c.id) AS documents
        FROM kyc_cases c
        JOIN users u ON u.id = c.partner_user_id
        LEFT JOIN profiles prof ON prof.user_id = u.id
       WHERE c.status IN ('IN_REVIEW','RESUBMIT')
       ORDER BY c.sla_due_at, c.created_at, c.id
       LIMIT LEAST(GREATEST(COALESCE(p_limit, 50), 1), 200)
    ) q;

  RETURN jsonb_build_object('cases', v_out);
END $$;
