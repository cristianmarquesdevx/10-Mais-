-- =============================================================================
-- 10 é + — KYC no Postgres (fila, SLA e decisão)
--
-- Antes desta migração o KYC era um stub: a API de demonstração aprovava o
-- cadastro na hora, num estado global, e o banco tinha as tabelas
-- (`kyc_cases`, `kyc_documents`) sem nenhuma regra de negócio — sem fila,
-- sem SLA, sem decisão, sem rastro. O parceiro que se cadastrava ficava
-- "aprovado" sem que ninguém olhasse documento algum.
--
-- Aqui o KYC vira regra do servidor, no mesmo padrão do ciclo de corrida:
-- a Edge Function `kyc` é uma FACHADA FINA (repasse do `Authorization` do
-- chamador ao PostgREST) e TODA a decisão mora aqui, em `api_*`.
--
-- O que a migração entrega:
--   1. `APPROVED` entra no vocabulário do caso (aprovação manual por um
--      agente da operação). O enum original não tinha como representar o
--      resultado de uma fila humana — o caminho manual não tinha destino.
--   2. `fn_kyc_sla_due`: o prazo da análise manual, calculado no fuso da
--      praça e dentro da JANELA HUMANA de revisão (parâmetros da cidade).
--   3. `fn_kyc_queue_position`: a posição na fila (1 = próximo).
--   4. `api_kyc_case_create` / `api_kyc_case_get` / `api_kyc_case_document`:
--      o que o PARCEIRO pode fazer (abrir caso, acompanhar, reenviar).
--   5. `api_kyc_queue` / `api_kyc_review`: o que só um AGENTE pode fazer
--      (ver a fila, decidir). A decisão sincroniza `partners.kyc_status`,
--      grava `audit_log`, notifica o parceiro e emite `kyc.decided`.
--
-- T7: nenhum número do comportamento está no código — a janela humana, o
-- fim da janela e a antecedência mínima do SLA saem de `city_configs`.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. O caso passa a ter o mesmo vocabulário que o parceiro.
--
-- `partners.kyc_status` já aceitava 'APPROVED'; `kyc_cases.status` não. Um
-- caso aprovado por um agente não tinha como ser gravado — a fila humana
-- não tinha destino no banco.
-- -----------------------------------------------------------------------------
ALTER TABLE kyc_cases DROP CONSTRAINT IF EXISTS kyc_cases_status_check;
ALTER TABLE kyc_cases ADD CONSTRAINT kyc_cases_status_check
  CHECK (status IN ('AUTO_APPROVED','APPROVED','IN_REVIEW','REJECTED','RESUBMIT'));

-- O catálogo de eventos é o contrato de BI: o novo status entra nele.
UPDATE event_catalog
   SET payload_schema = '{"status":"AUTO_APPROVED|APPROVED|IN_REVIEW|REJECTED|RESUBMIT","reason":"string?"}'
 WHERE version = 1 AND event_type = 'kyc.decided';

INSERT INTO event_catalog(version, event_type, description, payload_schema)
VALUES (1, 'kyc.resubmitted', 'Partner re-submitted KYC documents after rejection',
        '{"case_id":"uuid","doc_type":"string"}')
ON CONFLICT (version, event_type) DO NOTHING;

-- -----------------------------------------------------------------------------
-- 2. O SLA da análise manual.
--
-- Regra: o prazo é o PRIMEIRO instante, a partir de agora, que
--   (a) respeita a antecedência mínima (`PRM-kyc.sla_antecedencia_h`), e
--   (b) cai DENTRO da janela humana de revisão
--       (`PRM-kyc.review_inicio_h` .. `PRM-kyc.review_fim_h`), no fuso da
--       praça.
--
-- Por que a janela humana importa: o prazo é uma promessa de atendimento,
-- não um temporizador. Prometer "2 h" às 23h30 — quando não há gente
-- reviewing — seria uma promessa falsa; o prazo cai na primeira abertura da
-- janela seguinte que ainda cumpre a antecedência.
--
-- O relógio é o do servidor (o fuso da cidade), nunca o do aparelho.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_kyc_sla_due(p_city uuid, p_from timestamptz DEFAULT now())
RETURNS timestamptz
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_tz    text;
  v_inicio int;
  v_fim    int;
  v_lead   int;
  v_d      date;
  v_open   timestamptz;
  v_close  timestamptz;
  v_due    timestamptz;
