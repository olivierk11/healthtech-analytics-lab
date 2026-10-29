-- GENERATED from etl_load_template.sql: source = healthtech_oltp (the small sample), mode = FULL.
-- Ready to run as-is (MySQL Workbench: open and click Execute).
-- =====================================================================
-- etl_load.sql  -  OLTP (healthtech_oltp) -> star schema (healthtech_dw)
-- Idempotent: safe to re-run. Upserts dimensions, processes the set of
-- encounters listed in stg_encounter_batch (full load = all encounters,
-- incremental = changed/new encounters + lookback window).
-- Replace healthtech_oltp with the source schema name before running.
-- =====================================================================
USE healthtech_dw;
SET SQL_SAFE_UPDATES = 0, SQL_BIG_SELECTS = 1;   -- MySQL Workbench enables safe-update mode by default; the ETL's
                                                -- UPDATE/DELETE ... JOIN statements and big joins need it off
SET SESSION sql_mode = CONCAT(@@sql_mode, ',NO_AUTO_VALUE_ON_ZERO');
SET @load_ts = NOW();
SET @run_mode = 'FULL';           -- this file always does a FULL load
SET @lookback_days = IFNULL(@lookback_days, 45);

-- ---------------------------------------------------------------
-- 1. dim_date (one-time; INSERT IGNORE makes re-runs harmless)
-- ---------------------------------------------------------------
-- (number generator via cross join instead of a recursive CTE: MariaDB caps
--  recursion at 1000 iterations by default and silently truncates)
INSERT IGNORE INTO dim_date
SELECT CAST(DATE_FORMAT(dt,'%Y%m%d') AS UNSIGNED), dt, DAY(dt), DAYOFWEEK(dt), DAYNAME(dt),
       DAYOFWEEK(dt) IN (1,7), WEEK(dt,3), MONTH(dt), MONTHNAME(dt), DATE_FORMAT(dt,'%Y-%m'),
       YEAR(dt)*100+MONTH(dt), QUARTER(dt), CONCAT(YEAR(dt),'-Q',QUARTER(dt)), YEAR(dt)
FROM (
    SELECT DATE('2015-01-01') + INTERVAL (a.n + 10*b.n + 100*c.n + 1000*d.n) DAY AS dt
    FROM (SELECT 0 n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
          UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) a,
         (SELECT 0 n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
          UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) b,
         (SELECT 0 n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
          UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) c,
         (SELECT 0 n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
          UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) d
) days
WHERE dt <= '2030-12-31';

-- ---------------------------------------------------------------
-- 2. Type-1 dimensions: upsert by natural key
-- ---------------------------------------------------------------
INSERT INTO dim_specialty (specialty_id, specialty_name, specialty_code)
SELECT specialty_id, COALESCE(specialty_name,'Unknown'), specialty_code FROM healthtech_oltp.specialties
ON DUPLICATE KEY UPDATE specialty_name = VALUES(specialty_name), specialty_code = VALUES(specialty_code);

INSERT INTO dim_department (department_id, department_name, floor, capacity)
SELECT department_id, COALESCE(department_name,'Unknown'), floor, capacity FROM healthtech_oltp.departments
ON DUPLICATE KEY UPDATE department_name = VALUES(department_name), floor = VALUES(floor), capacity = VALUES(capacity);

INSERT INTO dim_diagnosis (diagnosis_id, icd10_code, icd10_description, icd10_category, icd10_chapter)
SELECT diagnosis_id, COALESCE(icd10_code,'UNK'), icd10_description, LEFT(icd10_code,3), LEFT(icd10_code,1) FROM healthtech_oltp.diagnoses
ON DUPLICATE KEY UPDATE icd10_code = VALUES(icd10_code), icd10_description = VALUES(icd10_description),
                        icd10_category = VALUES(icd10_category), icd10_chapter = VALUES(icd10_chapter);

