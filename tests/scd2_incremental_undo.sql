-- test_undo.sql : put the source back the way it was, then rerun a FULL load
UPDATE healthtech_oltp_big.providers SET specialty_id = 2 WHERE provider_id = 1;
DELETE FROM healthtech_oltp_big.billing WHERE billing_id = 9000020;
