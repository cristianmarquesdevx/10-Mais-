#!/usr/bin/env bash
# =============================================================================
# 10 é + — CI da CADEIA DE DEPLOY (supabase/migrations) em container limpo.
#
# A suíte `ci_db_suite.sh` cobre a cadeia de desenvolvimento da Fase 2
# (docs/fase2/0001→0005). Esta cobre a cadeia que realmente vai para o banco
# (`supabase/migrations/*.sql`), que é o que o `supabase db push` aplica.
#
# O que valida (fail com exit != 0 em qualquer uma):
#   1. A cadeia inteira aplica do ZERO num Postgres+PostGIS limpo, com
#      ON_ERROR_STOP (SQL inválido ou erro de execução aborta na hora).
#   2. O schema `auth` do GoTrue é stubado (scripts/supabase_auth_stub.sql):
#      fora do Supabase, as migrations de identidade precisam da tabela.
#   3. O schema `storage` do Storage é stubado (scripts/supabase_storage_stub.sql):
#      fora do Supabase, a migration do KYC precisa do bucket e das políticas.
#   4. As funções que as Edge Functions chamam existem com a assinatura
#      esperada — a função `rides` quebra se o PostgREST não achar o RPC.
#   5. A cotação congelada existe (tabela + funções) e o despacho usa o
#      código de serviço real (RIDE_CAR), não o nome legado de moto.
#
# Ambiente: container efêmero PostGIS 16 (descartado ao fim, salvo KEEP_DB=1).
# =============================================================================
set -euo pipefail

IMAGE="${MIGRATIONS_IMAGE:-postgis/postgis:16-3.4}"
NAME="${MIGRATIONS_NAME:-dezemais-migrations-$$}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KEEP_DB="${KEEP_DB:-0}"
LOG="$(mktemp -t dezemais-migrations.XXXXXX)"
trap 'if [ "$KEEP_DB" = "1" ]; then echo "[mig] KEEP_DB=1 -> container $NAME mantido"; else docker rm -f "$NAME" >/dev/null 2>&1 || true; fi; rm -f "$LOG"' EXIT

say() { printf '[mig] %s\n' "$*"; }
fail() { echo "[mig] ASSERT FALHOU: $*" >&2; tail -60 "$LOG" >&2; exit 1; }

say "subindo $IMAGE ($NAME)"
docker run -d --name "$NAME" \
  -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=dezemais \
  "$IMAGE" >/dev/null

# O init do postgis/postgis recria o cluster (create extension + restart),
# então pg_isready cedo é falso positivo: exige estabilidade + postgis.
ready=0
for _ in $(seq 1 90); do
  if docker exec "$NAME" pg_isready -U postgres -d dezemais >/dev/null 2>&1; then
    if docker exec "$NAME" psql -U postgres -d dezemais -Atc \
        "SELECT extname FROM pg_extension WHERE extname='postgis'" 2>/dev/null \
        | grep -q postgis; then
      ready=$((ready + 1))
      [ "$ready" -ge 3 ] && break
    else
      ready=0
    fi
  fi
  sleep 1
done
if [ "$ready" -lt 3 ]; then
  echo "[mig] FALHA: container não estabilizou em 90s" >&2
  docker logs "$NAME" 2>&1 | tail -40 >&2
  exit 1
fi
say "container estável (postgis ok)"

psql_c() { docker exec -i "$NAME" psql -U postgres -d dezemais -v ON_ERROR_STOP=1 "$@"; }

run_file() {
  local f="$1"
  say "executando $(basename "$f")"
  if ! docker exec -i "$NAME" psql -U postgres -d dezemais -v ON_ERROR_STOP=1 \
      < "$f" >>"$LOG" 2>&1; then
    echo "[mig] FALHOU em $(basename "$f") — últimas linhas:" >&2
    tail -60 "$LOG" >&2
    exit 1
  fi
}

# O schema `auth` é do GoTrue: fora do Supabase, ele é stubado para que as
# migrations de identidade (trigger auth.users → users/profiles) apliquem.
run_file "$ROOT/scripts/supabase_auth_stub.sql"

# O schema `storage` é do Storage (serviço de arquivos): fora do Supabase, ele
# é stubado para que a migration do KYC (bucket privado + RLS por dono +
# conferência do objeto no bucket) aplique. O stub precisa vir ANTES das
# migrations: as políticas usam `storage.foldername`, que só existe depois
# dele.
run_file "$ROOT/scripts/supabase_storage_stub.sql"

