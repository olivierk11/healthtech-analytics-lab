-- test_scd2_and_incremental.sql
-- Run AFTER the full ETL. Changes two things in the source, runs an INCREMENTAL
-- load, shows the results, then puts the source back. Expected output is in the guide.

-- 1. SCD Type 2: provider 1 changes specialty (to specialty 5)
SELECT specialty_id INTO @old_spec FROM healthtech_oltp_big.providers WHERE provider_id = 1;
UPDATE healthtech_oltp_big.providers SET specialty_id = 5 WHERE provider_id = 1;

-- 2. Late-arriving fact: a claim arrives TODAY for old encounter 20 (never billed)
INSERT INTO healthtech_oltp_big.billing VALUES (9000020, 20, 900.00, 700.00, CURDATE(), 'Paid');
