-- readmission_logic_test.sql
-- The lab's sample data has no readmission, so Q3 always shows 0% on it.
-- This adds a return admission inside a transaction, runs Q3, then rolls back.
-- Expected:  Cardiology | 2 | 1 | 50.00
--   (stay 7002, discharged 2024-06-06, is readmitted on 2024-06-20 = 14 days later)
USE healthtech_oltp;
START TRANSACTION;
INSERT INTO encounters VALUES (7005, 1001, 101, 'Inpatient', '2024-06-20 08:00:00', '2024-06-22 10:00:00', 1);

SELECT s.specialty_name,
       COUNT(DISTINCT idx.encounter_id) AS inpatient_discharges,
       COUNT(DISTINCT CASE WHEN r.encounter_id IS NOT NULL THEN idx.encounter_id END) AS readmissions_30d,
       ROUND(100.0 * COUNT(DISTINCT CASE WHEN r.encounter_id IS NOT NULL THEN idx.encounter_id END)
                   / COUNT(DISTINCT idx.encounter_id), 2) AS readmission_rate_pct
FROM encounters idx
JOIN providers   p ON idx.provider_id = p.provider_id
JOIN specialties s ON p.specialty_id  = s.specialty_id
LEFT JOIN encounters r
       ON  r.patient_id      = idx.patient_id
       AND r.encounter_type  = 'Inpatient'
       AND r.encounter_id   <> idx.encounter_id
       AND r.encounter_date  > idx.discharge_date
       AND r.encounter_date <= idx.discharge_date + INTERVAL 30 DAY
WHERE idx.encounter_type = 'Inpatient'
  AND idx.discharge_date IS NOT NULL
GROUP BY s.specialty_name;

ROLLBACK;   -- sample data is unchanged afterwards
