-- Q3 30-day readmission rate by specialty - star schema version
-- Run with default schema: healthtech_dw
SELECT s.specialty_name,
       agg.inpatient_discharges,
       agg.readmissions_30d,
       ROUND(100.0 * agg.readmissions_30d / agg.inpatient_discharges, 2) AS readmission_rate_pct
FROM (
    SELECT f.specialty_key,
           COUNT(*)                     AS inpatient_discharges,
           SUM(f.readmitted_within_30d) AS readmissions_30d   -- pre-computed in ETL: no self-join
    FROM fact_encounters f
    WHERE f.encounter_type_key IN (SELECT encounter_type_key FROM dim_encounter_type WHERE is_inpatient = 1)
      AND f.discharge_date_key <> 0
    GROUP BY f.specialty_key
) agg
JOIN dim_specialty s ON s.specialty_key = agg.specialty_key
ORDER BY readmission_rate_pct DESC;