BEGIN
  SELECT c.timezone INTO v_tz FROM cities c WHERE c.id = p_city;
  v_tz := COALESCE(v_tz, 'America/Porto_Velho');

  v_inicio := (city_param(p_city,'PRM-kyc.review_inicio_h','7')  #>> '{}')::int;
  v_fim    := (city_param(p_city,'PRM-kyc.review_fim_h','23')   #>> '{}')::int;
  v_lead   := (city_param(p_city,'PRM-kyc.sla_antecedencia_h','2') #>> '{}')::int;

  IF v_inicio < 0 OR v_fim > 24 OR v_inicio >= v_fim THEN
    RAISE EXCEPTION 'janela humana de revisão inválida (%..%)', v_inicio, v_fim;
  END IF;

  -- Procura, dia a dia, a primeira janela que ainda pode conter o prazo.
  FOR i IN 0..14 LOOP
    v_d     := (p_from AT TIME ZONE v_tz)::date + i;
    v_open  := (v_d + make_interval(hours => v_inicio)) AT TIME ZONE v_tz;
    v_close := (v_d + make_interval(hours => v_fim))    AT TIME ZONE v_tz;

    -- Janela já closed antes da antecedência mínima: tenta o dia seguinte.
    CONTINUE WHEN v_close <= p_from + make_interval(hours => v_lead);

    v_due := GREATEST(v_open, p_from + make_interval(hours => v_lead));
    RETURN v_due;
  END LOOP;

  -- Rede de segurança (14 dias sem janela livre): devolve a antecedência
  -- mínima, mas o caso fica visível na fila como atrasado.
  RETURN p_from + make_interval(hours => v_lead);
END $$;

-- -----------------------------------------------------------------------------
-- 3. Posição na fila (1 = o próximo a ser analysado).
--
-- A fila é ordenada pelo prazo (o índice parcial `idx_kyc_queue`); o empate
-- do prazo é desfeito pela hora de entrada, para a ordem ser estável.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_kyc_queue_position(p_case uuid)
RETURNS integer
LANGUAGE sql STABLE AS $$
  SELECT count(*)::int
    FROM kyc_cases q
   WHERE q.status IN ('IN_REVIEW','RESUBMIT')
     AND (q.sla_due_at, q.created_at, q.id) <= (
           SELECT c.sla_due_at, c.created_at, c.id
             FROM kyc_cases c WHERE c.id = p_case);
$$;

-- -----------------------------------------------------------------------------
-- 4. O PARCEIRO abre o caso.
--
-- Idempotente por natureza: quem já tem um caso em aberto (em análise,
-- reenviado ou recusado) recebe o MESMO caso de volta — um duplo toque no
-- botão "Enviar documentação" não cria duas filas.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api_kyc_case_create()
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_uid     uuid := app_uid();
  v_partner partners%ROWTYPE;
  v_case    kyc_cases%ROWTYPE;
  v_sla     timestamptz;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated' USING ERRCODE = '28000';
  END IF;

  SELECT * INTO v_partner FROM partners p
   WHERE p.user_id = v_uid AND p.deleted_at IS NULL;
  IF v_partner.user_id IS NULL THEN
    RAISE EXCEPTION 'not_a_partner' USING ERRCODE = '42501';
  END IF;

  -- 1) Caso em aberto (em análise, reenviado ou recusado): devolve o mesmo.
  SELECT * INTO v_case
    FROM kyc_cases c
   WHERE c.partner_user_id = v_uid
     AND c.status IN ('IN_REVIEW','RESUBMIT','REJECTED')
   ORDER BY c.created_at DESC
   LIMIT 1;

  IF FOUND THEN
    RETURN jsonb_build_object(
      'case_id', v_case.id,
      'status',  v_case.status,
      'position', CASE WHEN v_case.status IN ('IN_REVIEW','RESUBMIT')
                       THEN fn_kyc_queue_position(v_case.id) END,
      'sla',     v_case.sla_due_at);
  END IF;

  -- 2) Já aprovado: não há nada a fazer. Devolve o caso aprovado (criando um
  --    registro de caso se o parceiro veio do seed antigo, que não tinha
  --    linha em `kyc_cases`) — sem inventar um prazo que não existe.
  IF v_partner.kyc_status = 'APPROVED' THEN
    SELECT * INTO v_case
      FROM kyc_cases c
     WHERE c.partner_user_id = v_uid
       AND c.status IN ('APPROVED','AUTO_APPROVED')
     ORDER BY c.created_at DESC
     LIMIT 1;

    IF NOT FOUND THEN
      INSERT INTO kyc_cases (partner_user_id, status, decided_at)
      VALUES (v_uid, 'APPROVED', now())
      RETURNING * INTO v_case;
    END IF;

    RETURN jsonb_build_object(
      'case_id', v_case.id, 'status', v_case.status,
      'position', NULL, 'sla', NULL);
  END IF;

  -- 3) Novo caso: entra na fila manual, com prazo.
  v_sla := fn_kyc_sla_due(v_partner.city_id, now());

  INSERT INTO kyc_cases (partner_user_id, status, sla_due_at)
  VALUES (v_uid, 'IN_REVIEW', v_sla)
  RETURNING * INTO v_case;

  UPDATE partners p SET kyc_status = 'IN_REVIEW' WHERE p.user_id = v_uid;

  RETURN jsonb_build_object(
    'case_id',  v_case.id,
    'status',   v_case.status,
    'position', fn_kyc_queue_position(v_case.id),
    'sla',      v_case.sla_due_at);
