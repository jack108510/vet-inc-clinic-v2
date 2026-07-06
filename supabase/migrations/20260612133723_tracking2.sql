-- Drop old functions with wrong return types
DROP FUNCTION IF EXISTS approve_recommendation(BIGINT, UUID);
DROP FUNCTION IF EXISTS dismiss_recommendation(BIGINT, TEXT);

-- APPROVE
CREATE OR REPLACE FUNCTION approve_recommendation(p_queue_id BIGINT, p_user_id UUID)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $_$
DECLARE
  rec RECORD;
BEGIN
  SELECT * INTO rec FROM std_approval_queue WHERE id = p_queue_id AND status = 'pending';
  IF NOT FOUND THEN
    RETURN jsonb_build_object('error', 'Not found or not pending');
  END IF;

  UPDATE std_approval_queue SET 
    status = 'approved', approved_at = NOW(), approved_by = p_user_id
  WHERE id = p_queue_id;

  INSERT INTO std_service_baselines (
    clinic_id, service_code, campaign_id,
    baseline_date, avg_daily_revenue, avg_daily_volume,
    old_price, new_price, expected_daily_uplift, status
  )
  SELECT 
    rec.clinic_id, rec.service_code, rec.id,
    CURRENT_DATE,
    COALESCE(spd.annual_revenue / 365.0, 0),
    COALESCE(spd.annual_volume / 365.0, 0),
    rec.old_price, rec.suggested_price,
    rec.expected_annual_uplift / 365.0,
    'approved'
  FROM std_service_prices spd
  WHERE spd.clinic_id = rec.clinic_id AND spd.service_code = rec.service_code
  ON CONFLICT DO NOTHING;

  RETURN jsonb_build_object('approved', rec.service_code, 'queue_id', p_queue_id);
END;
$_$;

-- IMPLEMENT
CREATE OR REPLACE FUNCTION implement_recommendation(p_queue_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $_$
DECLARE
  rec RECORD;
BEGIN
  SELECT * INTO rec FROM std_approval_queue WHERE id = p_queue_id AND status = 'approved';
  IF NOT FOUND THEN
    RETURN jsonb_build_object('error', 'Not found or not approved');
  END IF;

  UPDATE std_approval_queue SET status = 'implemented', implemented_at = NOW()
  WHERE id = p_queue_id;

  UPDATE std_service_baselines SET status = 'active', price_implemented = rec.suggested_price
  WHERE campaign_id = p_queue_id;

  RETURN jsonb_build_object('implemented', rec.service_code, 'new_price', rec.suggested_price);
END;
$_$;

-- DISMISS
CREATE OR REPLACE FUNCTION dismiss_recommendation(p_queue_id BIGINT, p_reason TEXT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $_$
BEGIN
  UPDATE std_approval_queue SET status = 'dismissed', dismissed_at = NOW(), dismiss_reason = p_reason
  WHERE id = p_queue_id AND status = 'pending';
  RETURN jsonb_build_object('dismissed', p_queue_id);
END;
$_$;

-- TRACK RESULTS
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
  LEFT JOIN LATERAL (SELECT SUM(t.amount) as actual FROM std_transactions t WHERE t.clinic_id = p_clinic_id AND t.service_code = sb.service_code AND t.txn_date = p_date AND t.amount > 0) daily_rev ON true
  LEFT JOIN LATERAL (SELECT COUNT(*) as actual FROM std_transactions t WHERE t.clinic_id = p_clinic_id AND t.service_code = sb.service_code AND t.txn_date = p_date AND t.amount > 0) daily_vol ON true
  WHERE sb.clinic_id = p_clinic_id AND sb.status = 'active'
  ON CONFLICT (clinic_id, service_code, day) DO UPDATE SET
    actual_daily_revenue = EXCLUDED.actual_daily_revenue,
    captured_uplift = EXCLUDED.captured_uplift,
    volume_change_pct = EXCLUDED.volume_change_pct;

  GET DIAGNOSTICS tracked = ROW_COUNT;
  RETURN jsonb_build_object('clinic_id', p_clinic_id, 'date', p_date, 'tracked', tracked);
END;
$_$;

-- Add missing columns
ALTER TABLE std_approval_queue ADD COLUMN IF NOT EXISTS approved_at TIMESTAMPTZ;
ALTER TABLE std_approval_queue ADD COLUMN IF NOT EXISTS approved_by UUID;
ALTER TABLE std_approval_queue ADD COLUMN IF NOT EXISTS implemented_at TIMESTAMPTZ;
ALTER TABLE std_approval_queue ADD COLUMN IF NOT EXISTS dismissed_at TIMESTAMPTZ;
ALTER TABLE std_approval_queue ADD COLUMN IF NOT EXISTS dismiss_reason TEXT;

-- Unique constraint on campaign results
CREATE UNIQUE INDEX IF NOT EXISTS idx_scr_unique ON std_campaign_results(clinic_id, service_code, day);
