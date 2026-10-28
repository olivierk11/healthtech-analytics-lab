-- Q1 Monthly encounters by specialty - normalized OLTP version
-- Run with default schema: healthtech_oltp_big (or healthtech_oltp for the small sample)
SELECT DATE_FORMAT(e.encounter_date, '%Y-%m') AS encounter_month,
       s.specialty_name,
       e.encounter_type,
       COUNT(*)                     AS total_encounters,
       COUNT(DISTINCT e.patient_id) AS unique_patients
FROM encounters e
JOIN providers   p ON e.provider_id  = p.provider_id
JOIN specialties s ON p.specialty_id = s.specialty_id
GROUP BY DATE_FORMAT(e.encounter_date, '%Y-%m'), s.specialty_name, e.encounter_type
ORDER BY encounter_month, s.specialty_name, e.encounter_type;
