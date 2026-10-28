-- Synthetic data at production-like volume, same OLTP schema.
-- Portable: runs on MySQL 8.0+ and MariaDB 10.6+.
-- Creates database healthtech_oltp_big using the same tables as oltp_schema.sql, then fills it.
DROP DATABASE IF EXISTS healthtech_oltp_big;
CREATE DATABASE healthtech_oltp_big;
USE healthtech_oltp_big;
CREATE TABLE patients (patient_id INT PRIMARY KEY, first_name VARCHAR(100), last_name VARCHAR(100), date_of_birth DATE, gender CHAR(1), mrn VARCHAR(20) UNIQUE);
CREATE TABLE specialties (specialty_id INT PRIMARY KEY, specialty_name VARCHAR(100), specialty_code VARCHAR(10));
CREATE TABLE departments (department_id INT PRIMARY KEY, department_name VARCHAR(100), floor INT, capacity INT);
CREATE TABLE providers (provider_id INT PRIMARY KEY, first_name VARCHAR(100), last_name VARCHAR(100), credential VARCHAR(20), specialty_id INT, department_id INT,
  FOREIGN KEY (specialty_id) REFERENCES specialties(specialty_id), FOREIGN KEY (department_id) REFERENCES departments(department_id));
CREATE TABLE encounters (encounter_id INT PRIMARY KEY, patient_id INT, provider_id INT, encounter_type VARCHAR(50), encounter_date DATETIME, discharge_date DATETIME, department_id INT,
  FOREIGN KEY (patient_id) REFERENCES patients(patient_id), FOREIGN KEY (provider_id) REFERENCES providers(provider_id),
  FOREIGN KEY (department_id) REFERENCES departments(department_id), INDEX idx_encounter_date (encounter_date));
CREATE TABLE diagnoses (diagnosis_id INT PRIMARY KEY, icd10_code VARCHAR(10), icd10_description VARCHAR(200));
CREATE TABLE encounter_diagnoses (encounter_diagnosis_id INT PRIMARY KEY, encounter_id INT, diagnosis_id INT, diagnosis_sequence INT,
  FOREIGN KEY (encounter_id) REFERENCES encounters(encounter_id), FOREIGN KEY (diagnosis_id) REFERENCES diagnoses(diagnosis_id));
CREATE TABLE procedures (procedure_id INT PRIMARY KEY, cpt_code VARCHAR(10), cpt_description VARCHAR(200));
CREATE TABLE encounter_procedures (encounter_procedure_id INT PRIMARY KEY, encounter_id INT, procedure_id INT, procedure_date DATE,
  FOREIGN KEY (encounter_id) REFERENCES encounters(encounter_id), FOREIGN KEY (procedure_id) REFERENCES procedures(procedure_id));
CREATE TABLE billing (billing_id INT PRIMARY KEY, encounter_id INT, claim_amount DECIMAL(12,2), allowed_amount DECIMAL(12,2), claim_date DATE, claim_status VARCHAR(50),
  FOREIGN KEY (encounter_id) REFERENCES encounters(encounter_id), INDEX idx_claim_date (claim_date));
-- numbers 1..1,000,000 (helper, dropped at the end)
CREATE TABLE nums (n INT PRIMARY KEY);
INSERT INTO nums
SELECT 1 + a.d + 10*b.d + 100*c.d + 1000*d.d + 10000*e.d + 100000*f.d
FROM (SELECT 0 d UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) a
CROSS JOIN (SELECT 0 d UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) b
CROSS JOIN (SELECT 0 d UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) c
CROSS JOIN (SELECT 0 d UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) d
CROSS JOIN (SELECT 0 d UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) e
CROSS JOIN (SELECT 0 d UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) f;
COMMIT;
SET foreign_key_checks=0, unique_checks=0, autocommit=0;

INSERT INTO specialties
SELECT n, ELT(n,'Cardiology','Internal Medicine','Emergency','Orthopedics','Neurology','Oncology','Pediatrics','Pulmonology',
  'Gastroenterology','Nephrology','Endocrinology','Dermatology','Psychiatry','Urology','OB/GYN','General Surgery','Infectious Disease',
  'Rheumatology','Hematology','Family Medicine'), CONCAT('SP',n) FROM nums WHERE n <= 20;
INSERT INTO departments SELECT n, CONCAT((SELECT specialty_name FROM specialties WHERE specialty_id=n),' Unit'), 1+n%6, 15+n*3 FROM nums WHERE n <= 20;
INSERT INTO providers SELECT n, CONCAT('ProvFirst',n), CONCAT('ProvLast',n), ELT(1+n%4,'MD','DO','NP','PA'),
  1+n%20, 1+n%20 FROM nums WHERE n <= 1000;
