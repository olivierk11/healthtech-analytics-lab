-- test_check.sql : look at the results of the SCD2 + late-arriving-fact test
SELECT provider_key, provider_id, specialty_name, effective_from, effective_to, is_current
FROM healthtech_dw.dim_provider WHERE provider_id = 1 ORDER BY provider_key;

SELECT encounter_id, claim_count, total_allowed_amount, etl_updated_at
FROM healthtech_dw.fact_encounters WHERE encounter_id = 20;

SELECT COUNT(*) AS fact_rows_should_still_be_1000000 FROM healthtech_dw.fact_encounters;

-- encounters of provider 1 that happened BEFORE the change keep the OLD specialty
SELECT s.specialty_name, COUNT(*) AS encounters
FROM healthtech_dw.fact_encounters f
JOIN healthtech_dw.dim_provider p  ON p.provider_key = f.provider_key
JOIN healthtech_dw.dim_specialty s ON s.specialty_key = f.specialty_key
WHERE p.provider_id = 1 GROUP BY s.specialty_name;
