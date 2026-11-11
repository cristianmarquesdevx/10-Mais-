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
#   3. As funções que as Edge Functions chamam existem com a assinatura
#      esperada — a função `rides` quebra se o PostgREST não achar o RPC.
#   4. A cotação congelada existe (tabela + funções) e o despacho usa o
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

say "TODOS OS ASSERTS OK — cadeia de deploy aplicou do zero ($count migrations)"