INSERT INTO patients SELECT n, CONCAT('First',n), CONCAT('Last',n),
  DATE_SUB('2024-01-01', INTERVAL FLOOR(RAND()*32000) DAY), ELT(1+FLOOR(RAND()*2),'M','F'), CONCAT('MRN',LPAD(n,8,'0'))
  FROM nums WHERE n <= 100000;
INSERT INTO diagnoses SELECT n, CONCAT(CHAR(65+n%26), LPAD(n%100,2,'0'), '.', n%10), CONCAT('Diagnosis ',n) FROM nums WHERE n <= 2000;
INSERT INTO procedures SELECT n, LPAD(10000+n*7,5,'0'), CONCAT('Procedure ',n) FROM nums WHERE n <= 1000;
COMMIT;

-- 1M encounters: 65% Outpatient, 20% ER, 15% Inpatient
-- Random values are generated ONCE into a helper table, then joined. (MySQL 8 merges
-- derived tables into the outer query, which re-evaluates RAND() per comparison and
-- would create duplicate encounters and inconsistent dates.)
CREATE TABLE rnd_enc AS
SELECT n,
       RAND()                          AS r_type,
       RAND()                          AS r_len,
       FLOOR(RAND() * 1095 * 24 * 60)  AS start_min,
       1 + FLOOR(RAND() * 1000)        AS provider_id,
       1 + FLOOR(RAND() * 100000)      AS patient_id
FROM nums WHERE n <= 1000000;
ALTER TABLE rnd_enc ADD PRIMARY KEY (n);
COMMIT;

INSERT INTO encounters
SELECT x.n, x.patient_id, p.provider_id,
       CASE WHEN x.r_type < 0.65 THEN 'Outpatient' WHEN x.r_type < 0.85 THEN 'ER' ELSE 'Inpatient' END,
       TIMESTAMP('2022-01-01') + INTERVAL x.start_min MINUTE,
       CASE WHEN x.r_type < 0.65 THEN TIMESTAMP('2022-01-01') + INTERVAL (x.start_min + 60 + FLOOR(x.r_len * 120)) MINUTE
            WHEN x.r_type < 0.85 THEN TIMESTAMP('2022-01-01') + INTERVAL (x.start_min + 60 * (2 + FLOOR(x.r_len * 10))) MINUTE
            ELSE                      TIMESTAMP('2022-01-01') + INTERVAL x.start_min MINUTE + INTERVAL (1 + FLOOR(x.r_len * 10)) DAY END,
       p.department_id
FROM rnd_enc x
JOIN providers p ON p.provider_id = x.provider_id;
COMMIT;

-- tiny real table 1..4 used to fan out child rows. (A subquery over nums gets merged
-- by MySQL 8 into a join against all 1,000,000 nums rows per encounter, which never finishes.)
CREATE TABLE seq4 (n INT PRIMARY KEY);
INSERT INTO seq4 VALUES (1),(2),(3),(4);

-- 1-4 diagnoses per encounter (skewed toward popular codes)
INSERT INTO encounter_diagnoses
SELECT ROW_NUMBER() OVER (), e.encounter_id, 1+FLOOR(POW(RAND(),3)*2000), s.n
FROM encounters e JOIN seq4 s ON s.n <= 1+(e.encounter_id*7)%4;
COMMIT;
-- 1-3 procedures per encounter
INSERT INTO encounter_procedures
SELECT ROW_NUMBER() OVER (), e.encounter_id, 1+FLOOR(POW(RAND(),3)*1000), DATE(e.encounter_date)
FROM encounters e JOIN seq4 s ON s.n <= 1+(e.encounter_id*11)%3;
COMMIT;
-- ~95% of encounters billed (allowed = 60-90% of claimed); random values stored first, as above
CREATE TABLE rnd_bill AS
SELECT e.encounter_id,
       ROUND(CASE e.encounter_type WHEN 'Inpatient' THEN 5000 + RAND() * 25000
                                   WHEN 'ER'        THEN 800  + RAND() * 4000
                                   ELSE                  100  + RAND() * 500 END, 2) AS claim,
       RAND()                                                AS r_allowed,
       RAND()                                                AS r_status,
       DATE(e.discharge_date) + INTERVAL FLOOR(RAND() * 20) DAY AS claim_date
FROM encounters e WHERE e.encounter_id % 20 <> 0;
COMMIT;

INSERT INTO billing
SELECT b.encounter_id, b.encounter_id, b.claim, ROUND(b.claim * (0.6 + b.r_allowed * 0.3), 2), b.claim_date,
       ELT(1 + FLOOR(b.r_status * 10), 'Paid','Paid','Paid','Paid','Paid','Paid','Paid','Pending','Denied','Pending')
FROM rnd_bill b;
COMMIT;
DROP TABLE nums, rnd_enc, rnd_bill, seq4;
SET foreign_key_checks=1, unique_checks=1;
ANALYZE TABLE patients, providers, encounters, encounter_diagnoses, encounter_procedures, billing;
