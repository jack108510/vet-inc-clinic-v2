CREATE OR REPLACE FUNCTION generate_inflation_campaign(p_clinic_id TEXT)
RETURNS JSON
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  result JSON;
BEGIN
  DELETE FROM std_approval_queue 
  WHERE clinic_id = p_clinic_id AND strategy = 'inflation_catchup';

  -- Use std_service_prices (already standardized mode prices)
  INSERT INTO std_approval_queue (
    clinic_id, campaign_id, service_code, service_name, strategy,
    old_price, suggested_price, price_increase_pct,
    expected_monthly_uplift, expected_annual_uplift,
    volume_risk, status, priority
  )
  SELECT 
    p_clinic_id,
    'inflation-catchup-2026',
    sp.service_code,
    sp.service_name,
    'inflation_catchup',
    sp.current_price,
    ROUND(sp.current_price * POWER(1.03, 2026 - EXTRACT(YEAR FROM sp.price_set_date)::int), 2),
    ROUND((POWER(1.03, 2026 - EXTRACT(YEAR FROM sp.price_set_date)::int) - 1) * 100, 1),
    ROUND(sp.annual_volume * sp.current_price * (POWER(1.03, 2026 - EXTRACT(YEAR FROM sp.price_set_date)::int) - 1) / 12, 2),
    ROUND(sp.annual_volume * sp.current_price * (POWER(1.03, 2026 - EXTRACT(YEAR FROM sp.price_set_date)::int) - 1), 2),
    CASE 
      WHEN POWER(1.03, 2026 - EXTRACT(YEAR FROM sp.price_set_date)::int) - 1 > 0.15 THEN 'high'
      WHEN POWER(1.03, 2026 - EXTRACT(YEAR FROM sp.price_set_date)::int) - 1 > 0.08 THEN 'medium'
      ELSE 'low'
    END,
    'pending',
    CASE 
      WHEN POWER(1.03, 2026 - EXTRACT(YEAR FROM sp.price_set_date)::int) - 1 > 0.15 THEN 1
      WHEN POWER(1.03, 2026 - EXTRACT(YEAR FROM sp.price_set_date)::int) - 1 > 0.08 THEN 2
      ELSE 3
    END
  FROM std_service_prices sp
  WHERE sp.clinic_id = p_clinic_id
    AND 2026 - EXTRACT(YEAR FROM sp.price_set_date)::int >= 1
    AND sp.current_price >= 5.0
    AND sp.total_transactions >= 10
    AND sp.current_price * (POWER(1.03, 2026 - EXTRACT(YEAR FROM sp.price_set_date)::int) - 1) > 0.50
    AND sp.annual_volume * sp.current_price * (POWER(1.03, 2026 - EXTRACT(YEAR FROM sp.price_set_date)::int) - 1) > 5;

  SELECT json_build_object(
    'count', COUNT(*),
    'total_uplift', COALESCE(SUM(expected_annual_uplift), 0)
  ) INTO result
  FROM std_approval_queue
  WHERE clinic_id = p_clinic_id AND strategy = 'inflation_catchup';

  RETURN result;
END;
$$;
