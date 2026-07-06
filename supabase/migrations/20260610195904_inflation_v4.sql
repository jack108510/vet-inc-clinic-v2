CREATE OR REPLACE FUNCTION generate_inflation_campaign(p_clinic_id TEXT)
RETURNS JSON
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  result JSON;
BEGIN
  DELETE FROM std_approval_queue 
  WHERE clinic_id = p_clinic_id AND strategy = 'inflation_catchup';

  -- For each service: find the MODE per-unit price (most common price = real list price)
  -- and the first transaction date (= when service was first offered, proxy for when price was set)
  WITH per_unit_prices AS (
    SELECT 
      service_code,
      amount / NULLIF(GREATEST(quantity, 1), 0) as unit_price,
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
  price_modes AS (
    SELECT 
      service_code,
      ROUND(unit_price, 2) as rounded_price,
      COUNT(*) as freq,
      MIN(txn_date) as first_seen,
      MAX(txn_date) as last_seen
    FROM per_unit_prices
    GROUP BY service_code, ROUND(unit_price, 2)
  ),
  -- Pick the most common price per service
  current_prices AS (
    SELECT DISTINCT ON (service_code)
      service_code,
      rounded_price as current_price,
      first_seen,
      last_seen,
      freq as total_transactions,
      -- Also get total annual volume
      freq::numeric / GREATEST(EXTRACT(YEAR FROM MAX(last_seen) OVER (PARTITION BY service_code)) - EXTRACT(YEAR FROM MIN(first_seen) OVER (PARTITION BY service_code)) + 1, 1) as annual_volume
    FROM price_modes
    ORDER BY service_code, freq DESC, rounded_price DESC
  )
  INSERT INTO std_approval_queue (
    clinic_id, campaign_id, service_code, service_name, strategy,
    old_price, suggested_price, price_increase_pct,
    expected_monthly_uplift, expected_annual_uplift,
    volume_risk, status, priority
  )
  SELECT 
    p_clinic_id,
    'inflation-catchup-2026',
    cp.service_code,
    COALESCE(sv.name, cp.service_code),
    'inflation_catchup',
    cp.current_price,
    ROUND(cp.current_price * POWER(1.03, 2026 - EXTRACT(YEAR FROM cp.first_seen)::int), 2),
    ROUND((POWER(1.03, 2026 - EXTRACT(YEAR FROM cp.first_seen)::int) - 1) * 100, 1),
    ROUND(cp.annual_volume * cp.current_price * (POWER(1.03, 2026 - EXTRACT(YEAR FROM cp.first_seen)::int) - 1) / 12, 2),
    ROUND(cp.annual_volume * cp.current_price * (POWER(1.03, 2026 - EXTRACT(YEAR FROM cp.first_seen)::int) - 1), 2),
    CASE 
      WHEN POWER(1.03, 2026 - EXTRACT(YEAR FROM cp.first_seen)::int) - 1 > 0.15 THEN 'high'
      WHEN POWER(1.03, 2026 - EXTRACT(YEAR FROM cp.first_seen)::int) - 1 > 0.08 THEN 'medium'
      ELSE 'low'
    END,
    'pending',
    CASE 
      WHEN POWER(1.03, 2026 - EXTRACT(YEAR FROM cp.first_seen)::int) - 1 > 0.15 THEN 1
      WHEN POWER(1.03, 2026 - EXTRACT(YEAR FROM cp.first_seen)::int) - 1 > 0.08 THEN 2
      ELSE 3
    END
  FROM current_prices cp
  LEFT JOIN std_services sv ON sv.code = cp.service_code AND sv.clinic_id = p_clinic_id
  WHERE 2026 - EXTRACT(YEAR FROM cp.first_seen)::int >= 1
    AND cp.current_price >= 5.0
    AND cp.total_transactions >= 10
    AND cp.current_price * (POWER(1.03, 2026 - EXTRACT(YEAR FROM cp.first_seen)::int) - 1) > 1.0
    AND cp.annual_volume * cp.current_price * (POWER(1.03, 2026 - EXTRACT(YEAR FROM cp.first_seen)::int) - 1) > 10;

  SELECT json_build_object(
    'count', COUNT(*),
    'total_uplift', COALESCE(SUM(expected_annual_uplift), 0)
  ) INTO result
  FROM std_approval_queue
  WHERE clinic_id = p_clinic_id AND strategy = 'inflation_catchup';

  RETURN result;
END;
$$;
