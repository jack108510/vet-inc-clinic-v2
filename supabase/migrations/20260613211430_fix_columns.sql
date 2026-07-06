-- Fix start_experiment_v2 column names to match actual table schema
CREATE OR REPLACE FUNCTION start_experiment_v2(
  p_clinic_id TEXT,
  p_service_code TEXT,
  p_nudge_pct NUMERIC DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $_$
DECLARE
  v_price RECORD;
  v_exp_id BIGINT;
  v_new_price NUMERIC;
  v_nudge NUMERIC;
  v_active_exp INT;
  v_base_rev NUMERIC;
  v_base_vol INT;
  v_base_days INT;
  v_base_end DATE;
BEGIN
  SELECT * INTO v_price FROM std_service_prices
  WHERE clinic_id = p_clinic_id AND service_code = p_service_code;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('error', 'service not found');
  END IF;

  -- Phase 1 cooldown check
  IF v_price.phase1_cooldown_until IS NOT NULL AND v_price.phase1_cooldown_until > CURRENT_DATE THEN
    RETURN jsonb_build_object(
      'error', 'phase1_cooldown',
      'message', 'Owner recently changed this price via Phase 1. Engine waits until ' || v_price.phase1_cooldown_until,
      'cooldown_until', v_price.phase1_cooldown_until
    );
  END IF;

  -- Already running?
  SELECT COUNT(*) INTO v_active_exp FROM std_price_experiments
  WHERE clinic_id = p_clinic_id AND service_code = p_service_code AND status = 'running';
  IF v_active_exp > 0 THEN
    RETURN jsonb_build_object('error', 'already_running');
  END IF;

  -- Max concurrent
  SELECT COUNT(*) INTO v_active_exp FROM std_price_experiments
  WHERE clinic_id = p_clinic_id AND status = 'running';
  IF v_active_exp >= 20 THEN
    RETURN jsonb_build_object('error', 'max_concurrent');
  END IF;

  -- Nudge from elasticity
  IF p_nudge_pct IS NOT NULL THEN
    v_nudge := p_nudge_pct;
  ELSE
    SELECT CASE
      WHEN e.adjusted_label = 'inelastic' AND e.confidence = 'high' THEN 4.0
      WHEN e.adjusted_label = 'inelastic' THEN 3.0
      WHEN e.adjusted_label = 'moderate' THEN 2.0
      WHEN e.adjusted_label = 'unknown' THEN 1.5
      WHEN e.adjusted_label = 'elastic' THEN 0.5
      ELSE 1.0
    END INTO v_nudge
    FROM std_elasticity e
    WHERE e.clinic_id = p_clinic_id AND e.service_code = p_service_code;
    v_nudge := COALESCE(v_nudge, 1.0);
  END IF;

  -- New price (ends in .99, max 10% from current)
  v_new_price := FLOOR((v_price.current_price * (1 + v_nudge / 100))) + 0.99;
  IF v_new_price > v_price.current_price * 1.10 THEN
    v_new_price := FLOOR(v_price.current_price * 1.10) + 0.99;
  END IF;

  -- 30-day baseline
  SELECT COALESCE(SUM(amount), 0), COUNT(*), COUNT(DISTINCT txn_date::date), MAX(txn_date::date)
  INTO v_base_rev, v_base_vol, v_base_days, v_base_end
  FROM std_transactions
  WHERE clinic_id = p_clinic_id AND service_code = p_service_code
    AND txn_date >= CURRENT_DATE - 37 AND txn_date < CURRENT_DATE - 7 AND amount > 0;

  INSERT INTO std_price_experiments (
    clinic_id, service_code, experiment_type,
    old_price, test_price, change_pct, direction,
    start_date, baseline_revenue, baseline_volume, baseline_days,
    status
  ) VALUES (
    p_clinic_id, p_service_code, 'demand',
    v_price.current_price, v_new_price, v_nudge, 'up',
    CURRENT_DATE, v_base_rev, v_base_vol, v_base_days,
    'running'
  ) RETURNING id INTO v_exp_id;

  INSERT INTO std_experiment_history (experiment_id, action, details)
  VALUES (v_exp_id, 'started', jsonb_build_object(
    'old_price', v_price.current_price,
    'test_price', v_new_price,
    'nudge_pct', v_nudge,
    'baseline_revenue', v_base_rev,
    'baseline_volume', v_base_vol,
    'baseline_days', v_base_days
  ));

  RETURN jsonb_build_object(
    'experiment_id', v_exp_id,
    'service_code', p_service_code,
    'old_price', v_price.current_price,
    'test_price', v_new_price,
    'nudge_pct', v_nudge,
    'baseline_revenue', v_base_rev,
    'baseline_days', v_base_days
  );
END;
$_$;

-- Also fix implement_recommendation to use correct column name (old_price exists on approval_queue)
CREATE OR REPLACE FUNCTION implement_recommendation(p_queue_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $_$
DECLARE
  rec RECORD;
  exp_count INT := 0;
BEGIN
  SELECT * INTO rec FROM std_approval_queue WHERE id = p_queue_id AND status = 'approved';
  IF NOT FOUND THEN
    RETURN jsonb_build_object('error', 'Not found or not approved');
  END IF;

  UPDATE std_approval_queue SET status = 'implemented', implemented_at = NOW()
  WHERE id = p_queue_id;

  UPDATE std_service_baselines SET status = 'active', price_implemented = rec.suggested_price
  WHERE campaign_id = p_queue_id;

  -- === PHASE 2 BRIDGE ===
  -- Stop any running experiment on this service
  UPDATE std_price_experiments
  SET status = 'concluded',
      decision = 'revert',
      decision_reason = 'Phase 1 manual override — owner changed price from $' || rec.old_price || ' to $' || rec.suggested_price,
      end_date = CURRENT_DATE,
      decided_at = NOW()
  WHERE clinic_id = rec.clinic_id
    AND service_code = rec.service_code
    AND status = 'running';

  GET DIAGNOSTICS exp_count = ROW_COUNT;

  IF exp_count > 0 THEN
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

  -- Set 30-day cooldown
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
    'experiments_stopped', exp_count,
    'cooldown_until', CURRENT_DATE + INTERVAL '30 days'
  );
END;
$_$;
