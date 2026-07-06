-- Fix baseline query in implement_recommendation
CREATE OR REPLACE FUNCTION implement_recommendation(p_queue_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $_$
DECLARE
  rec RECORD;
  v_old_exp INT;
  v_new_exp_id BIGINT;
  v_base_rev NUMERIC;
  v_base_vol INT;
  v_base_days INT;
  v_base_end DATE;
  v_data_end DATE;
BEGIN
  SELECT * INTO rec FROM std_approval_queue WHERE id = p_queue_id AND status = 'approved';
  IF NOT FOUND THEN
    RETURN jsonb_build_object('error', 'Not found or not approved');
  END IF;

  UPDATE std_approval_queue SET status = 'implemented', implemented_at = NOW()
  WHERE id = p_queue_id;

  UPDATE std_service_baselines SET status = 'active', price_implemented = rec.suggested_price
  WHERE campaign_id = p_queue_id;

  -- === STOP Phase 2 experiments on this service ===
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
           jsonb_build_object('reason', 'Owner approved Phase 1 price change', 'old_price', rec.old_price, 'new_price', rec.suggested_price, 'campaign', rec.strategy)
    FROM std_price_experiments
    WHERE clinic_id = rec.clinic_id AND service_code = rec.service_code AND decision = 'revert' AND decision_reason LIKE 'Phase 1 manual override%';
  END IF;

  -- === COMPUTE BASELINE (most recent 30 days of data) ===
  -- Find the last transaction date for this service
  SELECT MAX(txn_date) INTO v_data_end
  FROM std_transactions
  WHERE clinic_id = rec.clinic_id AND service_code = rec.service_code AND amount > 0;

  -- Get 30-day baseline ending 7 days before last txn (avoid edge effects)
  SELECT COALESCE(SUM(amount), 0), COUNT(*), COUNT(DISTINCT txn_date::date), MAX(txn_date::date)
  INTO v_base_rev, v_base_vol, v_base_days, v_base_end
  FROM std_transactions
  WHERE clinic_id = rec.clinic_id
    AND service_code = rec.service_code
    AND amount > 0
    AND txn_date >= v_data_end - INTERVAL '37 days'
    AND txn_date < v_data_end - INTERVAL '7 days';

  -- === CREATE PHASE 1 TRACKING EXPERIMENT ===
  INSERT INTO std_price_experiments (
    clinic_id, service_code, experiment_type,
    old_price, test_price, change_pct, direction,
    start_date, baseline_revenue, baseline_volume, baseline_days, baseline_end_date,
    status
  ) VALUES (
    rec.clinic_id, rec.service_code, 'phase1',
    rec.old_price, rec.suggested_price,
    CASE WHEN rec.old_price > 0 THEN ROUND(((rec.suggested_price - rec.old_price) / rec.old_price * 100)::NUMERIC, 1) ELSE 0 END,
    CASE WHEN rec.suggested_price >= rec.old_price THEN 'up' ELSE 'down' END,
    CURRENT_DATE, v_base_rev, v_base_vol, v_base_days, v_base_end,
    'running'
  ) RETURNING id INTO v_new_exp_id;

  INSERT INTO std_experiment_history (experiment_id, action, details)
  VALUES (v_new_exp_id, 'phase1_tracked', jsonb_build_object(
    'queue_id', p_queue_id, 'strategy', rec.strategy,
    'old_price', rec.old_price, 'new_price', rec.suggested_price,
    'campaign', rec.campaign_id,
    'baseline_revenue', v_base_rev, 'baseline_volume', v_base_vol,
    'baseline_days', v_base_days, 'baseline_end', v_base_end
  ));

  -- === Phase 2 cooldown ===
  UPDATE std_service_prices
  SET phase1_cooldown_until = CURRENT_DATE + INTERVAL '30 days',
      phase1_last_changed = CURRENT_DATE,
      current_price = rec.suggested_price,
      updated_at = NOW()
  WHERE clinic_id = rec.clinic_id AND service_code = rec.service_code;

  RETURN jsonb_build_object(
    'implemented', rec.service_code,
    'new_price', rec.suggested_price,
    'experiments_stopped', v_old_exp,
    'tracking_experiment_id', v_new_exp_id,
    'baseline_revenue', v_base_rev,
    'baseline_volume', v_base_vol,
    'baseline_days', v_base_days,
    'cooldown_until', CURRENT_DATE + INTERVAL '30 days'
  );
END;
$_$;
