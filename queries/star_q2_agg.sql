-- Q2 Top diagnosis-procedure pairs - star schema, via pre-aggregated table
-- Run with default schema: healthtech_dw
SELECT dx.icd10_code, dx.icd10_description, px.cpt_code, px.cpt_description, top.encounter_count
FROM (
    SELECT diagnosis_key, procedure_key, encounter_count
    FROM agg_diagnosis_procedure_pairs
    ORDER BY encounter_count DESC
    LIMIT 10                                   -- reads 10 entries from idx_agg_pair_count
) top
JOIN dim_diagnosis dx ON dx.diagnosis_key = top.diagnosis_key
JOIN dim_procedure px ON px.procedure_key = top.procedure_key
ORDER BY top.encounter_count DESC;
