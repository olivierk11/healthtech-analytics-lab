-- Q2 Top diagnosis-procedure pairs - star schema, via bridge tables
-- Run with default schema: healthtech_dw
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
ORDER BY tp.encounter_count DESC;
