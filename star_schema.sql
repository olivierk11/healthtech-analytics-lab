-- =====================================================================
-- star_schema.sql
-- HealthTech Analytics - Star schema for encounter analytics
-- Target: MySQL 8 / MariaDB 10.6+  (InnoDB)
--
-- Grain of the fact table: ONE ROW PER ENCOUNTER.
-- Many-to-many detail (diagnoses, procedures) lives in bridge tables.
-- Every dimension has a surrogate key; key 0 = "Unknown" member so the
-- fact table never needs NULL foreign keys.
-- =====================================================================

DROP DATABASE IF EXISTS healthtech_dw;
CREATE DATABASE healthtech_dw;
USE healthtech_dw;

-- ---------------------------------------------------------------------
-- dim_date: one row per calendar day (pre-generated, 2015-01-01..2030-12-31).
-- Smart key YYYYMMDD so the key itself is human-readable and sortable,
-- and month/quarter/year attributes are pre-computed (no DATE_FORMAT at
-- query time).
-- ---------------------------------------------------------------------
CREATE TABLE dim_date (
    date_key        INT          NOT NULL PRIMARY KEY,   -- YYYYMMDD, 0 = unknown
    calendar_date   DATE         NULL,
    day_of_month    TINYINT      NULL,
    day_of_week     TINYINT      NULL,                   -- 1=Sunday..7=Saturday
    day_name        VARCHAR(10)  NULL,
    is_weekend      TINYINT(1)   NULL,
    week_of_year    TINYINT      NULL,
    month_num       TINYINT      NULL,
    month_name      VARCHAR(10)  NULL,
    month_label     CHAR(7)      NULL,                   -- '2024-05'
    month_key       INT          NULL,                   -- 202405
    quarter_num     TINYINT      NULL,
    year_quarter    CHAR(7)      NULL,                   -- '2024-Q2'
    year_num        SMALLINT     NULL,
    INDEX idx_dim_date_month (month_key)
) ENGINE=InnoDB COMMENT='Calendar dimension, one row per day; static one-time load';

-- ---------------------------------------------------------------------
-- dim_specialty: clinical specialty (Cardiology, IM, ...).
-- ---------------------------------------------------------------------
CREATE TABLE dim_specialty (
    specialty_key   INT          NOT NULL AUTO_INCREMENT PRIMARY KEY,
    specialty_id    INT          NULL,                   -- natural key from OLTP
    specialty_name  VARCHAR(100) NOT NULL,
    specialty_code  VARCHAR(10)  NULL,
    UNIQUE KEY uk_dim_specialty_nk (specialty_id)
) ENGINE=InnoDB COMMENT='Specialty dimension (SCD Type 1)';

-- ---------------------------------------------------------------------
-- dim_department: hospital department / unit.
-- ---------------------------------------------------------------------
CREATE TABLE dim_department (
    department_key  INT          NOT NULL AUTO_INCREMENT PRIMARY KEY,
    department_id   INT          NULL,
    department_name VARCHAR(100) NOT NULL,
    floor           INT          NULL,
    capacity        INT          NULL,
    UNIQUE KEY uk_dim_department_nk (department_id)
) ENGINE=InnoDB COMMENT='Department dimension (SCD Type 1)';

-- ---------------------------------------------------------------------
-- dim_encounter_type: Outpatient / Inpatient / ER (+ Unknown).
-- Tiny "junk-style" dimension so filters use an INT key and carry
-- descriptive flags (is_inpatient) instead of string comparisons.
-- ---------------------------------------------------------------------
CREATE TABLE dim_encounter_type (
    encounter_type_key  INT          NOT NULL PRIMARY KEY,
    type_name           VARCHAR(50)  NOT NULL,           -- 'Outpatient','Inpatient','ER'
    care_setting        VARCHAR(50)  NULL,               -- 'Ambulatory','Acute','Emergency'
    is_inpatient        TINYINT(1)   NOT NULL DEFAULT 0,
    UNIQUE KEY uk_dim_encounter_type_name (type_name)
) ENGINE=InnoDB COMMENT='Encounter type dimension (static)';