INSERT INTO dim_procedure (procedure_id, cpt_code, cpt_description)
SELECT procedure_id, COALESCE(cpt_code,'UNK'), cpt_description FROM healthtech_oltp.procedures
ON DUPLICATE KEY UPDATE cpt_code = VALUES(cpt_code), cpt_description = VALUES(cpt_description);

-- ---------------------------------------------------------------
-- 3. dim_patient (SCD Type 2): stage -> expire changed -> insert new
-- ---------------------------------------------------------------
DROP TEMPORARY TABLE IF EXISTS stg_patient;
CREATE TEMPORARY TABLE stg_patient AS
SELECT p.patient_id, p.mrn, p.first_name, p.last_name,
       TRIM(CONCAT(COALESCE(p.first_name,''),' ',COALESCE(p.last_name,''))) AS full_name,
       p.date_of_birth, YEAR(p.date_of_birth) AS birth_year, UPPER(p.gender) AS gender,
       CASE UPPER(p.gender) WHEN 'M' THEN 'Male' WHEN 'F' THEN 'Female' ELSE 'Unknown' END AS gender_desc,
       CASE WHEN p.date_of_birth IS NULL THEN 'Unknown'
            WHEN TIMESTAMPDIFF(YEAR,p.date_of_birth,CURDATE()) < 18 THEN '0-17'
            WHEN TIMESTAMPDIFF(YEAR,p.date_of_birth,CURDATE()) < 35 THEN '18-34'
            WHEN TIMESTAMPDIFF(YEAR,p.date_of_birth,CURDATE()) < 50 THEN '35-49'
            WHEN TIMESTAMPDIFF(YEAR,p.date_of_birth,CURDATE()) < 65 THEN '50-64'
            WHEN TIMESTAMPDIFF(YEAR,p.date_of_birth,CURDATE()) < 80 THEN '65-79'
            ELSE '80+' END AS age_group,
       MD5(CONCAT_WS('|', p.date_of_birth, UPPER(p.gender), p.mrn)) AS row_hash   -- Type-2 tracked attributes
FROM healthtech_oltp.patients p;
CREATE INDEX ix_stg_patient ON stg_patient(patient_id);

-- Type-1 attributes (name corrections, age band refresh): overwrite in place on current row
UPDATE dim_patient d JOIN stg_patient s ON d.patient_id = s.patient_id AND d.is_current = 1
SET d.first_name = s.first_name, d.last_name = s.last_name, d.full_name = s.full_name, d.age_group = s.age_group
WHERE d.row_hash = s.row_hash;

-- Type-2: close out current versions whose tracked attributes changed
UPDATE dim_patient d JOIN stg_patient s ON d.patient_id = s.patient_id AND d.is_current = 1
SET d.is_current = 0, d.effective_to = CURDATE() - INTERVAL 1 DAY
WHERE d.row_hash <> s.row_hash;

-- Insert brand-new patients and new versions of changed patients
INSERT INTO dim_patient (patient_id, mrn, first_name, last_name, full_name, date_of_birth, birth_year,
                         gender, gender_desc, age_group, effective_from, effective_to, is_current, row_hash)
SELECT s.patient_id, s.mrn, s.first_name, s.last_name, s.full_name, s.date_of_birth, s.birth_year,
       s.gender, s.gender_desc, s.age_group,
       CASE WHEN EXISTS (SELECT 1 FROM dim_patient x WHERE x.patient_id = s.patient_id) THEN CURDATE() ELSE '1900-01-01' END,
       '9999-12-31', 1, s.row_hash
FROM stg_patient s
LEFT JOIN dim_patient d ON d.patient_id = s.patient_id AND d.is_current = 1
WHERE d.patient_key IS NULL;

