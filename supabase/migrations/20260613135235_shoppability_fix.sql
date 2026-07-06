-- Fix: use txn_id (visit/transaction grouping) not ref_id
CREATE OR REPLACE FUNCTION compute_shoppability(p_clinic_id TEXT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $_$
DECLARE
  computed INT;
BEGIN
  DELETE FROM std_shoppability WHERE clinic_id = p_clinic_id;

  INSERT INTO std_shoppability (
    clinic_id, service_code, service_name,
    total_visits, standalone_visits, shoppability_score, visibility_label, avg_invoice_size
  )
  WITH invoice_sizes AS (
    SELECT txn_id, COUNT(*) AS services_on_invoice
    FROM std_transactions
    WHERE clinic_id = p_clinic_id AND amount > 0
    GROUP BY txn_id
  ),
  service_invoices AS (
    SELECT 
      t.service_code,
      sp.service_name,
      t.txn_id,
      isz.services_on_invoice
    FROM std_transactions t
    LEFT JOIN std_service_prices sp ON sp.clinic_id = t.clinic_id AND sp.service_code = t.service_code
    JOIN invoice_sizes isz ON isz.txn_id = t.txn_id
    WHERE t.clinic_id = p_clinic_id AND t.amount > 0
  ),
  classified AS (
    SELECT 
      service_code,
      MAX(service_name) AS service_name,
      COUNT(DISTINCT txn_id) AS total_visits,
      COUNT(DISTINCT CASE WHEN services_on_invoice <= 2 THEN txn_id END) AS standalone_visits,
      AVG(services_on_invoice::numeric) AS avg_invoice_size
    FROM service_invoices
    GROUP BY service_code
  )
  SELECT 
    p_clinic_id, service_code, service_name, total_visits, standalone_visits,
    CASE WHEN total_visits > 0 THEN ROUND(standalone_visits::numeric / total_visits, 3) ELSE 0 END,
    CASE 
      WHEN total_visits = 0 THEN 'unknown'
      WHEN standalone_visits::numeric / total_visits >= 0.5 THEN 'shoppable'
      WHEN standalone_visits::numeric / total_visits >= 0.25 THEN 'moderate'
      ELSE 'blind'
    END,
    ROUND(avg_invoice_size, 1)
  FROM classified
  WHERE total_visits >= 5;

  GET DIAGNOSTICS computed = ROW_COUNT;

  RETURN jsonb_build_object(
    'clinic_id', p_clinic_id,
    'services_classified', computed,
    'shoppable', (SELECT COUNT(*) FROM std_shoppability WHERE clinic_id = p_clinic_id AND visibility_label = 'shoppable'),
    'moderate', (SELECT COUNT(*) FROM std_shoppability WHERE clinic_id = p_clinic_id AND visibility_label = 'moderate'),
    'blind', (SELECT COUNT(*) FROM std_shoppability WHERE clinic_id = p_clinic_id AND visibility_label = 'blind')
  );
END;
$_$;