# A cadeia de deploy, em ordem de nome (timestamp no prefixo).
count=0
for f in $(ls "$ROOT"/supabase/migrations/*.sql | sort); do
  run_file "$f"
  count=$((count + 1))
done
say "$count migrations aplicadas sem erro"

# --- asserts -----------------------------------------------------------------

# 1) Tabelas que o produto precisa.
for t in users rides offers payments ledger_entries ride_quotes partner_presence; do
  psql_c -Atc "SELECT to_regclass('public.$t')" | grep -q "$t" \
    || fail "tabela $t não existe"
done

# 2) As RPCs que a Edge Function `rides` chama (mesma assinatura do código).
check_sig() {
  psql_c -Atc "SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                WHERE n.nspname='public' AND p.proname='$1' AND p.pronargs=$2" \
    | grep -qx "$3" || fail "função $1 com $2 argumentos não encontrada"
}
check_sig api_quote 2 1
check_sig api_ride_request 8 1
check_sig api_ride_get 1 1
check_sig api_ride_cancel 2 1
check_sig api_rides_mine 1 1
check_sig api_ride_dispatch 1 1
check_sig api_offer_accept 1 1
check_sig api_offer_decline 1 1
check_sig api_offer_get 1 1
check_sig api_offers_mine 0 1
check_sig api_ride_transition 4 1
check_sig api_payment_intent 2 1
check_sig api_payment_get_by_ride 1 1
check_sig api_ride_rate 4 1
check_sig fn_quote_resolve 4 1

# 3) A cotação congelada: as colunas que o preço gravado precisa.
psql_c -Atc "SELECT count(*) FROM information_schema.columns
              WHERE table_schema='public' AND table_name='ride_quotes'
                AND column_name IN ('id','expires_at','fare_total','user_id')" \
  | grep -qx 4 || fail "ride_quotes sem as colunas de cotação"

# 4) O despacho usa o código de serviço real (não o 'MOTO' legado).
if psql_c -Atc "SELECT prosrc FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                 WHERE n.nspname='public' AND p.proname='fn_dispatch_evaluate'" \
     | grep -q "MOTO_NEGOCIA"; then
  fail "fn_dispatch_evaluate ainda usa o serviço legado MOTO_NEGOCIA"
fi
psql_c -Atc "SELECT prosrc FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
              WHERE n.nspname='public' AND p.proname='fn_dispatch_evaluate'" \
  | grep -q "service_type_id" || fail "fn_dispatch_evaluate não casa o veículo pelo service_type_id"

# 5) Ledger começa zerado (nada foi lançado por migração).
sum=$(psql_c -Atc "SELECT to_char(COALESCE(SUM(CASE WHEN direction='C' THEN amount ELSE -amount END),0), 'FM999999990.00')
                     FROM ledger_entries" | tail -1)
[ "$sum" = "0.00" ] || fail "ledger soma $sum (esperado 0.00)"

# 6) A janela da oferta fica presa ao contrato (15 s na cidade piloto).
#
# Teste FUNCIONAL, não grep: a trava é um trigger, e o que importa é que
# uma config divergente seja recusada na hora de gravar. Foi assim que o
# banco local ficou com a janela em 60 s (4× mais espera para o passageiro)
# enquanto o SPEC, o seed e a API de demonstração diziam 15 s.
psql_c -Atc "INSERT INTO cities (id, name, uf, status, timezone)
             VALUES ('99999999-9999-4999-8999-999999999999', 'Cidade do Teste',
                     'RO', 'PILOT', 'America/Porto_Velho')" >/dev/null
psql_c -Atc "INSERT INTO city_configs (city_id, param_key, param_value, valid_from)
             VALUES ('99999999-9999-4999-8999-999999999999',
                     'PRM-oferta.timeout', '15'::jsonb, now())" >/dev/null
if psql_c -Atc "UPDATE city_configs SET param_value = '60'::jsonb
                WHERE city_id = '99999999-9999-4999-8999-999999999999'
                  AND param_key = 'PRM-oferta.timeout'" >/dev/null 2>&1; then
  fail "a janela da oferta aceitou 60 s na cidade piloto (contrato: 15 s)"
fi
janela=$(psql_c -Atc "SELECT param_value FROM city_config_current
                       WHERE city_id = '99999999-9999-4999-8999-999999999999'
                         AND param_key = 'PRM-oferta.timeout'" | tail -1)
[ "$janela" = "15" ] || fail "janela da oferta na cidade piloto = $janela (esperado 15)"

# 7) O KYC do parceiro no Postgres (SPECS §6): fila, SLA e decisão.
#
# A Edge Function `kyc` é uma fachada FINA: se estas funções não existirem
# (ou com outra assinatura), o cadastro do parceiro quebra em produção — e
# o erro só apareceria na hora de um cadastro de verdade.
check_sig fn_kyc_sla_due 2 1
check_sig fn_kyc_queue_position 1 1
check_sig api_kyc_case_create 0 1
check_sig api_kyc_case_get 1 1
check_sig api_kyc_case_document 5 1
check_sig api_kyc_queue 1 1
check_sig api_kyc_review 4 1
# O console da operação confere o PAPEL da conta antes da fila: a função
# `api_kyc_me` é a fonte da verdade (vem do `users.role`, que só o trigger
# escreve). Sem ela, a rota `/me` do console quebra em produção.
check_sig api_kyc_me 0 1

# A aprovação MANUAL precisa caber no vocabulário do caso: sem ela, a fila
# humana não tem destino no banco (o caso aprovado não pode ser gravado).
psql_c -Atc "INSERT INTO users (id, phone_e164, role)
             VALUES ('88888888-8888-4888-8888-888888888888', '+5596990000008', 'PARTNER')" >/dev/null
psql_c -Atc "INSERT INTO partners (user_id, city_id)
             VALUES ('88888888-8888-4888-8888-888888888888',
                     '99999999-9999-4999-8999-999999999999')" >/dev/null
if ! psql_c -Atc "INSERT INTO kyc_cases (partner_user_id, status)
                  VALUES ('88888888-8888-4888-8888-888888888888', 'APPROVED')" >/dev/null 2>&1; then
  fail "kyc_cases não aceita o status APPROVED (aprovação manual pela operação)"
fi

# O SLA é lido da CONFIG da cidade (T7): a janela humana e a antecedência
# mudam o prazo, e o prazo nunca cai fora da janela.
psql_c -Atc "INSERT INTO city_configs (city_id, param_key, param_value, valid_from) VALUES
               ('99999999-9999-4999-8999-999999999999', 'PRM-kyc.review_inicio_h', '9'::jsonb, now()),
               ('99999999-9999-4999-8999-999999999999', 'PRM-kyc.review_fim_h', '18'::jsonb, now()),
               ('99999999-9999-4999-8999-999999999999', 'PRM-kyc.sla_antecedencia_h', '3'::jsonb, now())" >/dev/null
sla=$(psql_c -Atc "
  WITH d AS (SELECT fn_kyc_sla_due('99999999-9999-4999-8999-999999999999'::uuid, now()) AS due)
  SELECT CASE WHEN due >= now() + interval '3 hours'
                   AND EXTRACT(HOUR FROM (due AT TIME ZONE 'America/Porto_Velho')) >= 9
                   AND EXTRACT(HOUR FROM (due AT TIME ZONE 'America/Porto_Velho')) < 18
              THEN 'ok' ELSE 'fora: ' || due::text END
    FROM d" | tail -1)
[ "$sla" = "ok" ] || fail "o SLA do KYC não respeitou a janela/antecedência da cidade ($sla)"

# 8) O Storage do KYC: bucket privado, RLS por dono e referência verificada.
#
# O documento do parceiro é um arquivo de verdade: o bucket é privado, cada
# um só enxerga a própria pasta (`kyc/<uid>/...`) e o servidor recusa uma
# referência que não aponta para um objeto existente.
bucket_public=$(psql_c -Atc "SELECT public FROM storage.buckets WHERE id = 'kyc-docs'" | tail -1)
[ "$bucket_public" = "f" ] \
  || fail "o bucket kyc-docs não existe ou não é privado (public = '$bucket_public')"

pol=$(psql_c -Atc "SELECT count(*) FROM pg_policies
                   WHERE schemaname = 'storage' AND tablename = 'objects'
                     AND policyname IN ('kyc_docs_select','kyc_docs_insert',
                                        'kyc_docs_update','kyc_docs_delete')" | tail -1)
[ "$pol" = "4" ] || fail "faltam políticas de RLS do bucket kyc-docs ($pol/4)"

# A política precisa restringir ao bucket E ao dono — uma policy "USING (true)"
# passaria no count acima e abriria a pasta de todo mundo.
qual=$(psql_c -Atc "SELECT qual FROM pg_policies
                    WHERE schemaname = 'storage' AND tablename = 'objects'
                      AND policyname = 'kyc_docs_select'" | tail -1)
echo "$qual" | grep -q "kyc-docs" \
  || fail "a política de leitura do KYC não restringe ao bucket kyc-docs ($qual)"
echo "$qual" | grep -q "auth.uid()" \
  || fail "a política de leitura do KYC não restringe ao dono (auth.uid()) ($qual)"
# A OPERAÇÃO também precisa ler: sem `app_is_agent()`, o console aprova uma
# CNH que nunca viu (o documento fica no bucket, e o console não baixa).
echo "$qual" | grep -q "app_is_agent()" \
  || fail "a política de leitura do KYC não libera o papel de operação (app_is_agent) ($qual)"

# 9) O comportamento FUNCIONAL do Storage do KYC.
#
# No CI, `auth.uid()` é o stub da migration `20261024000200_rls_states_events.sql`
# (ele lê a GUC `app.test_uid`) — o mesmo gancho do `request.jwt.claims` do
# GoTrue em produção. Dá para chamar a API COMO O PARCEIRO e provar o que
# importa: path de outro dono é recusado, path de objeto inexistente é
# recusado, path de objeto existente é aceito, e o modo sem path (demo) segue
# gravando o marcador honesto `PENDENTE/...`.
if ! psql_c -At <<'SQL'
DO $test$
DECLARE
  v_uid    uuid := 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
  v_outro  uuid := 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
  v_cidade uuid := '99999999-9999-4999-8999-999999999999';
  v_case   uuid;
  v_path   text;
  v_state  text;
  v_msg    text;
  v_ok     boolean;
  v_doc    record;
BEGIN
  -- A identidade do chamador (no CI: a GUC `app.test_uid`).
  PERFORM set_config('app.test_uid', v_uid::text, false);

  INSERT INTO users (id, phone_e164, role)
  VALUES (v_uid, '+5596990000077', 'PARTNER')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO partners (user_id, city_id)
  VALUES (v_uid, v_cidade)
  ON CONFLICT (user_id) DO NOTHING;

  INSERT INTO kyc_cases (partner_user_id, status)
  VALUES (v_uid, 'IN_REVIEW')
  RETURNING id INTO v_case;

  v_path := 'kyc/' || v_uid::text || '/' || v_case::text || '/CNH_1700000000000.jpg';

  -- O objeto existe no bucket (o stub do Storage).
  INSERT INTO storage.objects (bucket_id, name, owner)
  VALUES ('kyc-docs', v_path, v_uid);

  -- (1) Path de OUTRO dono -> recusado.
  v_ok := false; v_state := ''; v_msg := '';
  BEGIN
    PERFORM api_kyc_case_document(v_case, 'CNH',
      'kyc/' || v_outro::text || '/' || v_case::text || '/CNH_1.jpg');
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    v_ok := true;
  END;
  IF NOT v_ok THEN
    RAISE EXCEPTION 'o path de outro dono foi ACEITO (deveria recusar)';
  END IF;
  IF v_state <> '22023' OR v_msg NOT LIKE '%storage_path_not_owned%' THEN
    RAISE EXCEPTION 'path de outro dono: esperava 22023/storage_path_not_owned, veio % / %',
      v_state, v_msg;
  END IF;

  -- (2) Path do dono, objeto INEXISTENTE -> recusado.
  v_ok := false; v_state := ''; v_msg := '';
  BEGIN
    PERFORM api_kyc_case_document(v_case, 'CRLV',
      'kyc/' || v_uid::text || '/' || v_case::text || '/CRLV_1700000000001.jpg');
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    v_ok := true;
  END;
  IF NOT v_ok THEN
    RAISE EXCEPTION 'o path de objeto inexistente foi ACEITO (deveria recusar)';
  END IF;
  IF v_state <> '22023' OR v_msg NOT LIKE '%document_not_found%' THEN
    RAISE EXCEPTION 'path de objeto inexistente: esperava 22023/document_not_found, veio % / %',
      v_state, v_msg;
  END IF;

  -- (3) Path do dono, objeto EXISTENTE -> aceito, com `upload_pending` falso
  --     e as flags de qualidade do app preservadas.
  PERFORM api_kyc_case_document(v_case, 'CNH', v_path, NULL,
                                 '{"blur": false, "reflexo": true}'::jsonb);
  SELECT storage_path, quality_flags INTO v_doc
    FROM kyc_documents
   WHERE case_id = v_case AND doc_type = 'CNH'
   ORDER BY created_at DESC LIMIT 1;
  IF v_doc.storage_path <> v_path THEN
    RAISE EXCEPTION 'o path aceito não foi gravado: %', v_doc.storage_path;
  END IF;
  IF (v_doc.quality_flags->>'upload_pending')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'upload_pending deveria ser false no path real: %', v_doc.quality_flags;
  END IF;
  IF (v_doc.quality_flags->>'reflexo')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'a flag de qualidade do app foi perdida: %', v_doc.quality_flags;
  END IF;

  -- (4) Sem path (modo demo/legado) -> continua o registro honesto.
  PERFORM api_kyc_case_document(v_case, 'SELFIE', NULL);
  SELECT storage_path, quality_flags INTO v_doc
    FROM kyc_documents
   WHERE case_id = v_case AND doc_type = 'SELFIE'
   ORDER BY created_at DESC LIMIT 1;
  IF v_doc.storage_path NOT LIKE 'PENDENTE/%' THEN
    RAISE EXCEPTION 'o modo sem path não gravou o marcador PENDENTE: %', v_doc.storage_path;
  END IF;
  IF (v_doc.quality_flags->>'upload_pending')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'no modo sem path, upload_pending deveria ser true: %', v_doc.quality_flags;
  END IF;
END
$test$;
SQL
then
  fail "a API do KYC não comportou o Storage como o contrato exige (ver o erro acima)"
fi

# 10) O console da operação precisa de DUAS coisas que a fila não tinha:
#     a IDENTIDADE do parceiro (nome e telefone) e o CAMINHO do documento.
#     Sem elas, a tela mostra "Parceiro 77777777" e aprova um cadastro sem
#     ver a foto.
if ! psql_c -At <<'SQL'
DO $test$
DECLARE
  v_agente   uuid := 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee';
  v_parceiro uuid := '88888888-8888-4888-8888-888888888888';
  v_case     uuid;
  v_fila     jsonb;
  v_detalhe  jsonb;
  v_caso     jsonb;
  v_doc      jsonb;
  v_path     text;
BEGIN
  INSERT INTO users (id, phone_e164, role)
  VALUES (v_agente, '+5596990000009', 'AGENT')
  ON CONFLICT (id) DO NOTHING;
  INSERT INTO profiles (user_id, full_name)
  VALUES (v_parceiro, 'Parceiro de Teste')
  ON CONFLICT (user_id) DO NOTHING;

  -- A identidade do chamador é a operação (no CI: a GUC `app.test_uid`).
  PERFORM set_config('app.test_uid', v_agente::text, false);

  INSERT INTO kyc_cases (partner_user_id, status)
  VALUES (v_parceiro, 'IN_REVIEW')
  RETURNING id INTO v_case;

  -- A FILA traz nome e telefone.
  v_fila := api_kyc_queue(50);
  SELECT c INTO v_caso
    FROM jsonb_array_elements(v_fila->'cases') c
   WHERE c->>'case_id' = v_case::text;
  IF v_caso IS NULL THEN
    RAISE EXCEPTION 'o caso da operação não apareceu na fila do KYC: %', v_fila;
  END IF;
  IF v_caso->>'partner_name' IS NULL THEN
    RAISE EXCEPTION 'a fila do KYC não traz o nome do parceiro: %', v_caso;
  END IF;
  IF v_caso->>'partner_phone' IS NULL THEN
    RAISE EXCEPTION 'a fila do KYC não traz o telefone do parceiro: %', v_caso;
  END IF;

  -- O DETALHE traz o caminho do arquivo e diz se ele EXISTE.
  v_path := 'kyc/' || v_parceiro::text || '/' || v_case::text || '/CNH_1.jpg';
  INSERT INTO kyc_documents (case_id, doc_type, storage_path)
  VALUES (v_case, 'CNH', v_path);
  -- O objeto existe no bucket (o stub do Storage): só assim o `has_file`
  -- pode ser VERDADEIRO.
  INSERT INTO storage.objects (bucket_id, name, owner)
  VALUES ('kyc-docs', v_path, v_parceiro);

  v_detalhe := api_kyc_case_get(v_case);
  IF v_detalhe->>'partner_name' IS NULL THEN
    RAISE EXCEPTION 'o detalhe do KYC não traz o nome do parceiro: %', v_detalhe;
  END IF;
  v_doc := v_detalhe->'documents'->0;
  IF v_doc->>'storage_path' IS DISTINCT FROM v_path THEN
    RAISE EXCEPTION 'o detalhe do KYC não traz o caminho do arquivo: %', v_doc;
  END IF;
  IF (v_doc->>'has_file')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'o detalhe do KYC não marca o documento como COM arquivo: %', v_doc;
  END IF;

  -- E um path que NÃO aponta para objeto nenhum NÃO pode ser "ARQUIVO OK":
  -- a tela pintava verde enquanto o preview falhava ("Não foi possível
  -- carregar o documento"). O `has_file` pergunta ao BUCKET.
  INSERT INTO kyc_documents (case_id, doc_type, storage_path)
  VALUES (v_case, 'OTHER',
          'kyc/' || v_parceiro::text || '/' || v_case::text || '/nao-existe.jpg');
  SELECT d INTO v_doc
    FROM jsonb_array_elements(api_kyc_case_get(v_case)->'documents') d
   WHERE d->>'doc_type' = 'OTHER';
  IF (v_doc->>'has_file')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'um path sem objeto foi marcado como COM arquivo: %', v_doc;
  END IF;

  -- E um caminho VAZIO (legado) é OMITIDO — nunca `null`.
  --
  -- O detalhe é montado com `jsonb_strip_nulls`, e ele **recursa**: a
  -- chave nula dentro de um elemento do array `documents` também some
  -- (medido no PG 16.4 do CI e no 17.11 do stack local: `{"docs":
  -- [{"p": null}]}` → `{"docs": [{}]}`). Sem isso, um `storage_path`
  -- vazio (o `NULLIF` o transforma em `null`) chegaria como
  -- `"storage_path": null` — um campo que o openapi promete NUNCA
  -- existir (nulo é OMITIDO, em toda parte).
  --
  -- Este assert existe para **vigiar** esse comportamento: se uma versão
  -- do Postgres deixar de recursar, ele acusa (e o contrato quebra).
  INSERT INTO kyc_documents (case_id, doc_type, storage_path)
  VALUES (v_case, 'PROOF_ADDRESS', '');
  SELECT d INTO v_doc
    FROM jsonb_array_elements(api_kyc_case_get(v_case)->'documents') d
   WHERE d->>'doc_type' = 'PROOF_ADDRESS';
  IF v_doc IS NULL THEN
    RAISE EXCEPTION 'o documento com caminho vazio sumiu do detalhe: %',
      api_kyc_case_get(v_case);
  END IF;
  IF v_doc ? 'storage_path' THEN
    RAISE EXCEPTION 'o documento sem caminho deveria OMITIR o storage_path, mas veio %', v_doc;
  END IF;
  IF (v_doc->>'has_file')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'um documento sem caminho foi marcado como COM arquivo: %', v_doc;
  END IF;
  DELETE FROM kyc_documents
   WHERE case_id = v_case AND doc_type = 'PROOF_ADDRESS';
END
$test$;
SQL
then
  fail "o console não recebeu a identidade do parceiro nem o caminho do documento (ver o erro acima)"
fi

# 11) A degradação honesta: sem o schema `storage`, uma referência real não
#     pode ser validada — e o servidor precisa dizer isso (503
#     `storage_unavailable`), não estourar "relation does not exist".
if ! psql_c -At <<'SQL'
INSERT INTO users (id, phone_e164, role)
VALUES ('cccccccc-cccc-4ccc-8ccc-cccccccccccc', '+5596990000077', 'PARTNER')
ON CONFLICT (id) DO NOTHING;
INSERT INTO partners (user_id, city_id)
VALUES ('cccccccc-cccc-4ccc-8ccc-cccccccccccc', '99999999-9999-4999-8999-999999999999')
ON CONFLICT (user_id) DO NOTHING;
BEGIN;
ALTER TABLE storage.objects RENAME TO objects_fora_do_ci;
SET app.test_uid = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
DO $test$
DECLARE
  v_case  uuid;
  v_state text;
  v_msg   text;
  v_ok    boolean := false;
BEGIN
  INSERT INTO kyc_cases (partner_user_id, status)
  VALUES ('cccccccc-cccc-4ccc-8ccc-cccccccccccc', 'IN_REVIEW')
  RETURNING id INTO v_case;
  BEGIN
    PERFORM api_kyc_case_document(v_case, 'CNH',
      'kyc/cccccccc-cccc-4ccc-8ccc-cccccccccccc/' || v_case::text || '/CNH_1.jpg');
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    v_ok := true;
  END;
  IF NOT v_ok THEN
    RAISE EXCEPTION 'sem o schema storage a API aceitou o path (deveria degradar)';
  END IF;
  IF v_state <> '22023' OR v_msg NOT LIKE '%storage_unavailable%' THEN
    RAISE EXCEPTION 'esperava 22023/storage_unavailable, veio % / %', v_state, v_msg;
  END IF;
END
$test$;
ROLLBACK;
SQL
then
  fail "sem o schema storage a API não degradou com storage_unavailable (ver o erro acima)"
fi

# 12) A função que pergunta "esse path existe?" NÃO é pública.
#
#     `fn_kyc_storage_object_present` vive em `public`. Sem o revoke, ela
#     fica executável por PUBLIC/anon: qualquer visitante da API poderia
#     perguntar "esse documento existe?" — um oráculo de existência de
#     documento de parceiro, num bucket privado.
if ! psql_c -At <<'SQL'
DO $test$
DECLARE
  v_acl text;
BEGIN
  SELECT p.proacl::text INTO v_acl
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public'
     AND p.proname = 'fn_kyc_storage_object_present';
  IF v_acl IS NULL THEN
    -- `proacl IS NULL` = a função NÃO tem ACL explícito = o default do
    -- Postgres = EXECUTE para PUBLIC. (Também cobre "a função não
    -- existe" — o `SELECT` não achou nada.)
    RAISE EXCEPTION 'a função do bucket não tem ACL explícito (⇒ PUBLIC por default) ou não existe';
  END IF;
  -- O ACL do Postgres escreve o PUBLIC como `=X/postgres`: o `=` sem
  -- nome é o PUBLIC, com a letra da permissão no meio. O regex precisa
  -- casar `=<permissão>/` — casar só `=/` não detecta nada.
  IF v_acl ~* '(^|,)=[^,=]*/' THEN
    RAISE EXCEPTION 'a função do bucket ainda é executável por PUBLIC: %', v_acl;
  END IF;
  IF v_acl ~* '(^|,)anon=' THEN
    RAISE EXCEPTION 'a função do bucket ainda é executável por anon: %', v_acl;
  END IF;
  IF v_acl !~* 'authenticated=' THEN
    RAISE EXCEPTION 'a função do bucket não dá execute para authenticated: %', v_acl;
  END IF;
  IF v_acl !~* 'service_role=' THEN
    RAISE EXCEPTION 'a função do bucket não dá execute para service_role: %', v_acl;
  END IF;
END
$test$;
SQL
then
  fail "fn_kyc_storage_object_present está executável por PUBLIC/anon (ver o erro acima)"
fi

# 13) A fila ORDENADA de verdade (e não só no texto da migration).
#
#     O `ORDER BY` precisa vir ANTES do `LIMIT`: com mais casos na fila do
#     que o limite, o caso que vence primeiro não pode ficar de fora. Este
#     teste é COMPORTAMENTAL: ele cria muitos casos, insere o MAIS URGENTE
#     por ÚLTIMO e exige que ele apareça na tela E em primeiro lugar.
#
#     O teste é **independente do plano**: sem isto, o `LIMIT` sem
#     `ORDER BY` seria salvo pelo ACIDENTO do plano de execução (o índice
#     parcial `idx_kyc_queue` — ou um index scan pela PK — devolve as
#     linhas já ordenadas por outro critério, e o caso urgente entrava
#     "por sorte"). Para provar o que é do SQL e não do plano:
#       * o índice parcial é derrubado durante o teste;
#       * o planner é forçado a varrer a tabela em seq scan (a ordem
#         física = ordem de inserção), sem index scan nem bitmap scan;
#       * os casos do teste têm prazo VENCIDO (mais urgentes que qualquer
#         outro caso da base), para que a diferença entre o conjunto
#         retornado com e sem o `ORDER BY` seja o próprio conjunto.
if ! psql_c -At <<'SQL'
INSERT INTO users (id, phone_e164, role)
VALUES ('dddddddd-dddd-4ddd-8ddd-dddddddddddd', '+5596990000088', 'PARTNER')
ON CONFLICT (id) DO NOTHING;
INSERT INTO partners (user_id, city_id)
VALUES ('dddddddd-dddd-4ddd-8ddd-dddddddddddd',
        '99999999-9999-4999-8999-999999999999')
ON CONFLICT (user_id) DO NOTHING;
SET app.test_uid = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee';
-- 80 casos COM prazo vencido (menos urgente que os três abaixo, mais
-- urgente que qualquer outro caso da base).
INSERT INTO kyc_cases (partner_user_id, status, sla_due_at, created_at)
SELECT 'dddddddd-dddd-4ddd-8ddd-dddddddddddd', 'IN_REVIEW',
       now() - interval '8 hours', now()
  FROM generate_series(1, 80);
-- DOIS casos com o MESMO prazo e a MESMA hora de entrada: o desempate
-- é pelo `id` (a mesma chave do ranking). Sem ele, a ordem da tela seria
-- arbitrária.
INSERT INTO kyc_cases (id, partner_user_id, status, sla_due_at, created_at)
VALUES ('11111111-1111-4111-8111-1111111111bb',
        'dddddddd-dddd-4ddd-8ddd-dddddddddddd', 'IN_REVIEW',
        now() - interval '9 hours', now() + interval '1 day'),
       ('11111111-1111-4111-8111-1111111111aa',
        'dddddddd-dddd-4ddd-8ddd-dddddddddddd', 'IN_REVIEW',
        now() - interval '9 hours', now() + interval '1 day');
-- O MAIS URGENTE (prazo vencido há 10 h), inserido por ÚLTIMO: na ordem
-- física ele é o ÚLTIMO — e é exatamente por isso que um `LIMIT` sem
-- `ORDER BY` o deixaria de fora da tela.
INSERT INTO kyc_cases (partner_user_id, status, sla_due_at, created_at)
VALUES ('dddddddd-dddd-4ddd-8ddd-dddddddddddd', 'IN_REVIEW',
        now() - interval '10 hours', now());

-- O índice partial que MASCARARIA o defeito: fora.
DROP INDEX IF EXISTS idx_kyc_queue;
-- E o planner sem index scan: a ordem passa a ser a ordem FÍSICA (de
-- inserção), que é a ordem ERRADA — o `ORDER BY` do SQL tem que
-- consertar.
SET enable_indexscan = off;
SET enable_bitmapscan = off;

DO $test$
DECLARE
  v_fila    jsonb;
  v_urgente uuid;
  v_total   int;
  v_ordem   text[];
BEGIN
  SELECT id INTO v_urgente
    FROM kyc_cases
   WHERE partner_user_id = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd'
     AND sla_due_at < now() - interval '9 hours 30 minutes';
  IF v_urgente IS NULL THEN
    RAISE EXCEPTION 'o caso urgente de teste não foi criado';
  END IF;

  v_fila := api_kyc_queue(50);
  SELECT count(*) INTO v_total
    FROM jsonb_array_elements(v_fila->'cases');
  IF v_total <> 50 THEN
    RAISE EXCEPTION 'a fila deveria trazer 50 casos, trouxe %', v_total;
  END IF;

  -- O caso MAIS URGENTE tem que estar na tela...
  IF NOT EXISTS (
       SELECT 1 FROM jsonb_array_elements(v_fila->'cases') c
        WHERE c->>'case_id' = v_urgente::text) THEN
    RAISE EXCEPTION 'o caso mais URGENTE ficou fora da fila (o ORDER BY precisa vir ANTES do LIMIT)';
  END IF;

  -- ...e em PRIMEIRO lugar (é o que a pessoa da operação vê no topo).
  IF (v_fila->'cases'->0->>'case_id')::uuid <> v_urgente THEN
    RAISE EXCEPTION 'a fila não começa pelo caso mais urgente: %', v_fila->'cases'->0;
  END IF;

  -- O desempate: dois casos com o MESMO (prazo, entrada) vêm pelo `id`.
  --
  -- O QUE este assert prova: a ordem **EFETIVA** dos empates na tela
  -- (que é o que a operação vê). O que ele NÃO prova: o `ORDER BY`
  -- externo (`q.sla_due_at, q.created_at, q.case_id`) — ele é o
  -- ESPELHO da chave do ranking (o subquery já entrega nessa ordem),
  -- então tirá-lo não muda o resultado. Quem guarda essa linha é o
  -- `test_contract.py` (grep textual), porque o comportamento é
  -- indistinguível do subquery.
  SELECT array_agg(c->>'case_id' ORDER BY ord) INTO v_ordem
    FROM jsonb_array_elements(v_fila->'cases') WITH ORDINALITY AS x(c, ord)
   WHERE c->>'case_id' IN ('11111111-1111-4111-8111-1111111111aa',
                           '11111111-1111-4111-8111-1111111111bb');
  IF v_ordem IS DISTINCT FROM ARRAY[
       '11111111-1111-4111-8111-1111111111aa',
       '11111111-1111-4111-8111-1111111111bb']::text[] THEN
    RAISE EXCEPTION 'o desempate por id da fila está errado: %', v_ordem;
  END IF;
END
$test$;

RESET enable_indexscan;
RESET enable_bitmapscan;
-- O índice de volta (o CI aplica as migrations num banco descartável,
-- mas a cadeia precisa ficar como estava).
CREATE INDEX IF NOT EXISTS idx_kyc_queue ON kyc_cases (sla_due_at)
  WHERE status IN ('IN_REVIEW','RESUBMIT');
SQL
then
  fail "a fila não traz o caso mais urgente quando há mais casos que o limite (ver o erro acima)"
fi

# 14) A POSIÇÃO concorda com a ORDEM (o número da tela é o número da tela).
#
#     O defeito: `fn_kyc_queue_position` contava com comparação de LINHA
#     (`(q.sla_due_at, q.created_at, q.id) <= (...)`), e na comparação de
#     linha um NULL torna o resultado **desconhecido** (o `WHERE`
#     descartava a linha) — não "NULL é o maior", como no `ORDER BY`.
#     Um caso SEM prazo recebia posição **0** sendo o ÚLTIMO da fila: a
#     tela mostrava "#1" em cima de "#0" (dois números que não contam
#     nada). A migration `20261113001000` alinha a posição com a ordem.
#
#     O assert é o INVARIANTE INTEIRO: para todo caso da fila, a
#     `position` que o servidor devolve tem que ser o índice dele na
#     própria fila (+1). É mais forte que testar um caso só — e pega
#     qualquer desalinhamento, não só o do prazo nulo.
if ! psql_c -At <<'SQL'
INSERT INTO users (id, phone_e164, role)
VALUES ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', '+5596990000066', 'PARTNER')
ON CONFLICT (id) DO NOTHING;
INSERT INTO partners (user_id, city_id)
VALUES ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        '99999999-9999-4999-8999-999999999999')
ON CONFLICT (user_id) DO NOTHING;
SET app.test_uid = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee';
-- Um caso COM prazo e um SEM prazo (o `sla_due_at` é NULL).
INSERT INTO kyc_cases (partner_user_id, status, sla_due_at, created_at)
VALUES ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'IN_REVIEW',
        now() + interval '2 hours', now());
