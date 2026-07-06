-- price_set_date = first transaction AFTER the last non-current-price transaction
-- If no prior different price exists, use the first transaction ever
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
  price_counts AS (
    SELECT service_code, unit_price, COUNT(*) as freq
    FROM per_unit GROUP BY service_code, unit_price
  ),
  mode_prices AS (
    SELECT DISTINCT ON (service_code) service_code, unit_price as current_price, freq as total_transactions
    FROM price_counts ORDER BY service_code, freq DESC, unit_price DESC
  ),
  -- Last transaction NOT at current price (per service)
  last_different_price AS (
    SELECT 
      pu.service_code,
      MAX(pu.txn_date) as last_old_price_date
    FROM per_unit pu
    JOIN mode_prices mp ON mp.service_code = pu.service_code
    WHERE pu.unit_price != mp.current_price
    GROUP BY pu.service_code
  ),
  -- Stats at current price
  current_price_stats AS (
    SELECT 
      mp.service_code,
      COUNT(*) as current_price_txns,
      SUM(pu.unit_price) as current_price_revenue,
      MIN(pu.txn_date) as first_at_price,
      MAX(pu.txn_date) as last_at_price
    FROM mode_prices mp
    JOIN per_unit pu ON pu.service_code = mp.service_code AND pu.unit_price = mp.current_price
    GROUP BY mp.service_code
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
    -- price_set_date = day after the last different price, or first_at_price if never changed
    COALESCE(ld.last_old_price_date + 1, cs.first_at_price),
    cs.last_at_price,
    mp.total_transactions,
    ROUND(cs.current_price_txns::numeric / 
      GREATEST(EXTRACT(YEAR FROM cs.last_at_price) - EXTRACT(YEAR FROM cs.first_at_price) + 1, 1), 1),
    ROUND(cs.current_price_revenue / 
      GREATEST(EXTRACT(YEAR FROM cs.last_at_price) - EXTRACT(YEAR FROM cs.first_at_price) + 1, 1)),
    sv.category
  FROM mode_prices mp
  JOIN current_price_stats cs ON cs.service_code = mp.service_code
  LEFT JOIN last_different_price ld ON ld.service_code = mp.service_code
  LEFT JOIN std_services sv ON sv.code = mp.service_code AND sv.clinic_id = p_clinic_id
  WHERE mp.current_price >= 1.0 AND mp.total_transactions >= 3;

  SELECT json_build_object(
    'clinic_id', p_clinic_id, 'services', COUNT(*),
    'total_annual_revenue', COALESCE(ROUND(SUM(annual_revenue)), 0)
  ) INTO result FROM std_service_prices WHERE clinic_id = p_clinic_id;
  RETURN result;
END;
$_$;
