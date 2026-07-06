CREATE OR REPLACE FUNCTION compute_service_prices(p_clinic_id TEXT)
RETURNS JSON
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  result JSON;
  date_range RECORD;
  years_covered NUMERIC;
BEGIN
  DELETE FROM std_service_prices WHERE clinic_id = p_clinic_id;

  -- Get actual date range
  SELECT MIN(txn_date), MAX(txn_date) INTO date_range
  FROM std_transactions WHERE clinic_id = p_clinic_id;
  
  years_covered := GREATEST(
    EXTRACT(YEAR FROM date_range.max) - EXTRACT(YEAR FROM date_range.min) + 1, 
    1
  );

  WITH per_unit AS (
    SELECT 
      service_code,
      ROUND(amount / NULLIF(GREATEST(quantity, 1), 0), 2) as unit_price,
      txn_date
    FROM std_transactions
    WHERE clinic_id = p_clinic_id
      AND amount > 0
      AND quantity > 0
      AND service_code IS NOT NULL
      AND service_code NOT IN ('(N/A)', '')
      AND description NOT ILIKE '%refund%'
      AND description NOT ILIKE '%credit%'
      AND description NOT ILIKE '%discount%'
  ),
  price_counts AS (
    SELECT 
      service_code,
      unit_price,
      COUNT(*) as freq,
      MIN(txn_date) as first_seen,
      MAX(txn_date) as last_seen
    FROM per_unit
    GROUP BY service_code, unit_price
  ),
  mode_prices AS (
    SELECT DISTINCT ON (service_code)
      service_code,
      unit_price as current_price,
      first_seen as price_set_date,
      last_seen as last_charged_date,
      freq as total_transactions
    FROM price_counts
    ORDER BY service_code, freq DESC, unit_price DESC
  )
  INSERT INTO std_service_prices (
    clinic_id, service_code, service_name, 
    current_price, price_set_date, last_charged_date,
    total_transactions, annual_volume, annual_revenue, category
  )
  SELECT 
    p_clinic_id,
    mp.service_code,
    COALESCE(sv.name, mp.service_code),
    mp.current_price,
    mp.price_set_date,
    mp.last_charged_date,
    mp.total_transactions,
    -- Annual volume = total transactions / years of data
    ROUND(mp.total_transactions::numeric / years_covered, 1),
    -- Annual revenue = actual total spend (freq * price) / years
    ROUND(mp.total_transactions * mp.current_price / years_covered, 2),
    sv.category
  FROM mode_prices mp
  LEFT JOIN std_services sv ON sv.code = mp.service_code AND sv.clinic_id = p_clinic_id
  WHERE mp.current_price >= 1.0
    AND mp.total_transactions >= 3;

  SELECT json_build_object(
    'clinic_id', p_clinic_id,
    'services', COUNT(*),
    'total_annual_revenue', COALESCE(ROUND(SUM(annual_revenue)), 0)
  ) INTO result
  FROM std_service_prices
  WHERE clinic_id = p_clinic_id;

  RETURN result;
END;
$$;
