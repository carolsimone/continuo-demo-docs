#!/usr/bin/env bash
# Local functional smoke for the finance operational-cost and LTV models.
# Builds the finance image, stands up an ephemeral postgres, stubs the
# cross-service upstreams (analytics.seed_fx_transactions with one synthetic
# row; analytics.seed_users from the real core CSV; analytics.revenue_per_user
# and analytics.marketing_cost_per_user from the real seed_users with flat
# stand-in per-user values -- core's/marketing's own smokes cover the real
# distributions), runs `dbt build` (seeds + models + tests), then asserts the
# row shapes the models are supposed to have. Exits non-zero on the first
# failure. Gate every finance push on it.
set -euo pipefail

IMG=finance-models-smoke
PG=finance-smoke-pg
NET=finance-smoke-net
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

echo "== create analytics schema + cross-service upstream stubs =="
docker exec -i "$PG" psql -U continuo_svc -d continuo_dbt <<'SQL'
CREATE SCHEMA IF NOT EXISTS analytics;
DROP TABLE IF EXISTS analytics.seed_fx_transactions;
CREATE TABLE analytics.seed_fx_transactions (
  transaction_id text, user_id text, amount numeric,
  currency_from text, currency_to text, rate numeric, created_at date,
  fee_amount numeric
);
-- created_at must land on a (currency, rate_date) pair that actually exists in
-- seeds/seed_fx_rates_eur.csv, otherwise fx_transactions_eur's LEFT JOIN
-- yields NULL rate_to_eur/amount_eur and its not_null tests fail the build.
INSERT INTO analytics.seed_fx_transactions VALUES
  ('t1','u1',100,'USD','EUR',0.9,'2023-02-15',0.5);
DROP TABLE IF EXISTS analytics.seed_users;
CREATE TABLE analytics.seed_users (
  user_id text, name text, email text, birth_year int, created_at timestamp
);
DROP TABLE IF EXISTS analytics.revenue_per_user;
CREATE TABLE analytics.revenue_per_user (
  user_id int, acquired_at timestamp, acquisition_month date,
  transaction_count bigint, gross_volume_eur numeric, revenue_eur numeric,
  first_transaction_at timestamp, last_transaction_at timestamp
);
DROP TABLE IF EXISTS analytics.marketing_cost_per_user;
CREATE TABLE analytics.marketing_cost_per_user (
  user_id int, channel text, campaign text, acquired_at timestamp,
  acquisition_month date, channel_is_paid boolean, marketing_cost_eur numeric
);
SQL

echo "== load real core seed_users (2000 users, 2023-01..2024-12) =="
docker exec -i "$PG" psql -U continuo_svc -d continuo_dbt \
  -c "COPY analytics.seed_users FROM STDIN WITH (FORMAT csv, HEADER true)" \
  < "$ROOT/services/core/seeds/seed_users.csv"

echo "== stub revenue_per_user and marketing_cost_per_user from the real seeds =="
docker exec -i "$PG" psql -U continuo_svc -d continuo_dbt <<'SQL'
INSERT INTO analytics.revenue_per_user
  (user_id, acquired_at, acquisition_month, transaction_count,
   gross_volume_eur, revenue_eur)
SELECT
  user_id::int,
  created_at::timestamp,
  DATE_TRUNC('month', created_at::timestamp)::date,
  0, 0, 101.06          -- flat stand-in for core's real per-user revenue
FROM analytics.seed_users;

INSERT INTO analytics.marketing_cost_per_user
  (user_id, channel, acquisition_month, channel_is_paid, marketing_cost_eur)
SELECT
  user_id::int,
  'google_ads',
  DATE_TRUNC('month', created_at::timestamp)::date,
  true,
  CASE WHEN user_id::int % 6 = 0 THEN 0 ELSE 30.60 END
    -- ~1-in-6 users get EUR 0 CAC, standing in for organic's real ~15-16%
    -- share, so this smoke actually exercises ltv_per_user's NULLIF(m.
    -- marketing_cost_eur, 0) guard instead of only ever dividing by 30.60.
