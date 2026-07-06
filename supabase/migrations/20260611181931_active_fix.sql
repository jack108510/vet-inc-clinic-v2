-- Fix: a service is "active" if it has ANY transaction in the last 12 months of data
-- Price periods can be old - what matters is the service is still being charged
CREATE OR REPLACE FUNCTION compute_service_prices(p_clinic_id TEXT)
RETURNS JSON
LANGUAGE plpgsql SECURITY DEFINER AS $_$
DECLARE
  result JSON;
  cutoff DATE;
BEGIN
  SELECT MAX(txn_date) - INTERVAL '12 months' INTO cutoff
  FROM std_transactions WHERE clinic_id = p_clinic_id;

  DELETE FROM std_service_prices WHERE clinic_id = p_clinic_id;
  PERFORM compute_price_history(p_clinic_id);

  -- is_current = latest period per service (regardless of cutoff)
  UPDATE std_price_history SET is_current = false WHERE clinic_id = p_clinic_id;
  UPDATE std_price_history SET is_current = true
  WHERE id IN (
    SELECT DISTINCT ON (service_code) id
    FROM std_price_history
    WHERE clinic_id = p_clinic_id
    ORDER BY service_code, first_seen DESC
  );

  -- Only include services with transactions in last 12 months of data
  INSERT INTO std_service_prices (
    clinic_id, service_code, service_name, 
    current_price, price_set_date, last_charged_date,
    total_transactions, annual_volume, annual_revenue, category
  )
  SELECT 
    p_clinic_id, ph.service_code, COALESCE(sv.name, ph.service_code),
    ph.price, ph.first_seen, ph.last_seen, ph.transaction_count,
    ROUND(ph.transaction_count::numeric / 
      GREATEST(EXTRACT(YEAR FROM ph.last_seen) - EXTRACT(YEAR FROM ph.first_seen) + 1, 1), 1),
    ROUND(ph.transaction_count * ph.price / 
      GREATEST(EXTRACT(YEAR FROM ph.last_seen) - EXTRACT(YEAR FROM ph.first_seen) + 1, 1)),
    sv.category
  FROM std_price_history ph
  LEFT JOIN std_services sv ON sv.code = ph.service_code AND sv.clinic_id = p_clinic_id
  WHERE ph.clinic_id = p_clinic_id AND ph.is_current = true
    AND ph.price >= 1.0 AND ph.transaction_count >= 3
    -- Active filter: service has transactions in last 12 months of data
    AND EXISTS (
      SELECT 1 FROM std_transactions t 
      WHERE t.clinic_id = p_clinic_id 
        AND t.service_code = ph.service_code 
        AND t.txn_date >= cutoff
        AND t.amount > 0
    );

  SELECT json_build_object(
    'clinic_id', p_clinic_id, 'services', COUNT(*),
    'total_annual_revenue', COALESCE(ROUND(SUM(annual_revenue)), 0)
  ) INTO result FROM std_service_prices WHERE clinic_id = p_clinic_id;
  RETURN result;
END;
$_$;
