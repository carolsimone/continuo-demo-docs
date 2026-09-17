{{ config(materialized='table', tags=['daily']) }}

SELECT
    t.transaction_id,
    t.user_id,
    t.amount,
    t.fee_amount,
    t.currency_from,
    t.currency_to,
    t.rate,
    t.created_at,
    r.rate_to_eur,
    -- The fee is denominated in currency_from, so it converts on the same
    -- join as the amount. This is why the seed does not carry a EUR fee.
    ROUND((t.fee_amount * r.rate_to_eur)::numeric, 2) AS fee_amount_eur
FROM analytics.seed_fx_transactions t
LEFT JOIN analytics.seed_fx_rates_eur r
    ON t.currency_from = r.currency
   AND t.created_at::date = r.rate_date
WHERE true