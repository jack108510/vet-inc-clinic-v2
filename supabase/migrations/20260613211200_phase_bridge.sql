-- Phase 1 ↔ Phase 2 Bridge
-- When Phase 1 approves/implements a price change, the engine needs to:
--   1. Stop any running experiment on that service (Phase 1 overrides)
--   2. Mark a 30-day cooldown before the engine can test it again
--   3. Engine reads the NEW price as its baseline going forward

-- Add phase1_cooldown tracking to std_service_prices
ALTER TABLE std_service_prices ADD COLUMN IF NOT EXISTS phase1_cooldown_until DATE DEFAULT NULL;
ALTER TABLE std_service_prices ADD COLUMN IF NOT EXISTS phase1_last_changed DATE DEFAULT NULL;

-- Override implement_recommendation to also notify the engine
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

  -- Mark as implemented
  UPDATE std_approval_queue SET status = 'implemented', implemented_at = NOW()
  WHERE id = p_queue_id;

  -- Update baselines
  UPDATE std_service_baselines SET status = 'active', price_implemented = rec.suggested_price
  WHERE campaign_id = p_queue_id;

  -- === PHASE 2 BRIDGE ===
  -- 1. Stop any running experiment on this service
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

  -- 2. Log the experiment abort
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

  -- 3. Set 30-day cooldown on this service
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

-- Update evaluate_all_services to respect Phase 1 cooldowns
-- (add cooldown check to the classification logic)
CREATE OR REPLACE FUNCTION evaluate_all_services_v2(p_clinic_id TEXT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $_$
DECLARE
  v_result JSONB;
  v_cooldown_count INT;
BEGIN
  -- Count services in cooldown
  SELECT COUNT(*) INTO v_cooldown_count
  FROM std_service_prices
  WHERE clinic_id = p_clinic_id
    AND phase1_cooldown_until IS NOT NULL
    AND phase1_cooldown_until > CURRENT_DATE;

  -- Run the original evaluation
  SELECT evaluate_all_services(p_clinic_id) INTO v_result;

  -- Merge cooldown info
  SELECT jsonb_set(
    v_result,
    '{phase1_cooldown}',
    to_jsonb(v_cooldown_count)
  ) INTO v_result;

  RETURN v_result;
END;
$_$;

-- Update start_experiment to check Phase 1 cooldown
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
  v_cooldown DATE;
  v_new_price NUMERIC;
  v_nudge NUMERIC;
  v_active_exp INT;
BEGIN
  -- Get current price info
  SELECT * INTO v_price FROM std_service_prices
  WHERE clinic_id = p_clinic_id AND service_code = p_service_code;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('error', 'service not found');
  END IF;

  -- CHECK 1: Phase 1 cooldown
  IF v_price.phase1_cooldown_until IS NOT NULL AND v_price.phase1_cooldown_until > CURRENT_DATE THEN
    RETURN jsonb_build_object(
      'error', 'phase1_cooldown',
      'message', 'Owner recently changed this price via Phase 1. Engine waits until ' || v_price.phase1_cooldown_until,
      'cooldown_until', v_price.phase1_cooldown_until
    );
  END IF;

  -- CHECK 2: Already running experiment?
  SELECT COUNT(*) INTO v_active_exp FROM std_price_experiments
  WHERE clinic_id = p_clinic_id AND service_code = p_service_code AND status = 'running';
  IF v_active_exp > 0 THEN
    RETURN jsonb_build_object('error', 'already_running', 'message', 'Experiment already active on this service');
  END IF;

  -- CHECK 3: Max concurrent experiments
  SELECT COUNT(*) INTO v_active_exp FROM std_price_experiments
  WHERE clinic_id = p_clinic_id AND status = 'running';
  IF v_active_exp >= 20 THEN
    RETURN jsonb_build_object('error', 'max_concurrent', 'message', '20 experiments already running');
  END IF;

  -- Get nudge from elasticity if not provided
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

  -- Calculate new price (ends in .99)
  v_new_price := FLOOR((v_price.current_price * (1 + v_nudge / 100))) + 0.99;

  -- Safety: max 10% from current
  IF v_new_price > v_price.current_price * 1.10 THEN
    v_new_price := FLOOR(v_price.current_price * 1.10) + 0.99;
  END IF;

  -- Compute 30-day baseline
  SELECT COALESCE(SUM(amount), 0), COUNT(*), COUNT(DISTINCT txn_date::date), MAX(txn_date::date)
  INTO v_price.baseline_revenue, v_price.baseline_volume, v_price.baseline_days, v_price.baseline_end
  FROM std_transactions
  WHERE clinic_id = p_clinic_id AND service_code = p_service_code
    AND txn_date >= CURRENT_DATE - 37 AND txn_date < CURRENT_DATE - 7 AND amount > 0;

  -- Insert experiment
  INSERT INTO std_price_experiments (
    clinic_id, service_code, original_price, test_price, nudge_pct,
    start_date, baseline_revenue, baseline_volume, baseline_days, baseline_end_date,
    status
  ) VALUES (
    p_clinic_id, p_service_code, v_price.current_price, v_new_price, v_nudge,
    CURRENT_DATE, v_price.baseline_revenue, v_price.baseline_volume, v_price.baseline_days, v_price.baseline_end,
    'running'
  ) RETURNING id INTO v_exp_id;

  INSERT INTO std_experiment_history (experiment_id, action, details)
  VALUES (v_exp_id, 'started', jsonb_build_object(
    'original_price', v_price.current_price,
    'test_price', v_new_price,
    'nudge_pct', v_nudge,
    'baseline_revenue', v_price.baseline_revenue,
    'baseline_volume', v_price.baseline_volume,
    'baseline_days', v_price.baseline_days
  ));

  RETURN jsonb_build_object(
    'experiment_id', v_exp_id,
    'service_code', p_service_code,
    'original_price', v_price.current_price,
    'test_price', v_new_price,
    'nudge_pct', v_nudge,
    'baseline_revenue', v_price.baseline_revenue,
    'baseline_days', v_price.baseline_days
  );
END;
$_$;
