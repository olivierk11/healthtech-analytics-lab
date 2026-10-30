-- Q4 Revenue (allowed amount) by specialty and month - star schema version
-- Run with default schema: healthtech_dw
SELECT d.month_label AS service_month,
       s.specialty_name,
       agg.total_allowed,
       agg.total_claimed,
       agg.billed_encounters
FROM (
    SELECT f.encounter_date_key DIV 100   AS month_key,
           f.specialty_key,
           SUM(f.total_allowed_amount)    AS total_allowed,      -- pre-aggregated per encounter in ETL
           SUM(f.total_claim_amount)      AS total_claimed,
           COUNT(*)                       AS billed_encounters
    FROM fact_encounters f
    WHERE f.claim_count > 0
    GROUP BY f.encounter_date_key DIV 100, f.specialty_key
) agg
JOIN (SELECT DISTINCT month_key, month_label FROM dim_date) d ON d.month_key = agg.month_key
JOIN dim_specialty s ON s.specialty_key = agg.specialty_key
ORDER BY service_month, agg.total_allowed DESC;
