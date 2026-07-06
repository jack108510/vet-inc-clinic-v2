-- Add price_source column
ALTER TABLE std_price_history ADD COLUMN IF NOT EXISTS price_source TEXT DEFAULT 'transaction_mode';

-- Update compute_service_prices to pull from std_price_history
CREATE OR REPLACE FUNCTION compute_service_prices(p_clinic_id TEXT)
RETURNS JSON
LANGUAGE plpgsql SECURITY DEFINER AS $_$
DECLARE
  result JSON;
BEGIN
  DELETE FROM std_service_prices WHERE clinic_id = p_clinic_id;

  -- Ensure price history exists
  PERFORM compute_price_history(p_clinic_id);

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
    -- Annual volume = transactions / years at this price
    ROUND(ph.transaction_count::numeric / 
      GREATEST(EXTRACT(YEAR FROM ph.last_seen) - EXTRACT(YEAR FROM ph.first_seen) + 1, 1), 1),
    -- Annual revenue = transactions * price / years
    ROUND(ph.transaction_count * ph.price / 
      GREATEST(EXTRACT(YEAR FROM ph.last_seen) - EXTRACT(YEAR FROM ph.first_seen) + 1, 1)),
    sv.category
  FROM std_price_history ph
  LEFT JOIN std_services sv ON sv.code = ph.service_code AND sv.clinic_id = p_clinic_id
  WHERE ph.clinic_id = p_clinic_id
    AND ph.is_current = true
    AND ph.price >= 1.0
    AND ph.transaction_count >= 3;

  SELECT json_build_object(
    'clinic_id', p_clinic_id, 'services', COUNT(*),
    'total_annual_revenue', COALESCE(ROUND(SUM(annual_revenue)), 0)
  ) INTO result FROM std_service_prices WHERE clinic_id = p_clinic_id;
  RETURN result;
END;
$_$;
