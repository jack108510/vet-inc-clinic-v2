-- Fix annual_volume/annual_revenue: count ALL transactions at current price
-- not just the ones in the latest price_history period
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

  UPDATE std_price_history SET is_current = false WHERE clinic_id = p_clinic_id;
  UPDATE std_price_history SET is_current = true
  WHERE id IN (
    SELECT DISTINCT ON (service_code) id
    FROM std_price_history WHERE clinic_id = p_clinic_id
    ORDER BY service_code, first_seen DESC
  );

  -- Count ALL transactions at the current price across ALL periods
  WITH current_prices AS (
    SELECT service_code, price FROM std_price_history 
    WHERE clinic_id = p_clinic_id AND is_current = true
  ),
  all_at_price AS (
    SELECT 
      cp.service_code,
      COUNT(*) as total_at_price,
      SUM(cp.price) as total_revenue_at_price,
      MIN(t.txn_date) as first_at_price,
      MAX(t.txn_date) as last_at_price
    FROM current_prices cp
    JOIN std_transactions t ON t.clinic_id = p_clinic_id 
      AND t.service_code = cp.service_code
      AND ROUND(t.amount / NULLIF(GREATEST(t.quantity, 1), 0), 2) = cp.price
      AND t.amount > 0 AND t.quantity > 0
      AND t.description NOT ILIKE '%refund%'
      AND t.description NOT ILIKE '%credit%'
      AND t.description NOT ILIKE '%discount%'
    GROUP BY cp.service_code
  )
  INSERT INTO std_service_prices (
    clinic_id, service_code, service_name, 
    current_price, price_set_date, last_charged_date,
    total_transactions, annual_volume, annual_revenue, category
  )
  SELECT 
    p_clinic_id,
    ap.service_code,
    COALESCE(sv.name, ap.service_code),
    ph.price,
    ph.first_seen,
    ap.last_at_price,
    ap.total_at_price,
    ROUND(ap.total_at_price::numeric / 
      GREATEST(EXTRACT(YEAR FROM ap.last_at_price) - EXTRACT(YEAR FROM ap.first_at_price) + 1, 1), 1),
    ROUND(ap.total_revenue_at_price / 
      GREATEST(EXTRACT(YEAR FROM ap.last_at_price) - EXTRACT(YEAR FROM ap.first_at_price) + 1, 1)),
    sv.category
  FROM all_at_price ap
  JOIN std_price_history ph ON ph.service_code = ap.service_code 
    AND ph.clinic_id = p_clinic_id AND ph.is_current = true
  LEFT JOIN std_services sv ON sv.code = ap.service_code AND sv.clinic_id = p_clinic_id
  WHERE ph.price >= 1.0 AND ap.total_at_price >= 3
    AND EXISTS (
      SELECT 1 FROM std_transactions t 
      WHERE t.clinic_id = p_clinic_id AND t.service_code = ap.service_code 
        AND t.txn_date >= cutoff AND t.amount > 0
    );

  SELECT json_build_object(
    'clinic_id', p_clinic_id, 'services', COUNT(*),
    'total_annual_revenue', COALESCE(ROUND(SUM(annual_revenue)), 0)
  ) INTO result FROM std_service_prices WHERE clinic_id = p_clinic_id;
  RETURN result;
END;
$_$;
