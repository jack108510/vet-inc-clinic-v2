DROP TABLE IF EXISTS std_service_prices CASCADE;

CREATE TABLE std_service_prices (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  clinic_id TEXT NOT NULL,
  service_code TEXT NOT NULL,
  service_name TEXT,
  current_price NUMERIC(10,2) NOT NULL,
  price_set_date DATE,
  last_charged_date DATE,
  price_source TEXT DEFAULT 'transaction_mode',
  total_transactions INT DEFAULT 0,
  annual_volume NUMERIC(10,2) DEFAULT 0,
  annual_revenue NUMERIC(12,2) DEFAULT 0,
  category TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(clinic_id, service_code)
);

ALTER TABLE std_service_prices ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Service role full access" ON std_service_prices FOR ALL USING (true) WITH CHECK (true);
CREATE INDEX idx_ssp_clinic ON std_service_prices(clinic_id);
CREATE INDEX idx_ssp_lookup ON std_service_prices(clinic_id, service_code);

CREATE OR REPLACE FUNCTION compute_service_prices(p_clinic_id TEXT)
RETURNS JSON
LANGUAGE plpgsql SECURITY DEFINER AS $$
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
      MAX(txn_date) as last_seen,
      COUNT(*)::numeric / GREATEST(
        EXTRACT(YEAR FROM MAX(txn_date)) - EXTRACT(YEAR FROM MIN(txn_date)) + 1, 
        1
      ) as annual_volume
    FROM per_unit
    GROUP BY service_code, unit_price
  ),
  mode_prices AS (
    SELECT DISTINCT ON (service_code)
      service_code,
      unit_price as current_price,
      first_seen as price_set_date,
      last_seen as last_charged_date,
      freq as total_transactions,
      annual_volume,
      freq * unit_price as annual_revenue
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
    mp.annual_volume,
    mp.annual_revenue,
    sv.category
  FROM mode_prices mp
  LEFT JOIN std_services sv ON sv.code = mp.service_code AND sv.clinic_id = p_clinic_id
  WHERE mp.current_price >= 1.0
    AND mp.total_transactions >= 3;

  SELECT json_build_object(
    'clinic_id', p_clinic_id,
    'services', COUNT(*),
    'total_annual_revenue', COALESCE(SUM(annual_revenue), 0)
  ) INTO result
  FROM std_service_prices
  WHERE clinic_id = p_clinic_id;

  RETURN result;
END;
$$;
