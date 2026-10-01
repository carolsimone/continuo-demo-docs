#!/usr/bin/env bash
# Local functional smoke for the finance customname-dbt CLI. Builds the finance
# image, stands up an ephemeral postgres with a minimal analytics schema + a
# stub of the cross-service upstream (analytics.seed_fx_transactions), then
# exercises every verb the deployed dialect routes through customname-dbt:
# compile-project, load-seed, run-model, build-model, test-model, reload-seed,
# rebuild-model. Exits non-zero on the first failure. Gate every finance push
# on it.
set -euo pipefail

IMG=finance-customnamedbt-smoke
PG=customname-smoke-pg
NET=customname-smoke-net
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

cleanup() {
  docker rm -f "$PG" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup

echo "== build finance image (real Dockerfile) =="
docker build -t "$IMG" -f "$ROOT/services/finance/Dockerfile" "$ROOT/services/finance"

echo "== start ephemeral postgres =="
docker network create "$NET" >/dev/null
docker run -d --name "$PG" --network "$NET" \
  -e POSTGRES_USER=continuo_svc -e POSTGRES_PASSWORD=runner -e POSTGRES_DB=continuo_dbt \
  postgres:16-alpine >/dev/null

echo "== wait for postgres =="
for _ in $(seq 1 30); do
  if docker exec "$PG" pg_isready -U continuo_svc -d continuo_dbt >/dev/null 2>&1; then break; fi
  sleep 1
done

echo "== create analytics schema + cross-service upstream stub =="
docker exec -i "$PG" psql -U continuo_svc -d continuo_dbt <<'SQL'
CREATE SCHEMA IF NOT EXISTS analytics;
DROP TABLE IF EXISTS analytics.seed_fx_transactions;
CREATE TABLE analytics.seed_fx_transactions (
  transaction_id text, user_id text, amount numeric,
  currency_from text, currency_to text, rate numeric, created_at date,
  fee_amount numeric
);
-- created_at must land on a (currency, rate_date) pair that actually exists in
-- seeds/seed_fx_rates_eur.csv (USD,2023-02-15 is a real row there), otherwise
-- the model's LEFT JOIN yields a NULL rate_to_eur/amount_eur and fails the
-- not_null tests exercised by build-model and test-model. fee_amount
-- (denominated in currency_from, like amount) must be non-null:
-- fx_transactions_eur selects it directly and derives fee_amount_eur from it,
-- both under a not_null test.
INSERT INTO analytics.seed_fx_transactions VALUES
  ('t1','u1',100,'USD','EUR',0.9,'2023-02-15',5);
SQL

run_verb() { # <expect-banner-substr> <verb...>
  local expect="$1"; shift
  local out
  # The image's own ENTRYPOINT (/entrypoint.sh) is a local-debug-only script
  # that ignores its positional args and always shells out to a hardcoded
  # `dbt run`. Override it so the container actually execs customname-dbt with
  # the verb we're testing, instead of silently running entrypoint.sh's own logic.
  out="$(docker run --rm --network "$NET" \
    -e POSTGRES_HOST="$PG" -e POSTGRES_PORT=5432 \
    -e POSTGRES_DB=continuo_dbt -e POSTGRES_USER=continuo_svc -e POSTGRES_PASSWORD=runner \
    --entrypoint customname-dbt "$IMG" "$@" 2>&1)"
  echo "$out"
  echo "$out" | grep -q "CUSTOMNAME-DBT WRAPPER v1" || { echo "FAIL: banner missing for '$*'"; return 1; }
  echo "$out" | grep -q "$expect" || { echo "FAIL: expected '$expect' in output for '$*'"; return 1; }
}

echo "== compile-project =="
run_verb "Running with dbt=" compile-project

echo "== load-seed (finance own seed) =="
run_verb "Running with dbt=" load-seed seed_fx_rates_eur

echo "== run-model (needs upstream stub + seed) =="
run_verb "Running with dbt=" run-model fx_transactions_eur

echo "== build-model = dbt build (materialize + test) =="
run_verb "Running with dbt=" build-model fx_transactions_eur

echo "== test-model (tests the built model) =="
run_verb "Running with dbt=" test-model fx_transactions_eur

echo "== reload-seed = dbt seed --full-refresh =="
run_verb "Running with dbt=" reload-seed seed_fx_rates_eur

echo "== rebuild-model = dbt run --full-refresh =="
run_verb "Running with dbt=" rebuild-model fx_transactions_eur

echo "== wise-dbt alias still resolves =="
# customname-dbt intentionally exits 64 on a bad invocation, so capture the
# output first (masking that expected non-zero exit) rather than piping the
# docker run directly into grep -q, which would trip pipefail even on a match.
alias_out="$(docker run --rm --entrypoint wise-dbt "$IMG" nope 2>&1)" || true
echo "$alias_out"
echo "$alias_out" | grep -q "customname-dbt: bad invocation" \
  || { echo "FAIL: wise-dbt alias missing"; exit 1; }

echo "SMOKE OK"
