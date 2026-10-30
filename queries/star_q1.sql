-- Q1 Monthly encounters by specialty - star schema version
-- Run with default schema: healthtech_dw
SELECT d.month_label    AS encounter_month,
       s.specialty_name,
       t.type_name      AS encounter_type,
       agg.total_encounters,
       agg.unique_patients
FROM (
    -- aggregate the fact on integer keys only (covering index idx_fact_date_spec_type)
    SELECT f.encounter_date_key DIV 100       AS month_key,     -- smart key YYYYMMDD -> YYYYMM
           f.specialty_key,
           f.encounter_type_key,
           COUNT(*)                           AS total_encounters,
           COUNT(DISTINCT f.patient_key)      AS unique_patients
    FROM fact_encounters f
    GROUP BY f.encounter_date_key DIV 100, f.specialty_key, f.encounter_type_key
) agg
JOIN (SELECT DISTINCT month_key, month_label FROM dim_date) d ON d.month_key = agg.month_key
JOIN dim_specialty      s ON s.specialty_key      = agg.specialty_key
JOIN dim_encounter_type t ON t.encounter_type_key = agg.encounter_type_key
ORDER BY encounter_month, s.specialty_name, encounter_type;
