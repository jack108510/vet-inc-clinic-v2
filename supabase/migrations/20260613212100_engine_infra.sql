-- Engine Settings + Kill Switch + Staggered Cycle

-- =====================================================
-- 1. ENGINE SETTINGS TABLE (kill switch, limits, mode)
-- =====================================================
CREATE TABLE IF NOT EXISTS std_engine_settings (
  clinic_id TEXT PRIMARY KEY,
  mode TEXT DEFAULT 'manual',  -- manual (human approves each nudge) | auto (engine decides)
  status TEXT DEFAULT 'paused', -- running | paused (kill switch)
  max_concurrent INT DEFAULT 20,
  max_new_per_week INT DEFAULT 5,  -- stagger: only start N new experiments per week
  max_total_change_pct NUMERIC DEFAULT 10,  -- max % from starting price
  min_days_before_measure INT DEFAULT 7,
  min_transaction_days INT DEFAULT 5,
  weekly_digest_day INT DEFAULT 1,  -- 0=Sun, 1=Mon...
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Default settings for rosslyn
INSERT INTO std_engine_settings (clinic_id, mode, status)
VALUES ('rosslyn', 'manual', 'paused')
ON CONFLICT (clinic_id) DO NOTHING;

-- =====================================================
-- 2. KILL SWITCH FUNCTIONS
-- =====================================================
CREATE OR REPLACE FUNCTION engine_pause(p_clinic_id TEXT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $_$
DECLARE
  v_running INT;
BEGIN
  UPDATE std_engine_settings SET status = 'paused', updated_at = NOW()
  WHERE clinic_id = p_clinic_id;

  -- Freeze all running experiments (don't conclude, just mark as frozen)
  SELECT COUNT(*) INTO v_running FROM std_price_experiments
  WHERE clinic_id = p_clinic_id AND status = 'running';

  RETURN jsonb_build_object(
    'action', 'paused',
    'frozen_experiments', v_running,
    'message', 'Engine paused. ' || v_running || ' experiments frozen (not concluded — will resume when engine resumes).'
  );
END;
$_$;

CREATE OR REPLACE FUNCTION engine_resume(p_clinic_id TEXT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $_$
BEGIN
  UPDATE std_engine_settings SET status = 'running', updated_at = NOW()
  WHERE clinic_id = p_clinic_id;

  RETURN jsonb_build_object('action', 'resumed', 'message', 'Engine running. Frozen experiments resume measurement.');
END;
$_$;

-- =====================================================
-- 3. STAGGERED CYCLE — respects cooldowns, limits, kill switch
-- =====================================================
CREATE OR REPLACE FUNCTION run_engine_cycle_v2(p_clinic_id TEXT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $_$
DECLARE
  v_settings RECORD;
  v_measured INT := 0;
  v_started INT := 0;
  v_errors INT := 0;
  v_skipped_cooldown INT := 0;
  v_skipped_max INT := 0;
  v_exp RECORD;
  v_result JSONB;
  v_active INT;
  v_new_this_week INT;
  v_candidates JSONB;
  v_cand RECORD;
  v_candidate_code TEXT;
  v_total_uplift NUMERIC := 0;
BEGIN
  -- Load settings
  SELECT * INTO v_settings FROM std_engine_settings WHERE clinic_id = p_clinic_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('error', 'no settings — call engine_init first');
  END IF;

  -- Kill switch check
  IF v_settings.status = 'paused' THEN
    RETURN jsonb_build_object('action', 'skipped', 'reason', 'engine_paused');
  END IF;

  -- === PHASE A: MEASURE existing experiments ===
  FOR v_exp IN
    SELECT id, service_code FROM std_price_experiments
    WHERE clinic_id = p_clinic_id AND status = 'running'
      AND start_date <= CURRENT_DATE - v_settings.min_days_before_measure
    LOOP
      SELECT measure_experiment(v_exp.id) INTO v_result;
      IF v_result ? 'decision' THEN
        v_measured := v_measured + 1;
        IF (v_result ->> 'decision') IN ('pushed') THEN
          v_total_uplift := v_total_uplift + COALESCE(((v_result ->> 'net_revenue_change')::NUMERIC), 0);
        END IF;
      END IF;
    END LOOP;

  -- === PHASE B: START new experiments (staggered) ===
  -- Count currently active
  SELECT COUNT(*) INTO v_active FROM std_price_experiments
  WHERE clinic_id = p_clinic_id AND status = 'running';

  -- Count started this week
  SELECT COUNT(*) INTO v_new_this_week FROM std_price_experiments
  WHERE clinic_id = p_clinic_id
    AND start_date >= CURRENT_DATE - (EXTRACT(DOW FROM CURRENT_DATE)::INT);

  -- Pick candidates
  SELECT evaluate_all_services(p_clinic_id) INTO v_candidates;
  FOR v_cand IN SELECT * FROM jsonb_array_elements(v_candidates -> 'top_test') LOOP
    EXIT WHEN v_active >= v_settings.max_concurrent;
    EXIT WHEN v_new_this_week >= v_settings.max_new_per_week;

    v_candidate_code := v_cand ->> 'service_code';

    -- Try to start
    SELECT start_experiment_v2(p_clinic_id, v_candidate_code) INTO v_result;

    IF v_result ? 'experiment_id' THEN
      v_started := v_started + 1;
      v_active := v_active + 1;
      v_new_this_week := v_new_this_week + 1;
    ELSIF v_result ->> 'error' = 'phase1_cooldown' THEN
      v_skipped_cooldown := v_skipped_cooldown + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'clinic_id', p_clinic_id,
    'measured', v_measured,
    'started', v_started,
    'skipped_cooldown', v_skipped_cooldown,
    'active_experiments', v_active,
    'captured_uplift', ROUND(v_total_uplift::NUMERIC, 2),
    'cycle_date', CURRENT_DATE
  );
END;
$_$;

-- =====================================================
-- 4. WEEKLY DIGEST — what the engine did this week
-- =====================================================
CREATE OR REPLACE FUNCTION engine_weekly_digest(p_clinic_id TEXT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $_$
DECLARE
  v_pushed INT;
  v_reverted INT;
  v_held INT;
  v_reviewed INT;
  v_started INT;
  v_uplift NUMERIC := 0;
  v_active INT;
  v_total_adjustments INT;
BEGIN
  SELECT COUNT(*) FILTER (WHERE decision = 'pushed')
       , COUNT(*) FILTER (WHERE decision = 'revert')
       , COUNT(*) FILTER (WHERE decision = 'hold')
       , COUNT(*) FILTER (WHERE decision = 'review')
    INTO v_pushed, v_reverted, v_held, v_reviewed
  FROM std_price_experiments
  WHERE clinic_id = p_clinic_id
    AND decided_at >= CURRENT_DATE - 7;

  SELECT COUNT(*) INTO v_started
  FROM std_price_experiments
  WHERE clinic_id = p_clinic_id AND start_date >= CURRENT_DATE - 7;

  SELECT COUNT(*), COALESCE(SUM(net_revenue_change), 0) INTO v_total_adjustments, v_uplift
  FROM std_price_experiments
  WHERE clinic_id = p_clinic_id
    AND decided_at >= CURRENT_DATE - 7
    AND decision = 'pushed';

  SELECT COUNT(*) INTO v_active
  FROM std_price_experiments
  WHERE clinic_id = p_clinic_id AND status = 'running';

  RETURN jsonb_build_object(
    'week_ending', CURRENT_DATE,
    'experiments_started', v_started,
    'pushed', v_pushed,
    'reverted', v_reverted,
    'held', v_held,
    'review', v_reviewed,
    'active_now', v_active,
    'captured_uplift_7d', ROUND(v_uplift::NUMERIC, 2),
    'total_price_adjustments', v_total_adjustments
  );
END;
$_$;

-- =====================================================
-- 5. ENGINE INIT — set up a clinic for the engine
-- =====================================================
CREATE OR REPLACE FUNCTION engine_init(
  p_clinic_id TEXT,
  p_mode TEXT DEFAULT 'manual',
  p_max_concurrent INT DEFAULT 20,
  p_max_new_per_week INT DEFAULT 5
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $_$
BEGIN
  INSERT INTO std_engine_settings (clinic_id, mode, status, max_concurrent, max_new_per_week)
  VALUES (p_clinic_id, p_mode, 'paused', p_max_concurrent, p_max_new_per_week)
  ON CONFLICT (clinic_id) DO UPDATE
  SET mode = EXCLUDED.mode,
      max_concurrent = EXCLUDED.max_concurrent,
      max_new_per_week = EXCLUDED.max_new_per_week,
      updated_at = NOW();

  RETURN jsonb_build_object(
    'clinic_id', p_clinic_id,
    'mode', p_mode,
    'status', 'paused',
    'max_concurrent', p_max_concurrent,
    'max_new_per_week', p_max_new_per_week,
    'message', 'Engine initialized. Use engine_resume() to start.'
  );
END;
$_$;