-- ---------------------------------------------------------------------
-- dim_patient: one row per patient VERSION (SCD Type 2 on demographic
-- attributes; name corrections handled as Type 1).
-- age_group here is the patient's CURRENT age band; age at the time of
-- care is stored on the fact row (patient_age_at_encounter) because it
-- changes with every encounter.
-- ---------------------------------------------------------------------
CREATE TABLE dim_patient (
    patient_key       INT          NOT NULL AUTO_INCREMENT PRIMARY KEY,
    patient_id        INT          NULL,                 -- natural key
    mrn               VARCHAR(20)  NULL,
    first_name        VARCHAR(100) NULL,
    last_name         VARCHAR(100) NULL,
    full_name         VARCHAR(201) NULL,
    date_of_birth     DATE         NULL,
    birth_year        SMALLINT     NULL,
    gender            CHAR(1)      NULL,
    gender_desc       VARCHAR(10)  NULL,
    age_group         VARCHAR(10)  NULL,                 -- '0-17','18-34','35-49','50-64','65-79','80+'
    effective_from    DATE         NOT NULL DEFAULT '1900-01-01',
    effective_to      DATE         NOT NULL DEFAULT '9999-12-31',
    is_current        TINYINT(1)   NOT NULL DEFAULT 1,
    row_hash          CHAR(32)     NULL,                 -- MD5 of tracked attributes, for change detection
    INDEX idx_dim_patient_nk (patient_id, is_current),
    INDEX idx_dim_patient_mrn (mrn)
) ENGINE=InnoDB COMMENT='Patient dimension (SCD Type 2)';

-- ---------------------------------------------------------------------
-- dim_provider: one row per provider VERSION (SCD Type 2).
-- Specialty and department are denormalized onto the provider row so a
-- provider-centric report needs one join, not three.
-- ---------------------------------------------------------------------
CREATE TABLE dim_provider (
    provider_key      INT          NOT NULL AUTO_INCREMENT PRIMARY KEY,
    provider_id       INT          NULL,
    first_name        VARCHAR(100) NULL,
    last_name         VARCHAR(100) NULL,
    full_name         VARCHAR(201) NULL,
    credential        VARCHAR(20)  NULL,
    specialty_key     INT          NOT NULL DEFAULT 0,
    specialty_name    VARCHAR(100) NULL,                 -- denormalized
    specialty_code    VARCHAR(10)  NULL,                 -- denormalized
    department_key    INT          NOT NULL DEFAULT 0,
    department_name   VARCHAR(100) NULL,                 -- denormalized
    effective_from    DATE         NOT NULL DEFAULT '1900-01-01',
    effective_to      DATE         NOT NULL DEFAULT '9999-12-31',
    is_current        TINYINT(1)   NOT NULL DEFAULT 1,
    row_hash          CHAR(32)     NULL,
    INDEX idx_dim_provider_nk (provider_id, is_current)
) ENGINE=InnoDB COMMENT='Provider dimension (SCD Type 2), specialty/department denormalized';

-- ---------------------------------------------------------------------
-- dim_diagnosis / dim_procedure: code dimensions used via bridge tables.
-- ---------------------------------------------------------------------
CREATE TABLE dim_diagnosis (
    diagnosis_key       INT          NOT NULL AUTO_INCREMENT PRIMARY KEY,
    diagnosis_id        INT          NULL,
    icd10_code          VARCHAR(10)  NOT NULL,
    icd10_description   VARCHAR(200) NULL,
    icd10_category      VARCHAR(3)   NULL,               -- first 3 chars, e.g. 'I50'
    icd10_chapter       CHAR(1)      NULL,               -- first letter, e.g. 'I' (circulatory)
    UNIQUE KEY uk_dim_diagnosis_nk (diagnosis_id),
    INDEX idx_dim_diagnosis_code (icd10_code)
) ENGINE=InnoDB COMMENT='ICD-10 diagnosis dimension (SCD Type 1)';

CREATE TABLE dim_procedure (
    procedure_key     INT          NOT NULL AUTO_INCREMENT PRIMARY KEY,
    procedure_id      INT          NULL,
    cpt_code          VARCHAR(10)  NOT NULL,
    cpt_description   VARCHAR(200) NULL,
    UNIQUE KEY uk_dim_procedure_nk (procedure_id),
    INDEX idx_dim_procedure_code (cpt_code)
) ENGINE=InnoDB COMMENT='CPT procedure dimension (SCD Type 1)';

