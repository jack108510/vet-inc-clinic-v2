-- ============================================================
-- CLINIC BASELINE: Monthly volume, revenue, and seasonality
-- Every service's performance is measured relative to this
-- ============================================================

CREATE TABLE std_clinic_baseline (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  clinic_id TEXT NOT NULL,
  month_date DATE NOT NULL,             -- first day of month
  total_transactions INT NOT NULL DEFAULT 0,
  total_revenue NUMERIC NOT NULL DEFAULT 0,
  unique_visit_days INT NOT NULL DEFAULT 0,  -- days clinic was open (had transactions)
  active_services INT NOT NULL DEFAULT 0,     -- distinct service codes sold that month
  avg_daily_volume NUMERIC NOT NULL DEFAULT 0, -- transactions per active day
  avg_daily_revenue NUMERIC NOT NULL DEFAULT 0,
  -- Rolling metrics (trailing 12 months ending this month)
  rolling_12m_revenue NUMERIC,
  rolling_12m_volume INT,
  -- Growth vs same month prior year (null if no prior data)
  yoy_revenue_growth NUMERIC,            -- % change vs same month last year
  yoy_volume_growth NUMERIC,
  -- Seasonality
  month_of_year INT NOT NULL,
  seasonal_index NUMERIC,                -- this month's revenue / average month revenue
  created_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(clinic_id, month_date)
);

ALTER TABLE std_clinic_baseline ENABLE ROW LEVEL SECURITY;
CREATE POLICY "auth_baseline" ON std_clinic_baseline FOR SELECT USING (clinic_id IN (SELECT clinic_id FROM meta_clinic_users WHERE user_id = auth.uid()));
CREATE POLICY "svc_baseline" ON std_clinic_baseline FOR ALL USING (true) WITH CHECK (true);
CREATE INDEX idx_baseline_clinic ON std_clinic_baseline(clinic_id, month_date);

-- ============================================================
-- COMPUTE CLINIC BASELINE
-- ============================================================

CREATE OR REPLACE FUNCTION compute_clinic_baseline(p_clinic_id TEXT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $_$
DECLARE
  computed INT;
  v_avg_monthly_rev NUMERIC;
BEGIN
  DELETE FROM std_clinic_baseline WHERE clinic_id = p_clinic_id;

  -- Monthly aggregates
  INSERT INTO std_clinic_baseline (
    clinic_id, month_date, total_transactions, total_revenue, unique_visit_days,
    active_services, avg_daily_volume, avg_daily_revenue, month_of_year
  )
  SELECT 
    p_clinic_id,
    month_start::date,
    COUNT(*) AS total_transactions,
    SUM(amount) AS total_revenue,
    COUNT(DISTINCT txn_date::date) AS unique_visit_days,
    COUNT(DISTINCT service_code) AS active_services,
    CASE WHEN COUNT(DISTINCT txn_date::date) > 0 THEN 
      ROUND(COUNT(*)::numeric / COUNT(DISTINCT txn_date::date), 1) ELSE 0 END,
    CASE WHEN COUNT(DISTINCT txn_date::date) > 0 THEN 
      ROUND(SUM(amount)::numeric / COUNT(DISTINCT txn_date::date), 2) ELSE 0 END,
    EXTRACT(MONTH FROM month_start)::int
  FROM std_transactions
  CROSS JOIN generate_series(
    DATE_TRUNC('month', MIN(txn_date))::date,
    DATE_TRUNC('month', MAX(txn_date))::date,
    INTERVAL '1 month'
  ) AS month_start
  WHERE clinic_id = p_clinic_id AND amount > 0
    AND txn_date >= month_start 
    AND txn_date < month_start + INTERVAL '1 month'
  GROUP BY month_start
  ORDER BY month_start;

  -- Rolling 12-month metrics
  UPDATE std_clinic_baseline b
  SET rolling_12m_revenue = sub.rev, rolling_12m_volume = sub.vol
  FROM (
    SELECT 
      b2.clinic_id, b2.month_date,
      SUM(b3.total_revenue) AS rev,
      SUM(b3.total_transactions) AS vol
    FROM std_clinic_baseline b2
    JOIN std_clinic_baseline b3 ON b3.clinic_id = b2.clinic_id
      AND b3.month_date >= b2.month_date - INTERVAL '11 months'
      AND b3.month_date <= b2.month_date
    GROUP BY b2.clinic_id, b2.month_date
  ) sub
  WHERE b.clinic_id = sub.clinic_id AND b.month_date = sub.month_date;

  -- YoY growth
  UPDATE std_clinic_baseline b
  SET 
    yoy_revenue_growth = CASE WHEN prev.total_revenue > 0 THEN 
      ROUND((b.total_revenue - prev.total_revenue) / prev.total_revenue * 100, 1) END,
    yoy_volume_growth = CASE WHEN prev.total_transactions > 0 THEN 
      ROUND((b.total_transactions - prev.total_transactions)::numeric / prev.total_transactions * 100, 1) END
  FROM std_clinic_baseline prev
  WHERE b.clinic_id = p_clinic_id AND prev.clinic_id = p_clinic_id
    AND prev.month_date = b.month_date - INTERVAL '12 months';

  -- Seasonal index: each month's revenue / average monthly revenue
  SELECT AVG(total_revenue) INTO v_avg_monthly_rev
  FROM std_clinic_baseline WHERE clinic_id = p_clinic_id;

  UPDATE std_clinic_baseline
  SET seasonal_index = CASE WHEN v_avg_monthly_rev > 0 THEN 
    ROUND(total_revenue / v_avg_monthly_rev, 3) END
  WHERE clinic_id = p_clinic_id;

  GET DIAGNOSTICS computed = ROW_COUNT;

  RETURN jsonb_build_object(
    'clinic_id', p_clinic_id,
    'months_computed', computed,
    'avg_monthly_revenue', ROUND(v_avg_monthly_rev, 2),
    'avg_yoy_revenue_growth', (SELECT ROUND(AVG(yoy_revenue_growth), 1) FROM std_clinic_baseline WHERE clinic_id = p_clinic_id AND yoy_revenue_growth IS NOT NULL),
    'avg_yoy_volume_growth', (SELECT ROUND(AVG(yoy_volume_growth), 1) FROM std_clinic_baseline WHERE clinic_id = p_clinic_id AND yoy_volume_growth IS NOT NULL),
    'date_range', (SELECT MIN(month_date)::text || ' to ' || MAX(month_date)::text FROM std_clinic_baseline WHERE clinic_id = p_clinic_id)
  );
END;
$_$;
