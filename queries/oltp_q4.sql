-- Q4 Revenue (allowed amount) by specialty and month - normalized OLTP version
-- Run with default schema: healthtech_oltp_big (or healthtech_oltp for the small sample)
SELECT DATE_FORMAT(e.encounter_date, '%Y-%m') AS service_month,
       s.specialty_name,
       SUM(b.allowed_amount) AS total_allowed,
       SUM(b.claim_amount)   AS total_claimed,
       COUNT(DISTINCT e.encounter_id) AS billed_encounters
FROM billing b
JOIN encounters  e ON b.encounter_id = e.encounter_id
JOIN providers   p ON e.provider_id  = p.provider_id
JOIN specialties s ON p.specialty_id = s.specialty_id
GROUP BY DATE_FORMAT(e.encounter_date, '%Y-%m'), s.specialty_name
ORDER BY service_month, total_allowed DESC;