FROM analytics.seed_users;
SQL

echo "== dbt seed (separate invocation, mirroring continuo's node-by-node orchestration) =="
# fx_transactions_eur references its seed by raw name (analytics.seed_fx_rates_eur),
# so dbt's DAG doesn't order the seed first. In production continuo drives each
# node itself via customname-dbt verbs; the smoke mirrors that by seeding before build.
docker run --rm --network "$NET" \
  -e POSTGRES_HOST="$PG" -e POSTGRES_PORT=5432 \
  -e POSTGRES_DB=continuo_dbt -e POSTGRES_USER=continuo_svc -e POSTGRES_PASSWORD=runner \
  --entrypoint dbt "$IMG" seed --profiles-dir /project

echo "== dbt build (seeds + models + tests) =="
# The image ENTRYPOINT is a local-debug script that ignores its args and always
# runs a hardcoded `dbt run`. Override it so we actually get `dbt build`.
docker run --rm --network "$NET" \
  -e POSTGRES_HOST="$PG" -e POSTGRES_PORT=5432 \
  -e POSTGRES_DB=continuo_dbt -e POSTGRES_USER=continuo_svc -e POSTGRES_PASSWORD=runner \
  --entrypoint dbt "$IMG" build --profiles-dir /project

# assert_scalar <label> <expected> <sql>
assert_scalar() {
  local label="$1" expected="$2" sql="$3" actual
  actual="$(docker exec "$PG" psql -U continuo_svc -d continuo_dbt -tAc "$sql" | tr -d '[:space:]')"
  if [ "$actual" != "$expected" ]; then
    echo "FAIL: ${label}: expected ${expected}, got ${actual}"
    return 1
  fi
  echo "OK: ${label} = ${actual}"
}

echo "== assert operational_costs_monthly shape =="
assert_scalar "monthly row count (24 months)" 24 \
  "SELECT COUNT(*) FROM analytics.operational_costs_monthly"
assert_scalar "monthly months are all first-of-month" 0 \
  "SELECT COUNT(*) FROM analytics.operational_costs_monthly WHERE EXTRACT(DAY FROM cost_month) <> 1"
assert_scalar "monthly cost_line_count total equals seed rows" 240 \
  "SELECT SUM(cost_line_count) FROM analytics.operational_costs_monthly"
assert_scalar "monthly total equals seed total" t \
  "SELECT ROUND(SUM(total_cost_eur),2) = (SELECT ROUND(SUM(amount::numeric),2) FROM analytics.seed_operational_costs) FROM analytics.operational_costs_monthly"
assert_scalar "category columns sum to the total in every month" 0 \
  "SELECT COUNT(*) FROM analytics.operational_costs_monthly
    WHERE ABS(cogs_eur + rd_eur + ga_eur - total_cost_eur) > 0.01"
assert_scalar "variable + fixed equals the total in every month" 0 \
  "SELECT COUNT(*) FROM analytics.operational_costs_monthly
    WHERE ABS(variable_cost_eur + fixed_cost_eur - total_cost_eur) > 0.01"
assert_scalar "variable is a small share of the total" t \
  "SELECT SUM(variable_cost_eur) < SUM(total_cost_eur) * 0.15
   FROM analytics.operational_costs_monthly"

echo "== assert operational_cost_per_user shape =="
assert_scalar "cost_per_user has one row per user" 2000 \
  "SELECT COUNT(*) FROM analytics.operational_cost_per_user"
assert_scalar "cost_per_user user_id is unique" 2000 \
  "SELECT COUNT(DISTINCT user_id) FROM analytics.operational_cost_per_user"
assert_scalar "every acquired user is present" 0 \
  "SELECT COUNT(*) FROM analytics.seed_users u
    WHERE NOT EXISTS (SELECT 1 FROM analytics.operational_cost_per_user c
                      WHERE c.user_id = u.user_id::int)"
assert_scalar "every user carries a positive cost" 2000 \
  "SELECT COUNT(*) FROM analytics.operational_cost_per_user WHERE operational_cost_eur > 0"
