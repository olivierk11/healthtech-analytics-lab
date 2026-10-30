-- compare_results.sql
-- Proves every star-schema query returns EXACTLY the same rows as its OLTP version.
-- Pure SQL, so it runs in MySQL Workbench (Execute the whole script; ~1-2 minutes,
-- mostly the slow OLTP Q2). Needs healthtech_oltp_big and a loaded healthtech_dw.
-- The last result grid shows one line per query: status must be PASS.

SET SQL_SAFE_UPDATES = 0, SQL_BIG_SELECTS = 1, SQL_SELECT_LIMIT = DEFAULT;  -- immune to client safety limits

DROP DATABASE IF EXISTS lab_compare;
CREATE DATABASE lab_compare;

USE healthtech_oltp_big;
CREATE TABLE lab_compare.oltp_q1 AS SELECT * FROM (
SELECT DATE_FORMAT(e.encounter_date, '%Y-%m') AS encounter_month,
       s.specialty_name,
       e.encounter_type,
       COUNT(*)                     AS total_encounters,
       COUNT(DISTINCT e.patient_id) AS unique_patients
FROM encounters e
JOIN providers   p ON e.provider_id  = p.provider_id
JOIN specialties s ON p.specialty_id = s.specialty_id
GROUP BY DATE_FORMAT(e.encounter_date, '%Y-%m'), s.specialty_name, e.encounter_type
ORDER BY encounter_month, s.specialty_name, e.encounter_type
) x;

USE healthtech_dw;
CREATE TABLE lab_compare.star_q1 AS SELECT * FROM (
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
ORDER BY encounter_month, s.specialty_name, encounter_type
) x;

USE healthtech_oltp_big;
CREATE TABLE lab_compare.oltp_q2 AS SELECT * FROM (
SELECT d.icd10_code,
       d.icd10_description,
       pr.cpt_code,
       pr.cpt_description,
       COUNT(DISTINCT ed.encounter_id) AS encounter_count
FROM encounter_diagnoses ed
JOIN encounter_procedures ep ON ed.encounter_id  = ep.encounter_id   -- junction-to-junction join
JOIN diagnoses  d            ON ed.diagnosis_id  = d.diagnosis_id
JOIN procedures pr           ON ep.procedure_id  = pr.procedure_id
GROUP BY d.icd10_code, d.icd10_description, pr.cpt_code, pr.cpt_description
ORDER BY encounter_count DESC
LIMIT 10
) x;

USE healthtech_dw;
CREATE TABLE lab_compare.star_q2 AS SELECT * FROM (
WITH top_pairs AS (
    SELECT bdx.diagnosis_key, bpx.procedure_key,
           COUNT(DISTINCT bdx.encounter_key) AS encounter_count
    FROM bridge_encounter_diagnoses  bdx
    JOIN bridge_encounter_procedures bpx ON bpx.encounter_key = bdx.encounter_key
    GROUP BY bdx.diagnosis_key, bpx.procedure_key
    ORDER BY encounter_count DESC
    LIMIT 10
)
SELECT dx.icd10_code, dx.icd10_description, px.cpt_code, px.cpt_description, tp.encounter_count
FROM top_pairs tp
JOIN dim_diagnosis dx ON dx.diagnosis_key = tp.diagnosis_key
JOIN dim_procedure px ON px.procedure_key = tp.procedure_key
ORDER BY tp.encounter_count DESC
) x;

USE healthtech_dw;
CREATE TABLE lab_compare.star_q2_agg AS SELECT * FROM (
SELECT dx.icd10_code, dx.icd10_description, px.cpt_code, px.cpt_description, top.encounter_count
FROM (
    SELECT diagnosis_key, procedure_key, encounter_count
    FROM agg_diagnosis_procedure_pairs
    ORDER BY encounter_count DESC
    LIMIT 10                                   -- reads 10 entries from idx_agg_pair_count
) top
JOIN dim_diagnosis dx ON dx.diagnosis_key = top.diagnosis_key
JOIN dim_procedure px ON px.procedure_key = top.procedure_key
ORDER BY top.encounter_count DESC
) x;

USE healthtech_oltp_big;
CREATE TABLE lab_compare.oltp_q3 AS SELECT * FROM (
SELECT s.specialty_name,
       COUNT(DISTINCT idx.encounter_id) AS inpatient_discharges,
       COUNT(DISTINCT CASE WHEN r.encounter_id IS NOT NULL THEN idx.encounter_id END) AS readmissions_30d,
       ROUND(100.0 * COUNT(DISTINCT CASE WHEN r.encounter_id IS NOT NULL THEN idx.encounter_id END)
                   / COUNT(DISTINCT idx.encounter_id), 2) AS readmission_rate_pct
FROM encounters idx                                   -- index admission
JOIN providers   p ON idx.provider_id = p.provider_id
JOIN specialties s ON p.specialty_id  = s.specialty_id
LEFT JOIN encounters r                                -- self-join: the return visit
       ON  r.patient_id      = idx.patient_id
       AND r.encounter_type  = 'Inpatient'
       AND r.encounter_id   <> idx.encounter_id
       AND r.encounter_date  > idx.discharge_date
       AND r.encounter_date <= idx.discharge_date + INTERVAL 30 DAY
WHERE idx.encounter_type = 'Inpatient'
  AND idx.discharge_date IS NOT NULL
GROUP BY s.specialty_name
ORDER BY readmission_rate_pct DESC
) x;

USE healthtech_dw;
CREATE TABLE lab_compare.star_q3 AS SELECT * FROM (
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
ORDER BY readmission_rate_pct DESC
) x;

