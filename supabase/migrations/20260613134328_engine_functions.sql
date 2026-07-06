-- ============================================================
-- PRICING ENGINE FUNCTIONS
-- pick_experiment, start_experiment, measure_experiment, run_engine_cycle
-- ============================================================

-- ============================================================
-- 1. PICK: Score and select services to test
-- Returns ranked list of services that are good candidates for testing
-- Uses elasticity data + Phase 1 prices + inflation headroom
-- ============================================================

CREATE OR REPLACE FUNCTION pick_experiments(
  p_clinic_id TEXT,
  p_limit INT DEFAULT 20
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $_$
BEGIN
  RETURN (
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'service_code', sp.service_code,
      'description', sp.description,
      'current_price', sp.mode_price,
      'inflation_target', sp.suggested_price,
      'headroom_pct', CASE WHEN sp.mode_price > 0 THEN 
        ROUND((sp.suggested_price - sp.mode_price) / sp.mode_price * 100, 1) ELSE 0 END,
      'annual_revenue', sp.annual_revenue,
      'annual_volume', sp.annual_volume,
      'elasticity_label', COALESCE(e.elasticity_label, 'unknown'),
      'elasticity_value', e.elasticity,
      'confidence', COALESCE(e.confidence, 'none'),
      'score', 
        -- Scoring: higher revenue (40), headroom (30), inelasticity (20), volume (10)
        LEAST(40, sp.annual_revenue / 100) +
        LEAST(30, CASE WHEN sp.mode_price > 0 THEN 
          (sp.suggested_price - sp.mode_price) / sp.mode_price * 100 * 2 ELSE 0 END) +
        CASE WHEN COALESCE(e.elasticity_label, 'unknown') = 'inelastic' THEN 20
             WHEN COALESCE(e.elasticity_label, 'unknown') = 'moderate' THEN 10
             WHEN COALESCE(e.elasticity_label, 'unknown') = 'unknown' THEN 5
             ELSE 0 END +
        LEAST(10, sp.annual_volume / 50)
    ) ORDER BY 
        LEAST(40, sp.annual_revenue / 100) +
        LEAST(30, CASE WHEN sp.mode_price > 0 THEN 
          (sp.suggested_price - sp.mode_price) / sp.mode_price * 100 * 2 ELSE 0 END) +
        CASE WHEN COALESCE(e.elasticity_label, 'unknown') = 'inelastic' THEN 20
             WHEN COALESCE(e.elasticity_label, 'unknown') = 'moderate' THEN 10
             WHEN COALESCE(e.elasticity_label, 'unknown') = 'unknown' THEN 5
             ELSE 0 END +
        LEAST(10, sp.annual_volume / 50) DESC
    ), '[]'::jsonb)
    FROM std_service_prices sp
    LEFT JOIN (
      SELECT DISTINCT ON (service_code) service_code, elasticity_label, elasticity, confidence
      FROM std_elasticity WHERE clinic_id = p_clinic_id
      ORDER BY service_code, 
        CASE confidence WHEN 'high' THEN 3 WHEN 'medium' THEN 2 ELSE 1 END DESC,
        ABS(elasticity) ASC
    ) e ON e.service_code = sp.service_code
    WHERE sp.clinic_id = p_clinic_id
      AND sp.mode_price > 0
      AND sp.suggested_price > sp.mode_price  -- has inflation headroom
      -- Exclude services already being tested
      AND sp.service_code NOT IN (
        SELECT service_code FROM std_price_experiments 
        WHERE clinic_id = p_clinic_id AND status IN ('pending', 'running')
      )
    LIMIT p_limit
  );
END;
$_$;

-- ============================================================
-- 2. START: Create an experiment
-- Computes baseline from last 30 days, sets test price, records experiment
-- ============================================================

