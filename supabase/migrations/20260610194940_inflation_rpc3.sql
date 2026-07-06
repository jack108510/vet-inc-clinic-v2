CREATE OR REPLACE FUNCTION generate_inflation_campaign(p_clinic_id TEXT)
RETURNS JSON
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  result JSON;
BEGIN
  DELETE FROM std_approval_queue 
  WHERE clinic_id = p_clinic_id AND strategy = 'inflation_catchup';

  WITH service_stats AS (
    SELECT 
      service_code,
      AVG(amount) as current_price,
      MIN(txn_date) as first_seen,
      COUNT(*)::numeric / GREATEST(EXTRACT(YEAR FROM MAX(txn_date)) - EXTRACT(YEAR FROM MIN(txn_date)) + 1, 1) as annual_volume
    FROM std_transactions
    WHERE clinic_id = p_clinic_id
      AND amount > 0
      AND service_code IS NOT NULL
      AND service_code NOT IN ('(N/A)', '')
    GROUP BY service_code
    HAVING COUNT(*) >= 10
  ),
  inflation_calc AS (
    SELECT 
      s.service_code,
      s.current_price,
      s.first_seen,
      s.annual_volume,
      s.current_price * POWER(1.03, 2026 - EXTRACT(YEAR FROM s.first_seen)::int) as suggested_price,
      (s.current_price * POWER(1.03, 2026 - EXTRACT(YEAR FROM s.first_seen)::int) - s.current_price) / NULLIF(s.current_price, 0) as gap_pct
    FROM service_stats s
    WHERE s.current_price > 0
      AND 2026 - EXTRACT(YEAR FROM s.first_seen)::int >= 1
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
    i.service_code,
    COALESCE(sv.name, i.service_code),
    'inflation_catchup',
    ROUND(i.current_price, 2),
    ROUND(i.suggested_price, 2),
    ROUND(i.gap_pct * 100, 1),
    ROUND(i.annual_volume * (i.suggested_price - i.current_price) / 12, 2),
    ROUND(i.annual_volume * (i.suggested_price - i.current_price), 2),
    CASE 
      WHEN i.gap_pct > 0.15 THEN 'high'
      WHEN i.gap_pct > 0.08 THEN 'medium'
      ELSE 'low'
    END,
    'pending',
    CASE 
      WHEN i.gap_pct > 0.15 THEN 1
      WHEN i.gap_pct > 0.08 THEN 2
      ELSE 3
    END
  FROM inflation_calc i
  LEFT JOIN std_services sv ON sv.code = i.service_code AND sv.clinic_id = p_clinic_id
  WHERE i.suggested_price - i.current_price > 1.0
    AND i.annual_volume * (i.suggested_price - i.current_price) > 10;

  SELECT json_build_object(
    'count', COUNT(*),
    'total_uplift', COALESCE(SUM(expected_annual_uplift), 0)
  ) INTO result
  FROM std_approval_queue
  WHERE clinic_id = p_clinic_id AND strategy = 'inflation_catchup';

  RETURN result;
END;
$$;
