-- verify_warehouse.sql : reconcile healthtech_dw against its source.
-- Every row should show status = PASS.
-- If your source database has a different name, replace healthtech_oltp_big below.
SELECT check_name, source_value, warehouse_value,
       CASE WHEN source_value = warehouse_value THEN 'PASS' ELSE 'FAIL' END AS status
FROM (
  SELECT 'encounters -> fact rows' AS check_name,
         (SELECT COUNT(*) FROM healthtech_oltp_big.encounters) AS source_value,
         (SELECT COUNT(*) FROM healthtech_dw.fact_encounters)  AS warehouse_value
  UNION ALL SELECT 'allowed amount total',
         (SELECT SUM(allowed_amount) FROM healthtech_oltp_big.billing),
         (SELECT SUM(total_allowed_amount) FROM healthtech_dw.fact_encounters)
  UNION ALL SELECT 'claim amount total',
         (SELECT SUM(claim_amount) FROM healthtech_oltp_big.billing),
         (SELECT SUM(total_claim_amount) FROM healthtech_dw.fact_encounters)
  UNION ALL SELECT 'billing rows -> claim_count',
         (SELECT COUNT(*) FROM healthtech_oltp_big.billing),
         (SELECT SUM(claim_count) FROM healthtech_dw.fact_encounters)
  UNION ALL SELECT 'diagnosis links -> bridge rows',
         (SELECT COUNT(*) FROM healthtech_oltp_big.encounter_diagnoses),
         (SELECT COUNT(*) FROM healthtech_dw.bridge_encounter_diagnoses)
  UNION ALL SELECT 'procedure links -> bridge rows',
         (SELECT COUNT(*) FROM healthtech_oltp_big.encounter_procedures),
         (SELECT COUNT(*) FROM healthtech_dw.bridge_encounter_procedures)
  UNION ALL SELECT 'diagnosis_count total = bridge rows',
         (SELECT COUNT(*) FROM healthtech_dw.bridge_encounter_diagnoses),
         (SELECT SUM(diagnosis_count) FROM healthtech_dw.fact_encounters)
  UNION ALL SELECT 'current patients = source patients',
         (SELECT COUNT(*) FROM healthtech_oltp_big.patients),
         (SELECT COUNT(*) FROM healthtech_dw.dim_patient WHERE is_current = 1 AND patient_key <> 0)
  UNION ALL SELECT 'fact rows with an Unknown (0) key',
         0,
         (SELECT COUNT(*) FROM healthtech_dw.fact_encounters
          WHERE encounter_date_key = 0 OR patient_key = 0 OR provider_key = 0
             OR specialty_key = 0 OR encounter_type_key = 0)
  UNION ALL SELECT 'dim_date covers 2015-2030',
         5844,
         (SELECT COUNT(*) FROM healthtech_dw.dim_date WHERE date_key <> 0)
  UNION ALL SELECT 'duplicate encounter_ids in fact',
         0,
         (SELECT COUNT(*) - COUNT(DISTINCT encounter_id) FROM healthtech_dw.fact_encounters)
) checks;
