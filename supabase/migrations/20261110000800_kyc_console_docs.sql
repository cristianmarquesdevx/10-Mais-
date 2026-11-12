-- 10 é + — a operação PRECISA VER o documento e saber QUEM é o parceiro.
--
-- O console da operação (`app/console`) nasceu com a fila e a decisão, mas
-- sem as duas coisas que fazem o trabalho de quem opera ser POSSÍVEL:
--
--   1. o DOCUMENTO. A operação recebia só os metadados ("ARQUIVO OK") e
--      aprovava uma CNH que nunca tinha visto. O bucket é privado e a
--      política de leitura era do DONO — a operação não podia nem baixar
--      o arquivo que precisa julgar;
--   2. o NOME. A fila mostrava "Parceiro 77777777" (uuid truncado). O
--      nome e o telefone do parceiro JÁ EXISTEM no banco (`profiles.full_name`
--      e `users.phone_e164`) — ninguém os lia.
--
-- A correção é em DUAS pontas:
--
--   * o Postgres devolve o `storage_path` dos documentos e a identidade do
--     parceiro (as funções `api_kyc_case_get` e `api_kyc_queue` são
--     recriadas aqui);
--   * o bucket libera a LEITURA para o papel AGENT/ADMIN, e só para ele.
--
-- A OPERAÇÃO CONTINUA SEM SERVICE ROLE: ela lê o objeto com o PRÓprio token
-- (o JWT do agente) direto do Storage REST. A RLS é quem autoriza — o
-- mesmo mecanismo que já protege o resto do bucket. E o parceiro NÃO pode
-- ler o documento de outro: a política exige papel de operação, e não
-- "ser alguém logado".
--
-- O que NÃO muda: o bucket continua privado (`public = false`), a escrita
-- continua sendo só do dono, e a exclusão também.

-- -----------------------------------------------------------------------------
-- 1. A política de LEITURA: o dono E a operação.
--
-- `app_is_agent()` é SECURITY DEFINER (le `users.role`, que só o trigger
-- escreve) — é o mesmo gancho que as políticas de `users` já usam.
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  IF to_regclass('storage.objects') IS NULL THEN
    RAISE NOTICE 'schema storage.objects ausente: a política de leitura da operação será criada quando o Storage existir';
    RETURN;
  END IF;

  BEGIN
    EXECUTE 'DROP POLICY IF EXISTS kyc_docs_select ON storage.objects';
    EXECUTE 'CREATE POLICY kyc_docs_select ON storage.objects
               FOR SELECT TO authenticated
               USING (bucket_id = ''kyc-docs''
                      AND ((storage.foldername(name))[2] = auth.uid()::text
                           OR app_is_agent()))';
  EXCEPTION WHEN insufficient_privilege THEN
    RAISE EXCEPTION
      'sem permissão para criar a politica de leitura do KYC em storage.objects: o DDL de politica exige o DONO da tabela (no Supabase, a role supabase_storage_admin) ou PostgreSQL 17+'
      USING ERRCODE = '42501',
            HINT = 'aplique o DDL de politica com um usuario dono de storage.objects (ou atualize o projeto para PostgreSQL 17+)';
  END;
END $$;

-- -----------------------------------------------------------------------------
-- 2. O caso com a documentação — agora com o ARQUIVO e a IDENTIDADE.
--
-- O `storage_path` devolvido é o NOME do objeto no bucket privado (sem
-- barra inicial). Quem mostra a imagem é o app, com o token do chamador:
-- o parceiro lê o próprio, a operação lê o de qualquer um (a RLS acima).
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

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'doc_type', d.doc_type,
           'created_at', d.created_at,
           -- O caminho do arquivo: o app monta a URL do bucket com o token
           -- do chamador. `PENDENTE/...` é o marcador honesto do registro
           -- SEM arquivo — não é um objeto, e por isso não vira URL.
           'storage_path', NULLIF(d.storage_path, ''),
           'has_file', (d.storage_path NOT LIKE 'PENDENTE/%'
                        AND d.storage_path IS NOT NULL),
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
-- 3. A fila — a mesma identidade, para a pessoa da operação saber de quem
--    é o cadastro ANTES de abrir.
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

  SELECT COALESCE(jsonb_agg(row_to_json(q) ORDER BY q.sla_due_at, q.created_at), '[]'::jsonb)
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
       LIMIT LEAST(GREATEST(COALESCE(p_limit, 50), 1), 200)
    ) q;

  RETURN jsonb_build_object('cases', v_out);
END $$;
