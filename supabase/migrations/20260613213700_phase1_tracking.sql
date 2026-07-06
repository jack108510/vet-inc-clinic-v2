-- Phase 1 Impact Tracking
-- When owner approves a Phase 1 price change, auto-track it as an experiment
-- Same measurement logic, tagged as 'phase1'

-- =====================================================
-- 1. Update implement_recommendation to create a tracking experiment
-- =====================================================
CREATE OR REPLACE FUNCTION implement_recommendation(p_queue_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $_$
DECLARE
  rec RECORD;
  v_exp_count INT := 0;
  v_new_exp_id BIGINT;
  v_base_rev NUMERIC;
  v_base_vol INT;
  v_base_days INT;
  v_base_end DATE;
  v_old_exp INT;
BEGIN
  SELECT * INTO rec FROM std_approval_queue WHERE id = p_queue_id AND status = 'approved';
  IF NOT FOUND THEN
    RETURN jsonb_build_object('error', 'Not found or not approved');
  END IF;

  -- Mark as implemented
  UPDATE std_approval_queue SET status = 'implemented', implemented_at = NOW()
  WHERE id = p_queue_id;

  UPDATE std_service_baselines SET status = 'active', price_implemented = rec.suggested_price
  WHERE campaign_id = p_queue_id;

  -- === STOP any Phase 2 engine experiment on this service ===
  UPDATE std_price_experiments
  SET status = 'concluded',
      decision = 'revert',
      decision_reason = 'Phase 1 manual override — owner changed price from $' || rec.old_price || ' to $' || rec.suggested_price,
      end_date = CURRENT_DATE,
      decided_at = NOW()
  WHERE clinic_id = rec.clinic_id
    AND service_code = rec.service_code
    AND status = 'running';

  GET DIAGNOSTICS v_old_exp = ROW_COUNT;

  IF v_old_exp > 0 THEN
    INSERT INTO std_experiment_history (experiment_id, action, details)
    SELECT id, 'aborted_by_phase1',
           jsonb_build_object(
             'reason', 'Owner approved Phase 1 price change',
             'old_price', rec.old_price,
             'new_price', rec.suggested_price,
             'campaign', rec.strategy
           )
    FROM std_price_experiments
    WHERE clinic_id = rec.clinic_id
      AND service_code = rec.service_code
      AND decision = 'revert'
      AND decision_reason LIKE 'Phase 1 manual override%';
  END IF;

  -- === COMPUTE BASELINE (30 days before the change) ===
  SELECT COALESCE(SUM(amount), 0), COUNT(*), COUNT(DISTINCT txn_date::date), MAX(txn_date::date)
  INTO v_base_rev, v_base_vol, v_base_days, v_base_end
  FROM std_transactions
  WHERE clinic_id = rec.clinic_id
    AND service_code = rec.service_code
    AND amount > 0
    AND txn_date < CURRENT_DATE
  ORDER BY txn_date DESC
  LIMIT 1;

  -- Actually compute proper 30-day baseline from most recent data
  SELECT COALESCE(SUM(amount), 0), COUNT(*), COUNT(DISTINCT txn_date::date), MAX(txn_date::date)
  INTO v_base_rev, v_base_vol, v_base_days, v_base_end
  FROM std_transactions
  WHERE clinic_id = rec.clinic_id
    AND service_code = rec.service_code
    AND amount > 0
    AND txn_date >= (SELECT MAX(txn_date) FROM std_transactions WHERE clinic_id = rec.clinic_id AND service_code = rec.service_code AND amount > 0) - INTERVAL '37 days'
    AND txn_date < (SELECT MAX(txn_date) FROM std_transactions WHERE clinic_id = rec.clinic_id AND service_code = rec.service_code AND amount > 0) - INTERVAL '7 days';

  -- === CREATE PHASE 1 TRACKING EXPERIMENT ===
  INSERT INTO std_price_experiments (
    clinic_id, service_code, experiment_type,
    old_price, test_price, change_pct, direction,
    start_date, baseline_revenue, baseline_volume, baseline_days,
    status
  ) VALUES (
    rec.clinic_id, rec.service_code, 'phase1',
    rec.old_price, rec.suggested_price,
    CASE WHEN rec.old_price > 0 THEN ROUND(((rec.suggested_price - rec.old_price) / rec.old_price * 100)::NUMERIC, 1) ELSE 0 END,
    CASE WHEN rec.suggested_price >= rec.old_price THEN 'up' ELSE 'down' END,
    CURRENT_DATE, v_base_rev, v_base_vol, v_base_days,
    'running'
  ) RETURNING id INTO v_new_exp_id;

  INSERT INTO std_experiment_history (experiment_id, action, details)
  VALUES (v_new_exp_id, 'phase1_tracked', jsonb_build_object(
    'queue_id', p_queue_id,
    'strategy', rec.strategy,
    'old_price', rec.old_price,
    'new_price', rec.suggested_price,
    'campaign', rec.campaign_id,
    'baseline_revenue', v_base_rev,
    'baseline_volume', v_base_vol,
    'baseline_days', v_base_days,
    'message', 'Phase 1 price change is now being tracked. Engine will measure impact after 30 days of new data.'
  ));

  -- === Set cooldown for Phase 2 engine ===
  UPDATE std_service_prices
  SET phase1_cooldown_until = CURRENT_DATE + INTERVAL '30 days',
      phase1_last_changed = CURRENT_DATE,
      current_price = rec.suggested_price,
      updated_at = NOW()
  WHERE clinic_id = rec.clinic_id
    AND service_code = rec.service_code;

  RETURN jsonb_build_object(
    'implemented', rec.service_code,
    'new_price', rec.suggested_price,
    'experiments_stopped', v_old_exp,
    'tracking_experiment_id', v_new_exp_id,
    'baseline_revenue', v_base_rev,
    'baseline_volume', v_base_vol,
    'cooldown_until', CURRENT_DATE + INTERVAL '30 days',
    'message', 'Price implemented. Engine will track impact automatically.'
  );
END;
$_$;

-- =====================================================
-- 2. Phase 1 measurement — uses longer window (30+ days)
-- =====================================================
CREATE OR REPLACE FUNCTION measure_phase1_impact(p_experiment_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $_$
DECLARE
  v_exp RECORD;
  v_test_rev NUMERIC;
  v_test_vol INT;
  v_test_days INT;
  v_rev_change_pct NUMERIC;
  v_vol_change_pct NUMERIC;
  v_clinic_growth NUMERIC;
  v_adj_vol_change NUMERIC;
  v_seasonal_adj NUMERIC;
  v_decision TEXT;
  v_reason TEXT;
  v_cutoff DATE;
  v_month_of_year INT;
BEGIN
  SELECT * INTO v_exp FROM std_price_experiments WHERE id = p_experiment_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('error', 'not found'); END IF;
  IF v_exp.status != 'running' THEN RETURN jsonb_build_object('error', 'not running'); END IF;

  -- Phase 1 needs 30 days minimum (bigger change = need more data)
  IF CURRENT_DATE - v_exp.start_date < 30 THEN
    RETURN jsonb_build_object('status', 'too_early', 'days_elapsed', CURRENT_DATE - v_exp.start_date, 'min_days', 30);
  END IF;

  SELECT MAX(txn_date) INTO v_cutoff FROM std_transactions WHERE clinic_id = v_exp.clinic_id;

  SELECT COALESCE(SUM(amount), 0), COUNT(*), COUNT(DISTINCT txn_date::date)
  INTO v_test_rev, v_test_vol, v_test_days
  FROM std_transactions
  WHERE clinic_id = v_exp.clinic_id AND service_code = v_exp.service_code
    AND txn_date >= v_exp.start_date AND txn_date <= COALESCE(v_cutoff, CURRENT_DATE) AND amount > 0;

  IF v_test_days < 15 THEN
    RETURN jsonb_build_object('status', 'insufficient_data', 'days', v_test_days, 'min_days', 15);
  END IF;

  v_rev_change_pct := CASE WHEN v_exp.baseline_days > 0 AND v_exp.baseline_revenue > 0 THEN
    ((v_test_rev::numeric / v_test_days) - (v_exp.baseline_revenue / v_exp.baseline_days))
    / (v_exp.baseline_revenue / v_exp.baseline_days) * 100 END;

  v_vol_change_pct := CASE WHEN v_exp.baseline_days > 0 AND v_exp.baseline_volume > 0 THEN
    ((v_test_vol::numeric / v_test_days) - (v_exp.baseline_volume::numeric / v_exp.baseline_days))
    / (v_exp.baseline_volume::numeric / v_exp.baseline_days) * 100 END;

  -- Clinic growth
  SELECT CASE WHEN AVG(avg_daily_volume) FILTER (WHERE month_date >= (v_exp.start_date - INTERVAL '30 days')::date AND month_date < v_exp.start_date) > 0 THEN
    (AVG(avg_daily_volume) FILTER (WHERE month_date >= v_exp.start_date) -
     AVG(avg_daily_volume) FILTER (WHERE month_date >= (v_exp.start_date - INTERVAL '30 days')::date AND month_date < v_exp.start_date))
    / AVG(avg_daily_volume) FILTER (WHERE month_date >= (v_exp.start_date - INTERVAL '30 days')::date AND month_date < v_exp.start_date) * 100
  END INTO v_clinic_growth
  FROM std_clinic_baseline WHERE clinic_id = v_exp.clinic_id;

  -- Seasonal
  v_month_of_year := EXTRACT(MONTH FROM v_exp.start_date)::int;
  SELECT CASE WHEN seasonal_volatility > 0.2 AND low_month = v_month_of_year THEN -seasonal_volatility * 20
              WHEN seasonal_volatility > 0.2 AND peak_month = v_month_of_year THEN seasonal_volatility * 20
              ELSE 0 END
  INTO v_seasonal_adj
  FROM std_service_metrics WHERE clinic_id = v_exp.clinic_id AND service_code = v_exp.service_code;

  v_adj_vol_change := CASE WHEN v_vol_change_pct IS NOT NULL THEN
    v_vol_change_pct - COALESCE(v_clinic_growth, 0) - COALESCE(v_seasonal_adj, 0) END;

  -- DECISION (Phase 1 = bigger changes, more tolerance for volume shift)
  IF v_vol_change_pct IS NULL THEN
    v_decision := 'review'; v_reason := 'insufficient baseline data';
  ELSIF v_adj_vol_change < -20 THEN
    v_decision := 'alert';
    v_reason := 'SIGNIFICANT volume drop (' || ROUND(v_adj_vol_change::NUMERIC,1) || '%). Phase 1 change may have hurt demand. Consider reverting.';
  ELSIF v_rev_change_pct > 5 AND v_adj_vol_change >= -10 THEN
    v_decision := 'success';
    v_reason := 'Revenue +' || ROUND(v_rev_change_pct::NUMERIC,1) || '%, volume stable. Phase 1 change worked.';
  ELSIF v_rev_change_pct > 0 AND v_adj_vol_change >= -20 THEN
    v_decision := 'monitor';
    v_reason := 'Revenue +' || ROUND(v_rev_change_pct::NUMERIC,1) || '% but volume softened (' || ROUND(v_adj_vol_change::NUMERIC,1) || '%). Keep watching.';
  ELSIF v_rev_change_pct <= 0 THEN
    v_decision := 'alert';
    v_reason := 'Revenue DECLINED ' || ROUND(v_rev_change_pct::NUMERIC,1) || '% after price change. Volume adj: ' || ROUND(v_adj_vol_change::NUMERIC,1) || '%. May need to revert.';
  ELSIF v_adj_vol_change >= 0 THEN
    v_decision := 'success';
    v_reason := 'Volume stable, revenue up. Phase 1 change worked.';
  ELSE
    v_decision := 'review';
    v_reason := 'Ambiguous — rev ' || COALESCE(ROUND(v_rev_change_pct::NUMERIC,1)::text,'?') || '%, adj vol ' || COALESCE(ROUND(v_adj_vol_change::NUMERIC,1)::text,'?') || '%';
  END IF;

  UPDATE std_price_experiments SET
    test_revenue = v_test_rev, test_volume = v_test_vol, test_days = v_test_days,
    revenue_change_pct = ROUND(v_rev_change_pct::NUMERIC, 1),
    volume_change_pct = ROUND(v_vol_change_pct::NUMERIC, 1),
    decision = v_decision, decision_reason = v_reason,
    decided_at = NOW(), end_date = CURRENT_DATE,
    status = 'concluded'
  WHERE id = p_experiment_id;

  INSERT INTO std_experiment_history (experiment_id, action, details)
  VALUES (p_experiment_id, 'phase1_measured', jsonb_build_object(
    'test_revenue', v_test_rev, 'test_volume', v_test_vol, 'test_days', v_test_days,
    'revenue_change_pct', ROUND(v_rev_change_pct::NUMERIC, 1),
    'raw_volume_change', ROUND(v_vol_change_pct::NUMERIC, 1),
    'clinic_growth_pct', ROUND(COALESCE(v_clinic_growth,0)::NUMERIC, 1),
    'seasonal_adj', ROUND(COALESCE(v_seasonal_adj,0)::NUMERIC, 1),
    'adjusted_volume_change', ROUND(v_adj_vol_change::NUMERIC, 1),
    'decision', v_decision, 'reason', v_reason
  ));

  RETURN jsonb_build_object(
    'experiment_id', p_experiment_id,
    'service_code', v_exp.service_code,
    'type', 'phase1',
    'revenue_change_pct', ROUND(v_rev_change_pct::NUMERIC, 1),
    'adjusted_volume_change', ROUND(v_adj_vol_change::NUMERIC, 1),
    'decision', v_decision, 'reason', v_reason
  );
END;
$_$;

-- =====================================================
-- 3. Phase 1 digest — summarize all tracked Phase 1 changes
-- =====================================================
CREATE OR REPLACE FUNCTION phase1_impact_digest(p_clinic_id TEXT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $_$
DECLARE
  v_tracked INT;
  v_success INT;
  v_alert INT;
  v_monitor INT;
  v_review INT;
  v_total_uplift NUMERIC := 0;
  v_pending INT;
BEGIN
  SELECT COUNT(*) INTO v_tracked
  FROM std_price_experiments
  WHERE clinic_id = p_clinic_id AND experiment_type = 'phase1';

  SELECT
    COUNT(*) FILTER (WHERE decision = 'success'),
    COUNT(*) FILTER (WHERE decision = 'alert'),
    COUNT(*) FILTER (WHERE decision = 'monitor'),
    COUNT(*) FILTER (WHERE decision = 'review')
  INTO v_success, v_alert, v_monitor, v_review
  FROM std_price_experiments
  WHERE clinic_id = p_clinic_id AND experiment_type = 'phase1' AND status = 'concluded';

  SELECT COUNT(*) INTO v_pending
  FROM std_price_experiments
  WHERE clinic_id = p_clinic_id AND experiment_type = 'phase1' AND status = 'running';

  SELECT COALESCE(SUM(net_revenue_change), 0) INTO v_total_uplift
  FROM std_price_experiments
  WHERE clinic_id = p_clinic_id AND experiment_type = 'phase1' AND decision = 'success';

  RETURN jsonb_build_object(
    'total_tracked', v_tracked,
    'pending_measurement', v_pending,
    'success', v_success,
    'alerts', v_alert,
    'monitoring', v_monitor,
    'needs_review', v_review,
    'estimated_annual_uplift', ROUND(v_total_uplift::NUMERIC, 2)
  );
END;
$_$;
