-- Deduplicate std_transactions: keep lowest id per unique (clinic_id, txn_id, service_code, amount, quantity, txn_date)
-- Delete all other copies

-- First count what we have and what we'd keep
DO $$
DECLARE
  total_count BIGINT;
  unique_count BIGINT;
  to_delete BIGINT;
BEGIN
  SELECT COUNT(*) INTO total_count FROM std_transactions WHERE clinic_id = 'rosslyn';
  RAISE NOTICE 'Total rows: %', total_count;
  
  SELECT COUNT(*) INTO unique_count FROM (
    SELECT DISTINCT clinic_id, txn_id, service_code, amount, quantity, txn_date
    FROM std_transactions WHERE clinic_id = 'rosslyn'
  ) sub;
  RAISE NOTICE 'Unique rows: %', unique_count;
  RAISE NOTICE 'Rows to delete: %', total_count - unique_count;
END $$;

-- Do the dedup
DELETE FROM std_transactions a
USING std_transactions b
WHERE a.id > b.id
  AND a.clinic_id = b.clinic_id
  AND a.txn_id = b.txn_id
  AND a.service_code = b.service_code
  AND a.amount = b.amount
  AND a.quantity = b.quantity
  AND a.txn_date = b.txn_date;

-- Check result
DO $$
DECLARE
  remaining BIGINT;
BEGIN
  SELECT COUNT(*) INTO remaining FROM std_transactions WHERE clinic_id = 'rosslyn';
  RAISE NOTICE 'Rows after dedup: %', remaining;
END $$;