INSERT INTO kyc_cases (partner_user_id, status, sla_due_at, created_at)
VALUES ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'IN_REVIEW',
        NULL, now() + interval '1 minute');

DO $test$
DECLARE
  v_fila jsonb;
  v_bad  text;
  v_sem  jsonb;
  v_com  jsonb;
  v_total int;
BEGIN
  v_fila := api_kyc_queue(200);
  SELECT count(*) INTO v_total
    FROM jsonb_array_elements(v_fila->'cases');

  -- O invariante: a posição é o índice na fila (+1).
  SELECT string_agg(
           format('%s: posição %s (era %s)', c->>'case_id', c->>'position', ord),
           ', ')
    INTO v_bad
    FROM jsonb_array_elements(v_fila->'cases') WITH ORDINALITY AS x(c, ord)
   WHERE (c->>'position')::int <> ord;
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'a posição não bate com a ordem da fila: %', left(v_bad, 400);
  END IF;

  -- E o caso SEM prazo é o ÚLTIMO da fila (os NULLs vão por último),
  -- depois do caso COM prazo do mesmo parceiro.
  SELECT c INTO v_sem
    FROM jsonb_array_elements(v_fila->'cases') c
   WHERE c->>'partner_user_id' = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
     AND c->>'sla_due_at' IS NULL;
  SELECT c INTO v_com
    FROM jsonb_array_elements(v_fila->'cases') c
   WHERE c->>'partner_user_id' = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
     AND c->>'sla_due_at' IS NOT NULL;
  IF v_sem IS NULL OR v_com IS NULL THEN
    RAISE EXCEPTION 'os casos de prazo e sem prazo não apareceram na fila (% casos)',
      v_total;
  END IF;
  IF (v_sem->>'position')::int <> v_total THEN
    RAISE EXCEPTION 'o caso sem prazo deveria ser o ÚLTIMO da fila (posição %), veio %',
      v_total, v_sem->>'position';
  END IF;
  IF (v_com->>'position')::int >= (v_sem->>'position')::int THEN
    RAISE EXCEPTION 'o caso COM prazo deveria vir antes do sem prazo: % e %',
      v_com->>'position', v_sem->>'position';
  END IF;
END
$test$;
SQL
then
  fail "a posição do caso na fila não concorda com a ordem da fila (ver o erro acima)"
fi

say "TODOS OS ASSERTS OK — cadeia de deploy aplicou do zero ($count migrations)"