USE healthtech_oltp_big;
CREATE TABLE lab_compare.oltp_q4 AS SELECT * FROM (
SELECT DATE_FORMAT(e.encounter_date, '%Y-%m') AS service_month,
       s.specialty_name,
       SUM(b.allowed_amount) AS total_allowed,
       SUM(b.claim_amount)   AS total_claimed,
       COUNT(DISTINCT e.encounter_id) AS billed_encounters
FROM billing b
JOIN encounters  e ON b.encounter_id = e.encounter_id
JOIN providers   p ON e.provider_id  = p.provider_id
JOIN specialties s ON p.specialty_id = s.specialty_id
GROUP BY DATE_FORMAT(e.encounter_date, '%Y-%m'), s.specialty_name
ORDER BY service_month, total_allowed DESC
) x;

USE healthtech_dw;
CREATE TABLE lab_compare.star_q4 AS SELECT * FROM (
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
ORDER BY service_month, agg.total_allowed DESC
) x;

-- Summary: PASS = same number of rows AND zero rows that differ
SELECT query_name, oltp_rows, star_rows, mismatched_rows,
       CASE WHEN oltp_rows = star_rows AND mismatched_rows = 0 THEN 'PASS' ELSE 'FAIL' END AS status
FROM (
SELECT 'Q1' AS query_name,
       (SELECT COUNT(*) FROM lab_compare.oltp_q1) AS oltp_rows,
       (SELECT COUNT(*) FROM lab_compare.star_q1) AS star_rows,
       (SELECT COUNT(*) FROM (
            SELECT encounter_month, specialty_name, encounter_type, total_encounters, unique_patients, SUM(src = 'o') AS in_oltp, SUM(src = 's') AS in_star
            FROM (SELECT o.*, 'o' AS src FROM lab_compare.oltp_q1 o
                  UNION ALL
                  SELECT s.*, 's' AS src FROM lab_compare.star_q1 s) u
            GROUP BY encounter_month, specialty_name, encounter_type, total_encounters, unique_patients
            HAVING in_oltp <> in_star) d) AS mismatched_rows
UNION ALL
SELECT 'Q2' AS query_name,
       (SELECT COUNT(*) FROM lab_compare.oltp_q2) AS oltp_rows,
       (SELECT COUNT(*) FROM lab_compare.star_q2) AS star_rows,
       (SELECT COUNT(*) FROM (
            SELECT icd10_code, icd10_description, cpt_code, cpt_description, encounter_count, SUM(src = 'o') AS in_oltp, SUM(src = 's') AS in_star
            FROM (SELECT o.*, 'o' AS src FROM lab_compare.oltp_q2 o
                  UNION ALL
                  SELECT s.*, 's' AS src FROM lab_compare.star_q2 s) u
            GROUP BY icd10_code, icd10_description, cpt_code, cpt_description, encounter_count
            HAVING in_oltp <> in_star) d) AS mismatched_rows
UNION ALL
SELECT 'Q2 (aggregate table)' AS query_name,
       (SELECT COUNT(*) FROM lab_compare.oltp_q2) AS oltp_rows,
       (SELECT COUNT(*) FROM lab_compare.star_q2_agg) AS star_rows,
       (SELECT COUNT(*) FROM (
            SELECT icd10_code, icd10_description, cpt_code, cpt_description, encounter_count, SUM(src = 'o') AS in_oltp, SUM(src = 's') AS in_star
            FROM (SELECT o.*, 'o' AS src FROM lab_compare.oltp_q2 o
                  UNION ALL
                  SELECT s.*, 's' AS src FROM lab_compare.star_q2_agg s) u
            GROUP BY icd10_code, icd10_description, cpt_code, cpt_description, encounter_count
            HAVING in_oltp <> in_star) d) AS mismatched_rows
UNION ALL
SELECT 'Q3' AS query_name,
       (SELECT COUNT(*) FROM lab_compare.oltp_q3) AS oltp_rows,
       (SELECT COUNT(*) FROM lab_compare.star_q3) AS star_rows,
       (SELECT COUNT(*) FROM (
            SELECT specialty_name, inpatient_discharges, readmissions_30d, readmission_rate_pct, SUM(src = 'o') AS in_oltp, SUM(src = 's') AS in_star
            FROM (SELECT o.*, 'o' AS src FROM lab_compare.oltp_q3 o
                  UNION ALL
                  SELECT s.*, 's' AS src FROM lab_compare.star_q3 s) u
            GROUP BY specialty_name, inpatient_discharges, readmissions_30d, readmission_rate_pct
            HAVING in_oltp <> in_star) d) AS mismatched_rows
UNION ALL
SELECT 'Q4' AS query_name,
       (SELECT COUNT(*) FROM lab_compare.oltp_q4) AS oltp_rows,
       (SELECT COUNT(*) FROM lab_compare.star_q4) AS star_rows,
       (SELECT COUNT(*) FROM (
            SELECT service_month, specialty_name, total_allowed, total_claimed, billed_encounters, SUM(src = 'o') AS in_oltp, SUM(src = 's') AS in_star
            FROM (SELECT o.*, 'o' AS src FROM lab_compare.oltp_q4 o
                  UNION ALL
                  SELECT s.*, 's' AS src FROM lab_compare.star_q4 s) u
            GROUP BY service_month, specialty_name, total_allowed, total_claimed, billed_encounters
            HAVING in_oltp <> in_star) d) AS mismatched_rows
) results;

-- Optional cleanup:  DROP DATABASE lab_compare;
