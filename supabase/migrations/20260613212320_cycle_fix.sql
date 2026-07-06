-- Fix run_engine_cycle_v2: handle jsonb iteration properly
CREATE OR REPLACE FUNCTION run_engine_cycle_v2(p_clinic_id TEXT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $_$
DECLARE
  v_settings RECORD;
  v_measured INT := 0;
  v_started INT := 0;
  v_errors INT := 0;
  v_skipped_cooldown INT := 0;
  v_exp RECORD;
  v_result JSONB;
  v_active INT;
  v_new_this_week INT;
  v_candidates JSONB;
  v_cand JSONB;
  v_candidate_code TEXT;
  v_total_uplift NUMERIC := 0;
BEGIN
  SELECT * INTO v_settings FROM std_engine_settings WHERE clinic_id = p_clinic_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('error', 'no settings — call engine_init first');
  END IF;

  IF v_settings.status = 'paused' THEN
    RETURN jsonb_build_object('action', 'skipped', 'reason', 'engine_paused');
  END IF;

  -- === PHASE A: MEASURE ===
  FOR v_exp IN
    SELECT id, service_code FROM std_price_experiments
    WHERE clinic_id = p_clinic_id AND status = 'running'
      AND start_date <= CURRENT_DATE - v_settings.min_days_before_measure
    LOOP
      SELECT measure_experiment(v_exp.id) INTO v_result;
      IF v_result ? 'decision' THEN
        v_measured := v_measured + 1;
      END IF;
    END LOOP;

  -- === PHASE B: START new (staggered) ===
  SELECT COUNT(*) INTO v_active FROM std_price_experiments
  WHERE clinic_id = p_clinic_id AND status = 'running';

  SELECT COUNT(*) INTO v_new_this_week FROM std_price_experiments
  WHERE clinic_id = p_clinic_id
    AND start_date >= CURRENT_DATE - (EXTRACT(DOW FROM CURRENT_DATE)::INT);

  SELECT evaluate_all_services(p_clinic_id) INTO v_candidates;

  FOR v_cand IN SELECT * FROM jsonb_array_elements(v_candidates -> 'top_test')
  LOOP
    EXIT WHEN v_active >= v_settings.max_concurrent;
    EXIT WHEN v_new_this_week >= v_settings.max_new_per_week;

    v_candidate_code := v_cand ->> 'service_code';

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
    'cycle_date', CURRENT_DATE
  );
END;
$_$;
