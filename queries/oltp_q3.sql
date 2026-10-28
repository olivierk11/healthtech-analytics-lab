-- Q3 30-day readmission rate by specialty - normalized OLTP version
-- Run with default schema: healthtech_oltp_big (or healthtech_oltp for the small sample)
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
ORDER BY readmission_rate_pct DESC;