-- ---------------------------------------------------------------
-- 4. dim_provider (SCD Type 2; specialty & department denormalized)
-- ---------------------------------------------------------------
DROP TEMPORARY TABLE IF EXISTS stg_provider;
CREATE TEMPORARY TABLE stg_provider AS
SELECT pr.provider_id, pr.first_name, pr.last_name,
       TRIM(CONCAT(COALESCE(pr.first_name,''),' ',COALESCE(pr.last_name,''))) AS full_name, pr.credential,
       COALESCE(ds.specialty_key,0) AS specialty_key, COALESCE(ds.specialty_name,'Unknown') AS specialty_name, ds.specialty_code,
       COALESCE(dd.department_key,0) AS department_key, COALESCE(dd.department_name,'Unknown') AS department_name,
       MD5(CONCAT_WS('|', pr.credential, pr.specialty_id, pr.department_id)) AS row_hash
FROM healthtech_oltp.providers pr
LEFT JOIN dim_specialty  ds ON ds.specialty_id  = pr.specialty_id
LEFT JOIN dim_department dd ON dd.department_id = pr.department_id;

UPDATE dim_provider d JOIN stg_provider s ON d.provider_id = s.provider_id AND d.is_current = 1
SET d.first_name = s.first_name, d.last_name = s.last_name, d.full_name = s.full_name,
    d.specialty_name = s.specialty_name, d.department_name = s.department_name
WHERE d.row_hash = s.row_hash;

UPDATE dim_provider d JOIN stg_provider s ON d.provider_id = s.provider_id AND d.is_current = 1
SET d.is_current = 0, d.effective_to = CURDATE() - INTERVAL 1 DAY
WHERE d.row_hash <> s.row_hash;

INSERT INTO dim_provider (provider_id, first_name, last_name, full_name, credential, specialty_key, specialty_name,
                          specialty_code, department_key, department_name, effective_from, effective_to, is_current, row_hash)
SELECT s.provider_id, s.first_name, s.last_name, s.full_name, s.credential, s.specialty_key, s.specialty_name,
       s.specialty_code, s.department_key, s.department_name,
       CASE WHEN EXISTS (SELECT 1 FROM dim_provider x WHERE x.provider_id = s.provider_id) THEN CURDATE() ELSE '1900-01-01' END,
       '9999-12-31', 1, s.row_hash
FROM stg_provider s
LEFT JOIN dim_provider d ON d.provider_id = s.provider_id AND d.is_current = 1
WHERE d.provider_key IS NULL;

-- ---------------------------------------------------------------
-- 5. Encounter batch to process
--    FULL: every encounter.  INCREMENTAL: encounters admitted/discharged
--    in the lookback window + encounters with new billing, diagnosis or
--    procedure rows (late-arriving facts) + prior inpatient stays of
--    patients with new admissions (their readmission flag can flip).
-- ---------------------------------------------------------------
DROP TEMPORARY TABLE IF EXISTS stg_encounter_batch;
CREATE TEMPORARY TABLE stg_encounter_batch (encounter_id INT PRIMARY KEY);

INSERT IGNORE INTO stg_encounter_batch
SELECT encounter_id FROM healthtech_oltp.encounters
WHERE @run_mode = 'FULL'
   OR encounter_date >= CURDATE() - INTERVAL @lookback_days DAY
   OR discharge_date >= CURDATE() - INTERVAL @lookback_days DAY;

INSERT IGNORE INTO stg_encounter_batch
SELECT b.encounter_id FROM healthtech_oltp.billing b
WHERE @run_mode <> 'FULL' AND b.claim_date >= CURDATE() - INTERVAL @lookback_days DAY;

-- earlier inpatient stays of the same patients (their readmission flag can flip).
-- Seed copy avoids reading a temp table we are inserting into (not allowed in MySQL 8).
DROP TEMPORARY TABLE IF EXISTS stg_batch_seed;
CREATE TEMPORARY TABLE stg_batch_seed (encounter_id INT PRIMARY KEY) AS SELECT encounter_id FROM stg_encounter_batch;
INSERT IGNORE INTO stg_encounter_batch
SELECT prev.encounter_id
FROM stg_batch_seed nb
JOIN healthtech_oltp.encounters newe ON newe.encounter_id = nb.encounter_id
JOIN healthtech_oltp.encounters prev ON prev.patient_id   = newe.patient_id
WHERE @run_mode <> 'FULL' AND prev.encounter_type = 'Inpatient'
  AND prev.discharge_date >= newe.encounter_date - INTERVAL 30 DAY;

