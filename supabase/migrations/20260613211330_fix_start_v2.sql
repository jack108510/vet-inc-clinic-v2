-- Fix start_experiment_v2: use separate variables for baseline
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

  -- 30-day baseline (from frozen data)
  SELECT COALESCE(SUM(amount), 0), COUNT(*), COUNT(DISTINCT txn_date::date), MAX(txn_date::date)
  INTO v_base_rev, v_base_vol, v_base_days, v_base_end
  FROM std_transactions
  WHERE clinic_id = p_clinic_id AND service_code = p_service_code
    AND txn_date >= CURRENT_DATE - 37 AND txn_date < CURRENT_DATE - 7 AND amount > 0;

  INSERT INTO std_price_experiments (
    clinic_id, service_code, original_price, test_price, nudge_pct,
    start_date, baseline_revenue, baseline_volume, baseline_days, baseline_end_date,
    status
  ) VALUES (
    p_clinic_id, p_service_code, v_price.current_price, v_new_price, v_nudge,
    CURRENT_DATE, v_base_rev, v_base_vol, v_base_days, v_base_end,
    'running'
  ) RETURNING id INTO v_exp_id;

  INSERT INTO std_experiment_history (experiment_id, action, details)
  VALUES (v_exp_id, 'started', jsonb_build_object(
    'original_price', v_price.current_price,
    'test_price', v_new_price,
    'nudge_pct', v_nudge,
    'baseline_revenue', v_base_rev,
    'baseline_volume', v_base_vol,
    'baseline_days', v_base_days
  ));

  RETURN jsonb_build_object(
    'experiment_id', v_exp_id,
    'service_code', p_service_code,
    'original_price', v_price.current_price,
    'test_price', v_new_price,
    'nudge_pct', v_nudge,
    'baseline_revenue', v_base_rev,
    'baseline_days', v_base_days
  );
END;
$_$;
