{{ config(materialized='table', tags=['daily']) }}

-- Per-channel return on marketing spend: lifetime contribution earned per
-- euro spent. analytics.ltv_per_user is produced by the finance project and
-- is referenced by its raw schema-qualified name (see "the four rules").
SELECT
    channel,
    COUNT(*)                                   AS users,
    ROUND(SUM(contribution_margin_eur), 2)     AS contribution_eur,
    ROUND(SUM(marketing_cost_eur), 2)          AS spend_eur,
    ROUND(SUM(contribution_margin_eur) / NULLIF(SUM(marketing_cost_eur), 0), 2)
                                               AS roi
FROM analytics.ltv_per_user
GROUP BY channel