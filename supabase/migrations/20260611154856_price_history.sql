-- Price history table: tracks every actual price change per service
CREATE TABLE std_price_history (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  clinic_id TEXT NOT NULL,
  service_code TEXT NOT NULL,
  price NUMERIC(10,2) NOT NULL,
  first_seen DATE NOT NULL,         -- First transaction at this price
  last_seen DATE NOT NULL,           -- Last transaction at this price
  transaction_count INT DEFAULT 0,   -- How many times charged
  is_current BOOLEAN DEFAULT false,  -- Is this the current price?
  created_at TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE std_price_history ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Service role full access" ON std_price_history FOR ALL USING (true) WITH CHECK (true);
CREATE INDEX idx_sph_clinic ON std_price_history(clinic_id);
CREATE INDEX idx_sph_current ON std_price_history(clinic_id, service_code) WHERE is_current = true;

-- Function to detect price changes from transaction history
-- Groups transactions by consecutive same-price periods
CREATE OR REPLACE FUNCTION compute_price_history(p_clinic_id TEXT)
RETURNS JSON
LANGUAGE plpgsql SECURITY DEFINER AS $_$
DECLARE
  result JSON;
BEGIN
  DELETE FROM std_price_history WHERE clinic_id = p_clinic_id;

  -- For each service, find distinct price periods
  -- A "period" = consecutive transactions at the same unit price
  -- We detect changes by finding where the mode price shifts
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
  -- Get monthly mode price per service
  monthly_modes AS (
    SELECT 
      service_code,
      DATE_TRUNC('month', txn_date)::DATE as month,
      unit_price,
      COUNT(*) as freq
    FROM per_unit
    GROUP BY service_code, DATE_TRUNC('month', txn_date), unit_price
  ),
  monthly_mode AS (
    SELECT DISTINCT ON (service_code, month)
      service_code, month, unit_price as mode_price
    FROM monthly_modes
    ORDER BY service_code, month, freq DESC, unit_price DESC
  ),
  -- Detect price changes: where mode differs from previous month
  price_changes AS (
    SELECT 
      m.*,
      LAG(mode_price) OVER (PARTITION BY service_code ORDER BY month) as prev_price
    FROM monthly_mode m
  ),
  -- Group consecutive months at same price into periods
  price_periods AS (
    SELECT 
      service_code,
      mode_price,
      month as period_start,
      -- End of period = month before next price change
      COALESCE(
        LEAD(month) OVER (PARTITION BY service_code ORDER BY month) - INTERVAL '1 day',
        '2099-12-31'::DATE
      ) as period_end_placeholder,
      CASE WHEN prev_price IS NULL OR prev_price != mode_price THEN 1 ELSE 0 END as is_change
    FROM price_changes
  ),
  -- Assign period groups
  period_groups AS (
    SELECT 
      service_code,
      mode_price,
      period_start,
      SUM(is_change) OVER (PARTITION BY service_code ORDER BY period_start) as period_id
    FROM price_periods
  ),
  -- Aggregate into one row per price period
  periods AS (
    SELECT 
      service_code,
      mode_price as price,
      MIN(period_start) as first_seen,
      MAX(period_start) + INTERVAL '1 month' - INTERVAL '1 day' as last_seen,
      COUNT(*) as month_count
    FROM period_groups
    GROUP BY service_code, mode_price, period_id
  ),
  -- Get actual transaction counts per period
  period_stats AS (
    SELECT 
      p.service_code,
      p.price,
      p.first_seen,
      p.last_seen,
      p.month_count,
      COUNT(pu.txn_date) as transaction_count
    FROM periods p
    LEFT JOIN per_unit pu ON pu.service_code = p.service_code 
      AND pu.unit_price = p.price
      AND pu.txn_date >= p.first_seen 
      AND pu.txn_date <= p.last_seen
    GROUP BY p.service_code, p.price, p.first_seen, p.last_seen, p.month_count
  ),
  -- Identify current price (latest period)
  current_prices AS (
    SELECT DISTINCT ON (service_code) service_code, price
    FROM periods ORDER BY service_code, first_seen DESC
  )
  INSERT INTO std_price_history (
    clinic_id, service_code, price, first_seen, last_seen, transaction_count, is_current
  )
  SELECT 
    p_clinic_id,
    ps.service_code,
    ps.price,
    ps.first_seen,
    ps.last_seen,
    ps.transaction_count,
    cp.price IS NOT NULL
  FROM period_stats ps
  LEFT JOIN current_prices cp ON cp.service_code = ps.service_code AND cp.price = ps.price
  WHERE ps.transaction_count >= 3;

  SELECT json_build_object(
    'clinic_id', p_clinic_id,
    'price_periods', COUNT(*),
    'services_with_changes', COUNT(DISTINCT CASE WHEN is_current THEN service_code END)
  ) INTO result
  FROM std_price_history WHERE clinic_id = p_clinic_id;
  
  RETURN result;
END;
$_$;