assert_scalar "every user carries a positive variable cost" 2000 \
  "SELECT COUNT(*) FROM analytics.operational_cost_per_user WHERE variable_cost_eur > 0"
assert_scalar "acquisition_month is always first-of-month" 0 \
  "SELECT COUNT(*) FROM analytics.operational_cost_per_user
    WHERE EXTRACT(DAY FROM acquisition_month) <> 1"
assert_scalar "distinct acquisition months (all 24 have signups)" 24 \
  "SELECT COUNT(DISTINCT acquisition_month) FROM analytics.operational_cost_per_user"
assert_scalar "users_in_cohort matches the real per-month user count" 0 \
  "SELECT COUNT(*) FROM (
     SELECT c.acquisition_month
     FROM analytics.operational_cost_per_user c
     GROUP BY c.acquisition_month, c.users_in_cohort
     HAVING c.users_in_cohort <> COUNT(*)
   ) bad"

echo "== assert the allocation rule itself =="
# For each cohort: users_in_cohort * per_user_cost must reconstruct that
# month's total cost, allowing a few cents of rounding residual. This is the
# core arithmetic of the model, not just its shape.
# At the 2,000-user/24-month scale, per-user cent rounding across large
# cohorts can drift further than a few cents: the observed max residual is
# EUR 0.54 (confirmed via a live dbt build against the regenerated seeds).
# 0.6 comfortably clears that observed max while still catching a real
# regression in the allocation math.
assert_scalar "each cohort's allocation reconstructs its month's total" 0 \
  "WITH cohort AS (
       SELECT acquisition_month,
              COUNT(*) AS users, MAX(operational_cost_eur) AS per_user
       FROM analytics.operational_cost_per_user
       GROUP BY 1
   )
   SELECT COUNT(*) FROM cohort
   JOIN analytics.operational_costs_monthly m
     ON m.cost_month = cohort.acquisition_month
   WHERE ABS(cohort.users * cohort.per_user - m.total_cost_eur) > 0.6"

# Every cost month now has a matching acquisition cohort (both run
# 2023-01..2024-12), so nothing is dropped as a whole month and the old
# structural margin (10/36 unallocated months, ~EUR 300k guaranteed slack)
# is gone. What is left is per-user cent rounding across 24 cohorts (up to
# 114 users/month, EUR 0.005 max rounding error/user) -- a possible swing of
# roughly EUR 13.7 either way, so the residual's SIGN is not meaningful on a
# reseed. Assert magnitude instead of direction.
assert_scalar "allocated total is within rounding tolerance of total costs" t \
  "SELECT ABS((SELECT SUM(total_cost_eur) FROM analytics.operational_costs_monthly) -
              (SELECT SUM(operational_cost_eur) FROM analytics.operational_cost_per_user)) < 20.00"

echo "== assert ltv_per_user shape =="
assert_scalar "one row per user" 2000 \
  "SELECT COUNT(*) FROM analytics.ltv_per_user"
assert_scalar "no user lost to the three-way join" 0 \
  "SELECT COUNT(*) FROM analytics.revenue_per_user r
    WHERE NOT EXISTS (SELECT 1 FROM analytics.ltv_per_user l WHERE l.user_id = r.user_id)"
assert_scalar "contribution margin reconciles" 0 \
  "SELECT COUNT(*) FROM analytics.ltv_per_user
    WHERE ABS(contribution_margin_eur - (revenue_eur - variable_cost_eur)) > 0.01"
assert_scalar "blended LTV:CAC inside the band" t \
  "SELECT SUM(contribution_margin_eur) / NULLIF(SUM(marketing_cost_eur),0)
          BETWEEN 1.5 AND 6.0
   FROM analytics.ltv_per_user"
assert_scalar "fully allocated is negative for every user" 2000 \
  "SELECT COUNT(*) FROM analytics.ltv_per_user WHERE fully_allocated_eur < 0"

echo "SMOKE OK"