END $$;

-- -----------------------------------------------------------------------------
-- 5. O PARCEIRO acompanha o seu caso.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api_kyc_case_get(p_case uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_uid  uuid := app_uid();
  v_case kyc_cases%ROWTYPE;
  v_docs jsonb;
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

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'doc_type', d.doc_type,
           'created_at', d.created_at,
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
    'documents', v_docs));
END $$;

-- -----------------------------------------------------------------------------
-- 6. O PARCEIRO reenvia a documentação (após uma recusa).
--
-- O reenvio devolve o caso para a fila com um NOVO prazo (o relógio andou) e
-- limpa o motivo da recusa — o histórico fica em `audit_log`.
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

  -- O app ainda NÃO envia o arquivo (a captura guiada é o módulo F9): o que
  -- chega aqui é a referência do documento. Sem `storage_path`, a referência
  -- fica marcada como pendente — o registro é honesto, não finge download.
  v_path := NULLIF(btrim(COALESCE(p_storage_path,'')), '');
  v_flags := COALESCE(p_quality_flags, '{}'::jsonb);
  IF v_path IS NULL THEN
    v_path  := 'PENDENTE/' || v_case.id::text || '/' || p_doc_type;
    v_flags := v_flags || jsonb_build_object('upload_pending', true);
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
-- 7. A OPERAÇÃO vê a fila (só agente).
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
             c.status,
             c.sla_due_at,
             c.created_at,
             fn_kyc_queue_position(c.id) AS position,
             (SELECT count(*)::int FROM kyc_documents d WHERE d.case_id = c.id) AS documents
        FROM kyc_cases c
       WHERE c.status IN ('IN_REVIEW','RESUBMIT')
       LIMIT LEAST(GREATEST(COALESCE(p_limit, 50), 1), 200)
    ) q;

  RETURN jsonb_build_object('cases', v_out);
END $$;

