-- Q2 Top diagnosis-procedure pairs - normalized OLTP version
-- Run with default schema: healthtech_oltp_big (or healthtech_oltp for the small sample)
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
LIMIT 10;