-- ---------------------------------------------------------------------
-- fact_encounters: ONE ROW PER ENCOUNTER.
-- * specialty_key is stored directly on the fact (copied from the
--   provider's specialty at the time of the encounter) so specialty
--   reports skip the provider hop entirely.
-- * Counts and billing totals are pre-aggregated from the junction /
--   billing tables during ETL.
-- * Readmission flags are pre-computed in ETL, replacing the runtime
--   self-join.
-- ---------------------------------------------------------------------
CREATE TABLE fact_encounters (
    encounter_key               BIGINT        NOT NULL AUTO_INCREMENT PRIMARY KEY,
    encounter_id                INT           NOT NULL,     -- degenerate dimension (source id)

    -- dimension foreign keys
    encounter_date_key          INT           NOT NULL DEFAULT 0,
    discharge_date_key          INT           NOT NULL DEFAULT 0,
    patient_key                 INT           NOT NULL DEFAULT 0,
    provider_key                INT           NOT NULL DEFAULT 0,
    specialty_key               INT           NOT NULL DEFAULT 0,
    department_key              INT           NOT NULL DEFAULT 0,
    encounter_type_key          INT           NOT NULL DEFAULT 0,
    primary_diagnosis_key       INT           NOT NULL DEFAULT 0,   -- diagnosis_sequence = 1

    -- timestamps kept for interval logic / drill-through
    encounter_datetime          DATETIME      NULL,
    discharge_datetime          DATETIME      NULL,

    -- pre-aggregated / derived measures
    diagnosis_count             SMALLINT      NOT NULL DEFAULT 0,
    procedure_count             SMALLINT      NOT NULL DEFAULT 0,
    claim_count                 SMALLINT      NOT NULL DEFAULT 0,
    total_claim_amount          DECIMAL(12,2) NOT NULL DEFAULT 0,
    total_allowed_amount        DECIMAL(12,2) NOT NULL DEFAULT 0,
    length_of_stay_hours        DECIMAL(8,2)  NULL,
    length_of_stay_days         SMALLINT      NULL,          -- calendar days (inpatient LOS)
    patient_age_at_encounter    SMALLINT      NULL,
    is_inpatient                TINYINT(1)    NOT NULL DEFAULT 0,
    is_readmission              TINYINT(1)    NOT NULL DEFAULT 0, -- this stay began <=30d after a prior inpatient discharge
    readmitted_within_30d       TINYINT(1)    NOT NULL DEFAULT 0, -- this inpatient stay was followed by a readmission <=30d
    days_to_next_admission      SMALLINT      NULL,

    -- audit
    etl_loaded_at               DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    etl_updated_at              DATETIME      NULL,

    UNIQUE KEY uk_fact_encounter_id (encounter_id),
    -- Covering indexes: each report is answered from the index alone ("Using index"),
    -- never touching the 400MB clustered row data.
    -- Q1: month x specialty x type, COUNT(DISTINCT patient)
    INDEX idx_fact_date_spec_type (encounter_date_key, specialty_key, encounter_type_key, patient_key),
    -- Q4: revenue by month x specialty (measures INCLUDED in the index)
    INDEX idx_fact_rev_cover (encounter_date_key, specialty_key, claim_count, total_allowed_amount, total_claim_amount),
    -- Q3: inpatient readmission rate by specialty (pre-computed flag INCLUDED)
    INDEX idx_fact_readmit_cover (encounter_type_key, specialty_key, discharge_date_key, readmitted_within_30d),
    INDEX idx_fact_specialty (specialty_key),
    INDEX idx_fact_patient (patient_key, encounter_datetime),
    INDEX idx_fact_provider (provider_key),
    INDEX idx_fact_department (department_key),

    CONSTRAINT fk_fact_enc_date   FOREIGN KEY (encounter_date_key)    REFERENCES dim_date(date_key),
    CONSTRAINT fk_fact_dis_date   FOREIGN KEY (discharge_date_key)    REFERENCES dim_date(date_key),
    CONSTRAINT fk_fact_patient    FOREIGN KEY (patient_key)           REFERENCES dim_patient(patient_key),
    CONSTRAINT fk_fact_provider   FOREIGN KEY (provider_key)          REFERENCES dim_provider(provider_key),
    CONSTRAINT fk_fact_specialty  FOREIGN KEY (specialty_key)         REFERENCES dim_specialty(specialty_key),
    CONSTRAINT fk_fact_department FOREIGN KEY (department_key)        REFERENCES dim_department(department_key),
    CONSTRAINT fk_fact_enc_type   FOREIGN KEY (encounter_type_key)    REFERENCES dim_encounter_type(encounter_type_key),
    CONSTRAINT fk_fact_primary_dx FOREIGN KEY (primary_diagnosis_key) REFERENCES dim_diagnosis(diagnosis_key)
) ENGINE=InnoDB COMMENT='Encounter fact, grain = one row per encounter';

-- ---------------------------------------------------------------------
-- bridge_encounter_diagnoses: encounter <-> diagnosis (many-to-many).
-- Clustered on encounter_key so all diagnoses of an encounter sit
-- together on disk (the OLTP junction table is clustered on its own
-- surrogate id, forcing random lookups).
-- ---------------------------------------------------------------------
CREATE TABLE bridge_encounter_diagnoses (
    encounter_key        BIGINT    NOT NULL,
    diagnosis_sequence   SMALLINT  NOT NULL,
    diagnosis_key        INT       NOT NULL DEFAULT 0,
    is_primary           TINYINT(1) NOT NULL DEFAULT 0,
    PRIMARY KEY (encounter_key, diagnosis_sequence),
    INDEX idx_bridge_dx_diag (diagnosis_key, encounter_key),
    CONSTRAINT fk_bdx_encounter FOREIGN KEY (encounter_key) REFERENCES fact_encounters(encounter_key),
    CONSTRAINT fk_bdx_diagnosis FOREIGN KEY (diagnosis_key) REFERENCES dim_diagnosis(diagnosis_key)
) ENGINE=InnoDB COMMENT='Bridge: diagnoses per encounter';

-- ---------------------------------------------------------------------
-- bridge_encounter_procedures: encounter <-> procedure (many-to-many).
-- procedure_line is a per-encounter sequence (source has no sequence).
-- ---------------------------------------------------------------------
CREATE TABLE bridge_encounter_procedures (
    encounter_key        BIGINT    NOT NULL,
    procedure_line       SMALLINT  NOT NULL,
    procedure_key        INT       NOT NULL DEFAULT 0,
    procedure_date_key   INT       NOT NULL DEFAULT 0,
    PRIMARY KEY (encounter_key, procedure_line),
    INDEX idx_bridge_px_proc (procedure_key, encounter_key),
    CONSTRAINT fk_bpx_encounter FOREIGN KEY (encounter_key)      REFERENCES fact_encounters(encounter_key),
    CONSTRAINT fk_bpx_procedure FOREIGN KEY (procedure_key)      REFERENCES dim_procedure(procedure_key),
    CONSTRAINT fk_bpx_date      FOREIGN KEY (procedure_date_key) REFERENCES dim_date(date_key)
) ENGINE=InnoDB COMMENT='Bridge: procedures per encounter';

-- ---------------------------------------------------------------------
-- agg_diagnosis_procedure_pairs (OPTIONAL aggregate table).
-- Q2 is the only question that still needs two bridges. If the pair
-- report is run often, ETL materializes it once per load.
-- ---------------------------------------------------------------------
CREATE TABLE agg_diagnosis_procedure_pairs (
    diagnosis_key     INT     NOT NULL,
    procedure_key     INT     NOT NULL,
    encounter_count   INT     NOT NULL,
    PRIMARY KEY (diagnosis_key, procedure_key),
    INDEX idx_agg_pair_count (encounter_count)
) ENGINE=InnoDB COMMENT='Aggregate: distinct encounters per diagnosis-procedure pair (rebuilt by ETL)';

-- ---------------------------------------------------------------------
-- Unknown members (key 0) so every fact FK resolves.
-- ---------------------------------------------------------------------
SET SESSION sql_mode = CONCAT(@@sql_mode, ',NO_AUTO_VALUE_ON_ZERO');
INSERT INTO dim_date (date_key, month_label) VALUES (0, 'Unknown');
INSERT INTO dim_specialty  (specialty_key, specialty_id, specialty_name, specialty_code) VALUES (0, NULL, 'Unknown', 'UNK');
INSERT INTO dim_department (department_key, department_id, department_name) VALUES (0, NULL, 'Unknown');
INSERT INTO dim_patient    (patient_key, patient_id, full_name, age_group) VALUES (0, NULL, 'Unknown', 'Unknown');
INSERT INTO dim_provider   (provider_key, provider_id, full_name, specialty_name, department_name) VALUES (0, NULL, 'Unknown', 'Unknown', 'Unknown');
INSERT INTO dim_diagnosis  (diagnosis_key, diagnosis_id, icd10_code, icd10_description) VALUES (0, NULL, 'UNK', 'Unknown');
INSERT INTO dim_procedure  (procedure_key, procedure_id, cpt_code, cpt_description) VALUES (0, NULL, 'UNK', 'Unknown');
INSERT INTO dim_encounter_type (encounter_type_key, type_name, care_setting, is_inpatient) VALUES
    (0, 'Unknown',    'Unknown',    0),
    (1, 'Outpatient', 'Ambulatory', 0),
    (2, 'Inpatient',  'Acute',      1),
    (3, 'ER',         'Emergency',  0);