-- ---------------------------------------------------------------
-- 6. Pre-aggregate child tables to encounter grain
-- ---------------------------------------------------------------
DROP TEMPORARY TABLE IF EXISTS stg_dx;
CREATE TEMPORARY TABLE stg_dx (encounter_id INT PRIMARY KEY, diagnosis_count INT, primary_diagnosis_id INT) AS
SELECT ed.encounter_id, COUNT(*) AS diagnosis_count,
       MIN(CASE WHEN ed.diagnosis_sequence = 1 THEN ed.diagnosis_id END) AS primary_diagnosis_id
FROM healthtech_oltp.encounter_diagnoses ed JOIN stg_encounter_batch b ON b.encounter_id = ed.encounter_id
GROUP BY ed.encounter_id;

DROP TEMPORARY TABLE IF EXISTS stg_px;
CREATE TEMPORARY TABLE stg_px (encounter_id INT PRIMARY KEY, procedure_count INT) AS
SELECT ep.encounter_id, COUNT(*) AS procedure_count
FROM healthtech_oltp.encounter_procedures ep JOIN stg_encounter_batch b ON b.encounter_id = ep.encounter_id
GROUP BY ep.encounter_id;

DROP TEMPORARY TABLE IF EXISTS stg_bill;
CREATE TEMPORARY TABLE stg_bill (encounter_id INT PRIMARY KEY, claim_count INT, total_claim DECIMAL(14,2), total_allowed DECIMAL(14,2)) AS
SELECT bl.encounter_id, COUNT(*) AS claim_count, COALESCE(SUM(bl.claim_amount),0) AS total_claim,
       COALESCE(SUM(bl.allowed_amount),0) AS total_allowed
FROM healthtech_oltp.billing bl JOIN stg_encounter_batch b ON b.encounter_id = bl.encounter_id
GROUP BY bl.encounter_id;

-- Readmission flags: computed ONCE here instead of in every report.
-- Definition (same as OLTP Q3): an inpatient stay is "readmitted_within_30d"
-- if the same patient has another inpatient admission whose start is after
-- this discharge and no more than 30 days later.
DROP TEMPORARY TABLE IF EXISTS stg_readmit;
CREATE TEMPORARY TABLE stg_readmit (encounter_id INT PRIMARY KEY, readmitted_within_30d TINYINT, days_to_next_admission INT, is_readmission TINYINT) AS
SELECT x.encounter_id,
       (x.next_admit IS NOT NULL AND x.next_admit <= x.discharge_date + INTERVAL 30 DAY) AS readmitted_within_30d,
       DATEDIFF(x.next_admit, x.discharge_date) AS days_to_next_admission,
       x.is_readmission
FROM (
    SELECT e.encounter_id, e.discharge_date,
           (SELECT MIN(r.encounter_date) FROM healthtech_oltp.encounters r            -- next inpatient admission after discharge
             WHERE r.patient_id = e.patient_id AND r.encounter_type = 'Inpatient'
               AND r.encounter_id <> e.encounter_id AND r.encounter_date > e.discharge_date) AS next_admit,
           EXISTS (SELECT 1 FROM healthtech_oltp.encounters p                          -- was THIS stay itself a readmission?
                    WHERE p.patient_id = e.patient_id AND p.encounter_type = 'Inpatient' AND p.encounter_id <> e.encounter_id
                      AND e.encounter_date > p.discharge_date
                      AND e.encounter_date <= p.discharge_date + INTERVAL 30 DAY) AS is_readmission
    FROM healthtech_oltp.encounters e
    JOIN stg_encounter_batch b ON b.encounter_id = e.encounter_id
    WHERE e.encounter_type = 'Inpatient' AND e.discharge_date IS NOT NULL
) x;

