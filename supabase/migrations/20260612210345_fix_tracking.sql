-- Fix: track by service_code revenue, not by matching exact price
-- The actual revenue is whatever was charged for that service that day

CREATE OR REPLACE FUNCTION track_campaign_results(p_clinic_id TEXT, p_date DATE)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $_$
DECLARE
  tracked INT;
BEGIN
  INSERT INTO std_campaign_results (
    clinic_id, service_code, day,
    baseline_daily_revenue, actual_daily_revenue,
    captured_uplift, volume_change_pct, price_implemented
  )
  SELECT 
    p_clinic_id, sb.service_code, p_date,
    sb.avg_daily_revenue,
    COALESCE(daily_rev.actual, 0),
    COALESCE(daily_rev.actual, 0) - sb.avg_daily_revenue,
    CASE WHEN sb.avg_daily_volume > 0 
      THEN (COALESCE(daily_vol.actual, 0) - sb.avg_daily_volume) / sb.avg_daily_volume * 100
      ELSE 0 END,
    sb.price_implemented
  FROM std_service_baselines sb
  LEFT JOIN LATERAL (
    SELECT SUM(t.amount) as actual FROM std_transactions t 
    WHERE t.clinic_id = p_clinic_id AND t.service_code = sb.service_code 
      AND t.txn_date = p_date AND t.amount > 0
  ) daily_rev ON true
  LEFT JOIN LATERAL (
    SELECT COUNT(*) as actual FROM std_transactions t 
    WHERE t.clinic_id = p_clinic_id AND t.service_code = sb.service_code 
      AND t.txn_date = p_date AND t.amount > 0
  ) daily_vol ON true
  WHERE sb.clinic_id = p_clinic_id AND sb.status = 'active'
  ON CONFLICT (clinic_id, service_code, day) DO UPDATE SET
    actual_daily_revenue = EXCLUDED.actual_daily_revenue,
    captured_uplift = EXCLUDED.captured_uplift,
    volume_change_pct = EXCLUDED.volume_change_pct;

  GET DIAGNOSTICS tracked = ROW_COUNT;
  RETURN jsonb_build_object('clinic_id', p_clinic_id, 'date', p_date, 'tracked', tracked);
END;
$_$;
