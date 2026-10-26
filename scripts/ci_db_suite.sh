#!/usr/bin/env bash
# =============================================================================
# 10 é + — CI da cadeia SQL da Fase 2 (0001 → 0005) em container único.
# Roda a cada push (ver .github/workflows/db-suite.yml) ou localmente:
#   bash scripts/ci_db_suite.sh
#
# O que valida (fail com exit != 0 em qualquer uma):
#   1. Cadeia completa 0001→0002→0003→0004→0005 com ON_ERROR_STOP (SQL inválido
#      ou erro de execução aborta na hora).
#   2. E2E do 0003: ledger soma 0.00 após COMISSÃO e após PASSE; replay de
#      webhook idempotente (contagem de lançamentos não muda).
#   3. Suíte adversarial do 0005: exige exatamente 18 marcadores AV-OK,
#      zero AV-FAIL, e o marcador final ADVERSARIAL_SUITE_OK.
#   4. Sanidade do 0001..0004: marcadores de sucesso esperados presentes.
# Ambiente: container efêmero PostGIS 16 (descartado ao fim, salvo KEEP_DB=1).
# =============================================================================
set -euo pipefail

IMAGE="${DB_SUITE_IMAGE:-postgis/postgis:16-3.4}"
NAME="${DB_SUITE_NAME:-dezemais-ci-$$}"
SQL_DIR="$(cd "$(dirname "$0")/../docs/fase2" && pwd)"
EXPECTED_AV_OK="${EXPECTED_AV_OK:-18}"
KEEP_DB="${KEEP_DB:-0}"
LOG="$(mktemp -t dezemais-db-suite.XXXXXX)"
trap 'if [ "$KEEP_DB" = "1" ]; then echo "[ci] KEEP_DB=1 -> container $NAME mantido"; else docker rm -f "$NAME" >/dev/null 2>&1 || true; fi; rm -f "$LOG"' EXIT

say() { printf '[ci] %s\n' "$*"; }

say "subindo $IMAGE ($NAME)"
docker run -d --name "$NAME" \
  -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=dezemais \
  "$IMAGE" >/dev/null

# Espera determinística: o init do postgis/postgis recria o cluster (create
# spatial extension + restart), então pg_isready cedo é falso positivo.
# Condição de estabilidade: 5 checagens consecutivas com pg_isready OK,
# separadas por 1s, e a extensão postgis respondendo.
ready=0
for _ in $(seq 1 90); do
  if docker exec "$NAME" pg_isready -U postgres -d dezemais >/dev/null 2>&1; then
    if docker exec "$NAME" psql -U postgres -d dezemais -Atc \
        "SELECT extname FROM pg_extension WHERE extname='postgis'" 2>/dev/null \
        | grep -q postgis; then
      ready=$((ready + 1))
      [ "$ready" -ge 5 ] && break
    else
      ready=0
    fi
  else
    ready=0
  fi
  sleep 1
done
if [ "$ready" -lt 5 ]; then
  echo "[ci] FALHA: container não estabilizou em 90s" >&2
  docker logs "$NAME" 2>&1 | tail -40 >&2
  exit 1
fi
say "container estável (postgis ok)"

psql_c() {
  docker exec -i "$NAME" psql -U postgres -d dezemais -v ON_ERROR_STOP=1 "$@"
}

run_file() {
  local f="$1"
  say "executando $(basename "$f")"
  if ! docker exec -i "$NAME" psql -U postgres -d dezemais -v ON_ERROR_STOP=1 \
      < "$f" >>"$LOG" 2>&1; then
    echo "[ci] FALHA em $(basename "$f") — últimas linhas:" >&2
    tail -60 "$LOG" >&2
    exit 1
  fi
}

for f in 0001_schema.sql 0002_rls_states_events.sql 0003_smoke_e2e.sql \
         0004_gap_fixes.sql 0005_adversarial_tests.sql; do
  [ -f "$SQL_DIR/$f" ] || { echo "[ci] FALHA: $f não encontrado em $SQL_DIR" >&2; exit 1; }
  run_file "$SQL_DIR/$f"
done
say "cadeia 0001→0005 executada sem erro"

# --- asserts -----------------------------------------------------------------
fail() { echo "[ci] ASSERT FALHOU: $*" >&2; echo "----- log -----" >&2; tail -80 "$LOG" >&2; exit 1; }

# 1) E2E 0003: ledger balanceado nos 2 modos + replay idempotente
grep -q "C1 soma ledger (precisa 0.00): 0.00" "$LOG" \
  || fail "0003: ledger do ciclo COMISSÃO não soma 0.00"
grep -q "Soma final do ledger (precisa 0.00): 0.00" "$LOG" \
  || fail "0003: ledger final (após PASSE) não soma 0.00"
c1_pre=$(grep -oE "C1 pós-pagamento.*" "$LOG" | head -1 || true)
[ -n "$c1_pre" ] || fail "0003: marcador C1 pós-pagamento ausente"
grep -q "C2 (PASSE): comissão lançada=0" "$LOG" \
  || fail "0003: corrida PASSE gerou lançamento de comissão (viola invariante 2)"
grep -q "C2 aceite: modo=PASSE pass_id_preenchido=true" "$LOG" \
  || fail "0003: snapshot PASSE não capturado na aceitação"
# replay: contagem impressa logo após o replay vs lançamentos reais do ciclo 1
replay_line=$(grep -oE "C1 replay: lançamentos=[0-9]+" "$LOG" | grep -oE "[0-9]+$" | tail -1 || true)
[ -n "$replay_line" ] || fail "0003: marcador de replay ausente"
c1_entries=$(psql_c -Atc \
  "SELECT count(*) FROM ledger_entries e JOIN rides r ON r.id = e.ride_id
    WHERE r.pricing_mode_snapshot = 'COMISSAO'" | tail -1)
[ "$c1_entries" = "$replay_line" ] \
  || fail "replay de webhook duplicou lançamentos: log=$replay_line db=$c1_entries"

# 2) 0004: tabelas do contrato existem
for t in idempotency_keys withdrawals ride_share_links; do
  psql_c -Atc "SELECT to_regclass('public.$t')" | grep -q "$t" \
    || fail "0004: tabela $t não existe"
done

# 3) 0005: suíte adversarial completa
av_ok=$(grep -c "AV-OK" "$LOG" || true)
av_fail=$(grep -c "AV-FAIL" "$LOG" || true)
[ "$av_fail" -eq 0 ] || fail "$av_fail marcador(es) AV-FAIL no log"
[ "$av_ok" -eq "$EXPECTED_AV_OK" ] \
  || fail "esperava $EXPECTED_AV_OK asserts AV-OK, obtive $av_ok"
grep -q "ADVERSARIAL_SUITE_OK" "$LOG" || fail "marcador ADVERSARIAL_SUITE_OK ausente"

# 4) invariante final direto no banco (não confiar só do print)
sum=$(psql_c -Atc \
  "SELECT COALESCE(SUM(CASE WHEN direction='C' THEN amount ELSE -amount END),0) FROM ledger_entries" | tail -1)
[ "$sum" = "0.00" ] || fail "ledger global soma $sum (esperado 0.00)"

say "TODOS OS ASSERTS OK — cadeia 0001→0005, $av_ok/$EXPECTED_AV_OK AV-OK, ledger Σ=0"