-- ---------------------------------------------------------------
-- 7. Fact upsert (dimension key lookups; unknown member 0 for misses)
-- ---------------------------------------------------------------
INSERT INTO fact_encounters (
    encounter_id, encounter_date_key, discharge_date_key, patient_key, provider_key, specialty_key, department_key,
    encounter_type_key, primary_diagnosis_key, encounter_datetime, discharge_datetime,
    diagnosis_count, procedure_count, claim_count, total_claim_amount, total_allowed_amount,
    length_of_stay_hours, length_of_stay_days, patient_age_at_encounter, is_inpatient,
    is_readmission, readmitted_within_30d, days_to_next_admission, etl_loaded_at)
SELECT e.encounter_id,
       COALESCE(dd1.date_key, 0),
       COALESCE(dd2.date_key, 0),
       COALESCE(dp.patient_key, 0),
       COALESCE(dpr.provider_key, 0),
       COALESCE(dpr.specialty_key, 0),
       COALESCE(ddep.department_key, dpr.department_key, 0),   -- fall back to provider's home department
       COALESCE(det.encounter_type_key, 0),
       COALESCE(ddx.diagnosis_key, 0),
       e.encounter_date, e.discharge_date,
       COALESCE(dx.diagnosis_count, 0), COALESCE(px.procedure_count, 0),
       COALESCE(bl.claim_count, 0), COALESCE(bl.total_claim, 0), COALESCE(bl.total_allowed, 0),
       CASE WHEN e.discharge_date >= e.encounter_date THEN ROUND(TIMESTAMPDIFF(MINUTE, e.encounter_date, e.discharge_date)/60, 2) END,
       CASE WHEN e.discharge_date >= e.encounter_date THEN DATEDIFF(e.discharge_date, e.encounter_date) END,
       CASE WHEN dp.date_of_birth IS NOT NULL THEN TIMESTAMPDIFF(YEAR, dp.date_of_birth, e.encounter_date) END,
       COALESCE(det.is_inpatient, 0),
       COALESCE(ra.is_readmission, 0), COALESCE(ra.readmitted_within_30d, 0), ra.days_to_next_admission,
       @load_ts
FROM healthtech_oltp.encounters e
JOIN stg_encounter_batch b         ON b.encounter_id = e.encounter_id
LEFT JOIN dim_date dd1             ON dd1.date_key = CAST(DATE_FORMAT(e.encounter_date,'%Y%m%d') AS UNSIGNED)
LEFT JOIN dim_date dd2             ON dd2.date_key = CAST(DATE_FORMAT(e.discharge_date,'%Y%m%d') AS UNSIGNED)
LEFT JOIN dim_patient dp           ON dp.patient_id = e.patient_id
                                  AND DATE(e.encounter_date) BETWEEN dp.effective_from AND dp.effective_to
LEFT JOIN dim_provider dpr         ON dpr.provider_id = e.provider_id
                                  AND DATE(e.encounter_date) BETWEEN dpr.effective_from AND dpr.effective_to
LEFT JOIN dim_department ddep      ON ddep.department_id = e.department_id
LEFT JOIN dim_encounter_type det   ON det.type_name = e.encounter_type
LEFT JOIN stg_dx dx                ON dx.encounter_id = e.encounter_id
LEFT JOIN dim_diagnosis ddx        ON ddx.diagnosis_id = dx.primary_diagnosis_id
LEFT JOIN stg_px px                ON px.encounter_id = e.encounter_id
LEFT JOIN stg_bill bl              ON bl.encounter_id = e.encounter_id
LEFT JOIN stg_readmit ra           ON ra.encounter_id = e.encounter_id
ON DUPLICATE KEY UPDATE
    encounter_date_key = VALUES(encounter_date_key), discharge_date_key = VALUES(discharge_date_key),
    patient_key = VALUES(patient_key), provider_key = VALUES(provider_key), specialty_key = VALUES(specialty_key),
    department_key = VALUES(department_key), encounter_type_key = VALUES(encounter_type_key),
    primary_diagnosis_key = VALUES(primary_diagnosis_key),
    encounter_datetime = VALUES(encounter_datetime), discharge_datetime = VALUES(discharge_datetime),
    diagnosis_count = VALUES(diagnosis_count), procedure_count = VALUES(procedure_count),
    claim_count = VALUES(claim_count), total_claim_amount = VALUES(total_claim_amount),
    total_allowed_amount = VALUES(total_allowed_amount), length_of_stay_hours = VALUES(length_of_stay_hours),
    length_of_stay_days = VALUES(length_of_stay_days), patient_age_at_encounter = VALUES(patient_age_at_encounter),
    is_inpatient = VALUES(is_inpatient), is_readmission = VALUES(is_readmission),
    readmitted_within_30d = VALUES(readmitted_within_30d), days_to_next_admission = VALUES(days_to_next_admission),
    etl_updated_at = @load_ts;