-- -----------------------------------------------------------------------------
-- 8. A OPERAÇÃO decide (só agente).
--
-- A decisão é o ato que muda o mundo: `partners.kyc_status` passa a valer
-- para o despacho (só `APPROVED` recebe oferta), o caso sai (ou volta) para
-- a fila, o rastro vai para `audit_log`, o parceiro é notificado e o evento
-- `kyc.decided` é emitido para o BI.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api_kyc_review(
  p_case uuid,
  p_decision text,
  p_rejection_code text DEFAULT NULL,
  p_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_uid    uuid := app_uid();
  v_case   kyc_cases%ROWTYPE;
  v_before jsonb;
  v_status text;
  v_city   uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not_authenticated' USING ERRCODE = '28000';
  END IF;
  IF NOT app_is_agent() THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF p_decision IS NULL
     OR p_decision NOT IN ('APPROVED','REJECTED','RESUBMIT') THEN
    RAISE EXCEPTION 'invalid_decision' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_case FROM kyc_cases c WHERE c.id = p_case;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'kyc_case_not_found' USING ERRCODE = 'P0002';
  END IF;
  IF v_case.status NOT IN ('IN_REVIEW','RESUBMIT') THEN
    RAISE EXCEPTION 'kyc_case_not_in_queue' USING ERRCODE = '22023';
  END IF;

  -- Recusa sem motivo padronizado é recusa sem ação possível para o
  -- parceiro: o código do motivo é o que a tela mostra.
  IF p_decision IN ('REJECTED','RESUBMIT')
     AND NULLIF(btrim(COALESCE(p_rejection_code,'')), '') IS NULL THEN
    RAISE EXCEPTION 'rejection_code_required' USING ERRCODE = '22023';
  END IF;

  SELECT p.kyc_status INTO v_status FROM partners p WHERE p.user_id = v_case.partner_user_id;
  v_before := jsonb_build_object('case_status', v_case.status, 'partner_kyc_status', v_status);
  SELECT p.city_id INTO v_city FROM partners p WHERE p.user_id = v_case.partner_user_id;

  UPDATE kyc_cases c
     SET status = p_decision,
         decided_at = now(),
         decided_by = v_uid,
         assigned_agent_id = v_uid,
         rejection_code = NULLIF(btrim(COALESCE(p_rejection_code,'')), ''),
         -- Aprovado ou recusado: sai da fila. Reenvio pedido: volta para a
         -- fila com prazo novo (o relógio andou desde a última promessa).
         sla_due_at = CASE WHEN p_decision = 'RESUBMIT'
                           THEN fn_kyc_sla_due(v_city, now()) ELSE NULL END
   WHERE c.id = v_case.id
   RETURNING * INTO v_case;

  UPDATE partners p
     SET kyc_status = p_decision
   WHERE p.user_id = v_case.partner_user_id;

  INSERT INTO audit_log (actor_user_id, action, entity_type, entity_id, before_data, after_data)
  VALUES (v_uid, 'KYC_DECIDED', 'kyc_case', v_case.id::text,
          v_before,
          jsonb_build_object('case_status', v_case.status,
                             'partner_kyc_status', p_decision,
                             'rejection_code', v_case.rejection_code,
                             'note', NULLIF(btrim(COALESCE(p_note,'')), '')));

  INSERT INTO notifications (user_id, channel, type, payload)
  VALUES (v_case.partner_user_id, 'IN_APP', 'KYC_DECIDED',
          jsonb_build_object('case_id', v_case.id,
                             'status', v_case.status,
                             'rejection_code', v_case.rejection_code,
                             'note', NULLIF(btrim(COALESCE(p_note,'')), '')));

  PERFORM fn_emit_event(NULL, 'kyc.decided',
    jsonb_build_object('status', v_case.status, 'reason', v_case.rejection_code),
    v_uid, 'kyc-decided:' || v_case.id || ':' || v_case.status);

  RETURN jsonb_build_object(
    'case_id', v_case.id,
    'status', v_case.status,
    'partner_kyc_status', p_decision);
END $$;

-- -----------------------------------------------------------------------------
-- 9. GRANTS — a API do KYC é do `authenticated`; `anon` não entra.
--
-- (As checagens de dono e de papel estão DENTRO de cada função, porque
-- SECURITY DEFINER ignora RLS: o token define o ator, o corpo não define
-- nada.)
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
                         'api_kyc_case_document','api_kyc_queue','api_kyc_review')
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon', f.sig);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated, service_role', f.sig);
  END LOOP;
END $$;
