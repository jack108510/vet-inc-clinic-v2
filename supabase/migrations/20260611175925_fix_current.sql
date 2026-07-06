-- Fix: only ONE current price per service (the latest period)
CREATE OR REPLACE FUNCTION compute_service_prices(p_clinic_id TEXT)
RETURNS JSON
LANGUAGE plpgsql SECURITY DEFINER AS $_$
DECLARE
  result JSON;
BEGIN
  DELETE FROM std_service_prices WHERE clinic_id = p_clinic_id;

  -- Ensure price history is computed
  PERFORM compute_price_history(p_clinic_id);

  -- Fix is_current: only the latest period per service is current
  UPDATE std_price_history SET is_current = false WHERE clinic_id = p_clinic_id;
  UPDATE std_price_history SET is_current = true
  WHERE id IN (
    SELECT DISTINCT ON (service_code) id
    FROM std_price_history
    WHERE clinic_id = p_clinic_id
    ORDER BY service_code, first_seen DESC
  );

  INSERT INTO std_service_prices (
    clinic_id, service_code, service_name, 
    current_price, price_set_date, last_charged_date,
    total_transactions, annual_volume, annual_revenue, category
  )
  SELECT 
    p_clinic_id,
    ph.service_code,
    COALESCE(sv.name, ph.service_code),
    ph.price,
    ph.first_seen,
    ph.last_seen,
    ph.transaction_count,
    ROUND(ph.transaction_count::numeric / 
      GREATEST(EXTRACT(YEAR FROM ph.last_seen) - EXTRACT(YEAR FROM ph.first_seen) + 1, 1), 1),
    ROUND(ph.transaction_count * ph.price / 
      GREATEST(EXTRACT(YEAR FROM ph.last_seen) - EXTRACT(YEAR FROM ph.first_seen) + 1, 1)),
    sv.category
  FROM std_price_history ph
  LEFT JOIN std_services sv ON sv.code = ph.service_code AND sv.clinic_id = p_clinic_id
  WHERE ph.clinic_id = p_clinic_id AND ph.is_current = true
    AND ph.price >= 1.0 AND ph.transaction_count >= 3;

  SELECT json_build_object(
    'clinic_id', p_clinic_id, 'services', COUNT(*),
    'total_annual_revenue', COALESCE(ROUND(SUM(annual_revenue)), 0)
  ) INTO result FROM std_service_prices WHERE clinic_id = p_clinic_id;
  RETURN result;
END;
$_$;