CREATE OR REPLACE FUNCTION start_experiment(
  p_clinic_id TEXT,
  p_service_code TEXT,
  p_change_pct NUMERIC DEFAULT 2,   -- percentage to change (e.g. 2 = +2%)
  p_direction TEXT DEFAULT 'up',
  p_experiment_type TEXT DEFAULT 'demand'
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $_$
DECLARE
  v_price RECORD;
  v_old_price NUMERIC;
  v_new_price NUMERIC;
  v_baseline_rev NUMERIC;
  v_baseline_vol INT;
  v_baseline_days INT;
  v_cutoff DATE;
  v_exp_id BIGINT;
BEGIN
  -- Get current price
  SELECT mode_price, description INTO v_price
  FROM std_service_prices
  WHERE clinic_id = p_clinic_id AND service_code = p_service_code;
  
  IF NOT FOUND THEN
    RETURN jsonb_build_object('error', 'service not found');
  END IF;

  v_old_price := v_price.mode_price;

  -- Calculate new price
  IF p_direction = 'up' THEN
    v_new_price := ROUND((v_old_price * (1 + p_change_pct / 100))::numeric, 2);
  ELSE
    v_new_price := ROUND((v_old_price * (1 - p_change_pct / 100))::numeric, 2);
  END IF;
  -- End in .99
  v_new_price := FLOOR(v_new_price) + 0.99;

  -- Check safety: max 10% from starting price (we don't have "original" price yet, 
  -- so for first experiment just ensure the change itself is reasonable)
  IF ABS((v_new_price - v_old_price) / v_old_price * 100) > 15 THEN
    RETURN jsonb_build_object('error', 'change exceeds 15% safety limit', 
      'old', v_old_price, 'new', v_new_price);
  END IF;

  -- Compute baseline (last 30 days of data)
  SELECT MAX(txn_date) - INTERVAL '30 days' INTO v_cutoff
  FROM std_transactions WHERE clinic_id = p_clinic_id;

  SELECT 
    COALESCE(SUM(amount), 0),
    COUNT(*),
    COUNT(DISTINCT txn_date::date)
  INTO v_baseline_rev, v_baseline_vol, v_baseline_days
  FROM std_transactions
  WHERE clinic_id = p_clinic_id
    AND service_code = p_service_code
    AND txn_date >= v_cutoff
    AND amount > 0;

  -- Create experiment
  INSERT INTO std_price_experiments (
    clinic_id, service_code, experiment_type,
    old_price, test_price, change_pct, direction,
    start_date, status,
    baseline_revenue, baseline_volume, baseline_days
  ) VALUES (
    p_clinic_id, p_service_code, p_experiment_type,
    v_old_price, v_new_price, p_change_pct, p_direction,
    CURRENT_DATE, 'running',
    v_baseline_rev, v_baseline_vol, v_baseline_days
  )
  RETURNING id INTO v_exp_id;

  -- Log to history
  INSERT INTO std_experiment_history (experiment_id, action, details)
  VALUES (v_exp_id, 'started', jsonb_build_object(
    'old_price', v_old_price,
    'test_price', v_new_price,
    'change_pct', p_change_pct,
    'direction', p_direction,
    'baseline_revenue', v_baseline_rev,
    'baseline_volume', v_baseline_vol,
    'baseline_days', v_baseline_days,
    'baseline_daily_rev', CASE WHEN v_baseline_days > 0 THEN v_baseline_rev / v_baseline_days ELSE 0 END,
    'baseline_daily_vol', CASE WHEN v_baseline_days > 0 THEN v_baseline_vol::numeric / v_baseline_days ELSE 0 END
  ));

  RETURN jsonb_build_object(
    'experiment_id', v_exp_id,
    'service_code', p_service_code,
    'old_price', v_old_price,
    'test_price', v_new_price,
    'change_pct', p_change_pct,
    'direction', p_direction,
    'baseline_revenue', v_baseline_rev,
    'baseline_volume', v_baseline_vol,
    'baseline_days', v_baseline_days
  );
END;
$_$;

-- ============================================================
-- 3. MEASURE: Evaluate running experiments
-- Checks if enough time has passed, computes results, makes decision
-- ============================================================

CREATE OR REPLACE FUNCTION measure_experiment(p_experiment_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $_$
DECLARE
  v_exp RECORD;
  v_test_rev NUMERIC;
  v_test_vol INT;
  v_test_days INT;
  v_rev_change_pct NUMERIC;
  v_vol_change_pct NUMERIC;
  v_net_change NUMERIC;
  v_decision TEXT;
  v_reason TEXT;
  v_cutoff DATE;
BEGIN
  SELECT * INTO v_exp FROM std_price_experiments WHERE id = p_experiment_id;
  
  IF NOT FOUND THEN
    RETURN jsonb_build_object('error', 'experiment not found');
  END IF;

  IF v_exp.status != 'running' THEN
    RETURN jsonb_build_object('error', 'experiment not running', 'status', v_exp.status);
  END IF;

  -- Need at least 7 days of data since start
  IF CURRENT_DATE - v_exp.start_date < 7 THEN
    RETURN jsonb_build_object('status', 'too_early', 'days_elapsed', CURRENT_DATE - v_exp.start_date);
  END IF;

  -- Measure test period (from start_date to now or data max)
  SELECT MAX(txn_date) INTO v_cutoff
  FROM std_transactions WHERE clinic_id = v_exp.clinic_id;

  SELECT 
    COALESCE(SUM(amount), 0),
    COUNT(*),
    COUNT(DISTINCT txn_date::date)
  INTO v_test_rev, v_test_vol, v_test_days
  FROM std_transactions
  WHERE clinic_id = v_exp.clinic_id
    AND service_code = v_exp.service_code
    AND txn_date >= v_exp.start_date
    AND txn_date <= COALESCE(v_cutoff, CURRENT_DATE)
    AND amount > 0;

  -- Need at least 5 active days to measure
  IF v_test_days < 5 THEN
    RETURN jsonb_build_object('status', 'insufficient_data', 'test_days', v_test_days);
  END IF;

  -- Calculate changes (using daily rates)
  v_rev_change_pct := CASE WHEN v_exp.baseline_days > 0 AND v_exp.baseline_revenue > 0 THEN
    ROUND(((v_test_rev::numeric / v_test_days) - (v_exp.baseline_revenue / v_exp.baseline_days)) 
      / (v_exp.baseline_revenue / v_exp.baseline_days) * 100, 1)
  ELSE NULL END;

  v_vol_change_pct := CASE WHEN v_exp.baseline_days > 0 AND v_exp.baseline_volume > 0 THEN
    ROUND(((v_test_vol::numeric / v_test_days) - (v_exp.baseline_volume::numeric / v_exp.baseline_days))
      / (v_exp.baseline_volume::numeric / v_exp.baseline_days) * 100, 1)
  ELSE NULL END;

  v_net_change := v_test_rev - (v_exp.baseline_revenue / v_exp.baseline_days * v_test_days);

  -- Decision matrix
  IF v_rev_change_pct IS NULL OR v_vol_change_pct IS NULL THEN
    v_decision := 'review';
    v_reason := 'insufficient baseline data';
  ELSIF v_vol_change_pct < -15 THEN
    v_decision := 'revert';
    v_reason := 'volume dropped significantly (>15%)';
  ELSIF v_rev_change_pct > 0 AND v_vol_change_pct >= -5 THEN
    v_decision := 'push';
    v_reason := 'revenue up while volume stable';
  ELSIF v_rev_change_pct > 0 AND v_vol_change_pct < -5 THEN
    v_decision := 'hold';
    v_reason := 'revenue up but volume dropped slightly — net positive but monitor';
  ELSIF v_rev_change_pct <= 0 THEN
    v_decision := 'revert';
    v_reason := 'revenue did not increase';
  ELSE
    v_decision := 'review';
    v_reason := 'ambiguous results — manual review needed';
  END IF;

  -- Update experiment
  UPDATE std_price_experiments SET
    test_revenue = v_test_rev,
    test_volume = v_test_vol,
    test_days = v_test_days,
    revenue_change_pct = v_rev_change_pct,
    volume_change_pct = v_vol_change_pct,
    net_revenue_change = v_net_change,
    decision = v_decision,
    decision_reason = v_reason,
    decided_at = NOW(),
    end_date = CURRENT_DATE,
    status = CASE WHEN v_decision = 'push' THEN 'pushed' ELSE 'concluded' END
  WHERE id = p_experiment_id;

  -- Log to history
  INSERT INTO std_experiment_history (experiment_id, action, details)
  VALUES (p_experiment_id, 'measured', jsonb_build_object(
    'test_revenue', v_test_rev,
    'test_volume', v_test_vol,
    'test_days', v_test_days,
    'revenue_change_pct', v_rev_change_pct,
    'volume_change_pct', v_vol_change_pct,
    'net_revenue_change', v_net_change,
    'decision', v_decision,
    'reason', v_reason
  ));

  RETURN jsonb_build_object(
    'experiment_id', p_experiment_id,
    'service_code', v_exp.service_code,
    'old_price', v_exp.old_price,
    'test_price', v_exp.test_price,
    'revenue_change_pct', v_rev_change_pct,
    'volume_change_pct', v_vol_change_pct,
    'net_revenue_change', v_net_change,
    'decision', v_decision,
    'reason', v_reason
  );
END;
$_$;

-- ============================================================
-- 4. RUN ENGINE CYCLE: Process all running experiments
-- Called daily by cron. Measures experiments with enough data,
-- starts new ones if under the concurrent limit.
-- ============================================================

CREATE OR REPLACE FUNCTION run_engine_cycle(p_clinic_id TEXT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $_$
DECLARE
  v_running INT;
  v_max_concurrent INT := 20;
  v_measured INT := 0;
  v_started INT := 0;
  v_errors INT := 0;
  exp RECORD;
  pick_result JSONB;
  start_result JSONB;
  measure_result JSONB;
  to_start RECORD;
BEGIN
  -- Measure all running experiments that have enough data
  FOR exp IN 
    SELECT id, service_code FROM std_price_experiments
    WHERE clinic_id = p_clinic_id AND status = 'running'
      AND CURRENT_DATE - start_date >= 7
  LOOP
    SELECT measure_experiment(exp.id) INTO measure_result;
    IF measure_result ? 'error' THEN
      v_errors := v_errors + 1;
    ELSE
      v_measured := v_measured + 1;
    END IF;
  END LOOP;

  -- Count currently running
  SELECT COUNT(*) INTO v_running
  FROM std_price_experiments
  WHERE clinic_id = p_clinic_id AND status IN ('running', 'pending');

  -- Start new experiments if under limit
  IF v_running < v_max_concurrent THEN
    pick_result := pick_experiments(p_clinic_id, v_max_concurrent - v_running);
    
    FOR to_start IN SELECT * FROM jsonb_to_recordset(pick_result) 
      AS x(service_code TEXT, current_price NUMERIC, elasticity_label TEXT, headroom_pct NUMERIC)
    LOOP
      EXIT WHEN v_running + v_started >= v_max_concurrent;
      
      -- Start with small nudge: 2% up for inelastic, 1% for moderate/unknown
      IF to_start.elasticity_label = 'inelastic' THEN
        SELECT start_experiment(p_clinic_id, to_start.service_code, 3, 'up', 'demand') INTO start_result;
      ELSIF to_start.elasticity_label = 'moderate' THEN
        SELECT start_experiment(p_clinic_id, to_start.service_code, 2, 'up', 'demand') INTO start_result;
      ELSE
        SELECT start_experiment(p_clinic_id, to_start.service_code, 1, 'up', 'demand') INTO start_result;
      END IF;

      IF start_result ? 'error' THEN
        v_errors := v_errors + 1;
      ELSE
        v_started := v_started + 1;
      END IF;
    END LOOP;
  END IF;

  RETURN jsonb_build_object(
    'clinic_id', p_clinic_id,
    'measured', v_measured,
    'started', v_started,
    'errors', v_errors,
    'currently_running', (SELECT COUNT(*) FROM std_price_experiments WHERE clinic_id = p_clinic_id AND status IN ('running','pending')),
    'total_concluded', (SELECT COUNT(*) FROM std_price_experiments WHERE clinic_id = p_clinic_id AND status IN ('concluded','reverted','pushed'))
  );
END;
$_$;
