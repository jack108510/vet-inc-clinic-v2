-- ============================================================
-- DATA CLEANUP: Remove Feb 2019 import artifact
-- 191,753 transactions in one month = years of backdated data
-- Normal months have ~1,500-2,100 transactions
-- ============================================================

-- Count before
SELECT 'before' as status, COUNT(*) as total FROM std_transactions WHERE clinic_id = 'rosslyn' AND txn_date >= '2019-02-01' AND txn_date < '2019-03-01';

-- Delete the import dump
DELETE FROM std_transactions 
WHERE clinic_id = 'rosslyn' 
  AND txn_date >= '2019-02-01' 
  AND txn_date < '2019-03-01';

-- Count after
SELECT 'after' as status, COUNT(*) as total FROM std_transactions WHERE clinic_id = 'rosslyn';

-- Recompute price history (this changes the detected first_seen dates)
SELECT 'recomputing price history...' as status;

-- Recompute elasticity with clean data
SELECT 'recomputing elasticity...' as status;
