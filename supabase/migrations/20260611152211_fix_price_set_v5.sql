-- Fix: price_set_date = when the CURRENT mode price became the majority
-- by checking per-year modes and finding the transition point
CREATE OR REPLACE FUNCTION compute_service_prices(p_clinic_id TEXT)
RETURNS JSON
LANGUAGE plpgsql SECURITY DEFINER AS $_$
DECLARE
  result JSON;
BEGIN
  DELETE FROM std_service_prices WHERE clinic_id = p_clinic_id;

  WITH per_unit AS (
    SELECT 
      service_code,
      ROUND(amount / NULLIF(GREATEST(quantity, 1), 0), 2) as unit_price,
      txn_date
    FROM std_transactions
    WHERE clinic_id = p_clinic_id
      AND amount > 0 AND quantity > 0
      AND service_code IS NOT NULL AND service_code NOT IN ('(N/A)', '')
      AND description NOT ILIKE '%refund%'
      AND description NOT ILIKE '%credit%'
      AND description NOT ILIKE '%discount%'
  ),
  -- Overall mode price
  overall_mode AS (
    SELECT DISTINCT ON (service_code) service_code, unit_price as current_price, COUNT(*) as total_transactions
    FROM (SELECT service_code, unit_price, COUNT(*) as freq FROM per_unit GROUP BY service_code, unit_price) sub
    GROUP BY service_code, unit_price, freq
    ORDER BY service_code, freq DESC, unit_price DESC
  ),
  -- Find when the current mode price became the yearly mode
  yearly_modes AS (
    SELECT 
      service_code,
      EXTRACT(YEAR FROM txn_date)::int as yr,
      unit_price,
      COUNT(*) as freq
    FROM per_unit
    GROUP BY service_code, EXTRACT(YEAR FROM txn_date), unit_price
  ),
  yearly_mode_price AS (
    SELECT DISTINCT ON (service_code, yr)
      service_code, yr, unit_price as mode_price
    FROM yearly_modes
    ORDER BY service_code, yr, freq DESC, unit_price DESC
  ),
  -- Find the first year where the mode matches the overall current mode
  price_transition AS (
    SELECT DISTINCT ON (ym.service_code)
      ym.service_code,
      ym.yr as price_set_year
    FROM yearly_mode_price ym
    JOIN overall_mode om ON om.service_code = ym.service_code AND ym.mode_price = om.current_price
    ORDER BY ym.service_code, ym.yr ASC
  ),
  -- Stats at current price only
  current_price_stats AS (
    SELECT 
      om.service_code,
      COUNT(*) as current_price_txns,
      SUM(pu.unit_price) as current_price_revenue,
      MIN(pu.txn_date) as first_at_price,
      MAX(pu.txn_date) as last_at_price
    FROM overall_mode om
    JOIN per_unit pu ON pu.service_code = om.service_code AND pu.unit_price = om.current_price
    GROUP BY om.service_code
  )
  INSERT INTO std_service_prices (
    clinic_id, service_code, service_name, 
    current_price, price_set_date, last_charged_date,
    total_transactions, annual_volume, annual_revenue, category
  )
  SELECT 
    p_clinic_id,
    om.service_code,
    COALESCE(sv.name, om.service_code),
    om.current_price,
    -- Use the transition year, January 1st
    MAKE_DATE(pt.price_set_year, 1, 1),
    cs.last_at_price,
    om.total_transactions,
    ROUND(cs.current_price_txns::numeric / 
      GREATEST(EXTRACT(YEAR FROM cs.last_at_price) - EXTRACT(YEAR FROM cs.first_at_price) + 1, 1), 1),
    ROUND(cs.current_price_revenue / 
      GREATEST(EXTRACT(YEAR FROM cs.last_at_price) - EXTRACT(YEAR FROM cs.first_at_price) + 1, 1)),
    sv.category
  FROM overall_mode om
  JOIN current_price_stats cs ON cs.service_code = om.service_code
  JOIN price_transition pt ON pt.service_code = om.service_code
  LEFT JOIN std_services sv ON sv.code = om.service_code AND sv.clinic_id = p_clinic_id
  WHERE om.current_price >= 1.0 AND om.total_transactions >= 3;

  SELECT json_build_object(
    'clinic_id', p_clinic_id,
    'services', COUNT(*),
    'total_annual_revenue', COALESCE(ROUND(SUM(annual_revenue)), 0)
  ) INTO result
  FROM std_service_prices WHERE clinic_id = p_clinic_id;

  RETURN result;
END;
$_$;