-- ---------------------------------------------------------------
-- 8. Bridges: replace the child rows of every encounter in the batch
-- ---------------------------------------------------------------
DROP TEMPORARY TABLE IF EXISTS stg_batch_keys;
CREATE TEMPORARY TABLE stg_batch_keys (encounter_key BIGINT PRIMARY KEY, encounter_id INT, UNIQUE(encounter_id)) AS
SELECT f.encounter_key, f.encounter_id FROM fact_encounters f JOIN stg_encounter_batch b ON b.encounter_id = f.encounter_id;

DELETE bdx FROM bridge_encounter_diagnoses bdx JOIN stg_batch_keys k ON k.encounter_key = bdx.encounter_key;
INSERT INTO bridge_encounter_diagnoses (encounter_key, diagnosis_sequence, diagnosis_key, is_primary)
SELECT k.encounter_key,
       ROW_NUMBER() OVER (PARTITION BY ed.encounter_id ORDER BY ed.diagnosis_sequence, ed.encounter_diagnosis_id),  -- guards duplicate/NULL sequences
       COALESCE(dd.diagnosis_key, 0),
       ed.diagnosis_sequence = 1
FROM healthtech_oltp.encounter_diagnoses ed
JOIN stg_batch_keys k        ON k.encounter_id = ed.encounter_id
LEFT JOIN dim_diagnosis dd   ON dd.diagnosis_id = ed.diagnosis_id;

DELETE bpx FROM bridge_encounter_procedures bpx JOIN stg_batch_keys k ON k.encounter_key = bpx.encounter_key;
INSERT INTO bridge_encounter_procedures (encounter_key, procedure_line, procedure_key, procedure_date_key)
SELECT k.encounter_key,
       ROW_NUMBER() OVER (PARTITION BY ep.encounter_id ORDER BY ep.procedure_date, ep.encounter_procedure_id),
       COALESCE(dpc.procedure_key, 0),
       COALESCE(dd.date_key, 0)
FROM healthtech_oltp.encounter_procedures ep
JOIN stg_batch_keys k        ON k.encounter_id = ep.encounter_id
LEFT JOIN dim_procedure dpc  ON dpc.procedure_id = ep.procedure_id
LEFT JOIN dim_date dd        ON dd.date_key = CAST(DATE_FORMAT(ep.procedure_date,'%Y%m%d') AS UNSIGNED);

-- ---------------------------------------------------------------
-- 9. Optional aggregate for Q2 (full rebuild; cheap relative to queries)
-- ---------------------------------------------------------------
TRUNCATE TABLE agg_diagnosis_procedure_pairs;
INSERT INTO agg_diagnosis_procedure_pairs (diagnosis_key, procedure_key, encounter_count)
SELECT bdx.diagnosis_key, bpx.procedure_key, COUNT(DISTINCT bdx.encounter_key)
FROM bridge_encounter_diagnoses bdx
JOIN bridge_encounter_procedures bpx ON bpx.encounter_key = bdx.encounter_key
GROUP BY bdx.diagnosis_key, bpx.procedure_key;

ANALYZE TABLE dim_patient, dim_provider, fact_encounters, bridge_encounter_diagnoses, bridge_encounter_procedures, agg_diagnosis_procedure_pairs;
