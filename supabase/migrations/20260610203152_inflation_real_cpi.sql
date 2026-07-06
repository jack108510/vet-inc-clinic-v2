CREATE OR REPLACE FUNCTION generate_inflation_campaign(p_clinic_id TEXT)
RETURNS JSON
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  result JSON;
BEGIN
  DELETE FROM std_approval_queue 
  WHERE clinic_id = p_clinic_id AND strategy = 'inflation_catchup';

  -- Use actual Statistics Canada CPI rates compounded year by year
  WITH cpi AS (
    SELECT yr, rate FROM (VALUES
      (2005, 0.022), (2006, 0.020), (2007, 0.021),
      (2008, 0.024), (2009,-0.003), (2010, 0.018),
      (2011, 0.029), (2012, 0.015), (2013, 0.009),
      (2014, 0.020), (2015, 0.011), (2016, 0.014),
      (2017, 0.016), (2018, 0.022), (2019, 0.019),
      (2020, 0.007), (2021, 0.034), (2022, 0.068),
      (2023, 0.039), (2024, 0.024), (2025, 0.021)
    ) AS t(yr, rate)
  ),
  -- Compound inflation factor for each starting year to 2026
  inflation_factors AS (
    SELECT 
      from_yr,
      EXP(SUM(LN(1 + rate))) as factor
    FROM 
      (SELECT generate_series(2005, 2025) as from_yr) years
    CROSS JOIN cpi
    WHERE cpi.yr >= from_yr AND cpi.yr <= 2025
    GROUP BY from_yr
  ),
  -- Map each service to its inflation factor based on price_set_date year
  service_inflation AS (
    SELECT 
      sp.*,
      COALESCE(iv.factor, POWER(1.03, 2026 - EXTRACT(YEAR FROM sp.price_set_date)::int)) as inflation_factor
    FROM std_service_prices sp
    LEFT JOIN inflation_factors iv ON iv.from_yr = EXTRACT(YEAR FROM sp.price_set_date)::int
    WHERE sp.clinic_id = p_clinic_id
      AND 2026 - EXTRACT(YEAR FROM sp.price_set_date)::int >= 1
      AND sp.current_price >= 5.0
      AND sp.total_transactions >= 10
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
    si.service_code,
    si.service_name,
    'inflation_catchup',
    si.current_price,
    ROUND(si.current_price * si.inflation_factor, 2),
    ROUND((si.inflation_factor - 1) * 100, 1),
    ROUND(si.annual_volume * si.current_price * (si.inflation_factor - 1) / 12, 2),
    ROUND(si.annual_volume * si.current_price * (si.inflation_factor - 1), 2),
    CASE 
      WHEN si.inflation_factor - 1 > 0.15 THEN 'high'
      WHEN si.inflation_factor - 1 > 0.08 THEN 'medium'
      ELSE 'low'
    END,
    'pending',
    CASE 
      WHEN si.inflation_factor - 1 > 0.15 THEN 1
      WHEN si.inflation_factor - 1 > 0.08 THEN 2
      ELSE 3
    END
  FROM service_inflation si
  WHERE si.current_price * (si.inflation_factor - 1) > 0.50
    AND si.annual_volume * si.current_price * (si.inflation_factor - 1) > 5;

  SELECT json_build_object(
    'count', COUNT(*),
    'total_uplift', COALESCE(SUM(expected_annual_uplift), 0)
  ) INTO result
  FROM std_approval_queue
  WHERE clinic_id = p_clinic_id AND strategy = 'inflation_catchup';

  RETURN result;
END;
$$;
