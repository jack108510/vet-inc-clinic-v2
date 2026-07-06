-- Fix: can't use aggregate in FROM clause directly
CREATE OR REPLACE FUNCTION compute_clinic_baseline(p_clinic_id TEXT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $_$
DECLARE
  computed INT;
  v_avg_monthly_rev NUMERIC;
  v_min_date DATE;
  v_max_date DATE;
BEGIN
  SELECT MIN(txn_date)::date, MAX(txn_date)::date INTO v_min_date, v_max_date
  FROM std_transactions WHERE clinic_id = p_clinic_id AND amount > 0;

  DELETE FROM std_clinic_baseline WHERE clinic_id = p_clinic_id;

  -- Monthly aggregates
  INSERT INTO std_clinic_baseline (
    clinic_id, month_date, total_transactions, total_revenue, unique_visit_days,
    active_services, avg_daily_volume, avg_daily_revenue, month_of_year
  )
  SELECT 
    p_clinic_id,
    ms::date,
    COUNT(t.*),
    COALESCE(SUM(t.amount), 0),
    COUNT(DISTINCT t.txn_date::date),
    COUNT(DISTINCT t.service_code),
    CASE WHEN COUNT(DISTINCT t.txn_date::date) > 0 THEN 
      ROUND(COUNT(t.id)::numeric / COUNT(DISTINCT t.txn_date::date), 1) ELSE 0 END,
    CASE WHEN COUNT(DISTINCT t.txn_date::date) > 0 THEN 
      ROUND(COALESCE(SUM(t.amount),0)::numeric / COUNT(DISTINCT t.txn_date::date), 2) ELSE 0 END,
    EXTRACT(MONTH FROM ms)::int
  FROM generate_series(
    DATE_TRUNC('month', v_min_date)::date,
    DATE_TRUNC('month', v_max_date)::date,
    INTERVAL '1 month'
  ) AS ms
  LEFT JOIN std_transactions t ON t.clinic_id = p_clinic_id AND t.amount > 0
    AND t.txn_date >= ms::date 
    AND t.txn_date < (ms + INTERVAL '1 month')::date
  GROUP BY ms
  ORDER BY ms;

  -- Rolling 12-month
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
    WHERE b2.clinic_id = p_clinic_id
    GROUP BY b2.clinic_id, b2.month_date
  ) sub
  WHERE b.month_date = sub.month_date;

  -- YoY
  UPDATE std_clinic_baseline b
  SET 
    yoy_revenue_growth = CASE WHEN prev.total_revenue > 0 THEN 
      ROUND((b.total_revenue - prev.total_revenue) / prev.total_revenue * 100, 1) END,
    yoy_volume_growth = CASE WHEN prev.total_transactions > 0 THEN 
      ROUND((b.total_transactions - prev.total_transactions)::numeric / prev.total_transactions * 100, 1) END
  FROM std_clinic_baseline prev
  WHERE prev.clinic_id = p_clinic_id
    AND prev.month_date = b.month_date - INTERVAL '12 months';

  -- Seasonal index
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
    'date_range', v_min_date::text || ' to ' || v_max_date::text
  );
END;
$_$;
