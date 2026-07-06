-- Insights Inbox: surfaces engine decisions for human attention
CREATE OR REPLACE FUNCTION get_insights(p_clinic_id TEXT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $_$
DECLARE
  v_insights JSONB[];
  v_item JSONB;
BEGIN
  -- 1. PHASE 1 ALERTS (price change backfired)
  FOR v_item IN
    SELECT jsonb_build_object(
      'type', 'phase1_alert',
      'priority', 'urgent',
      'icon', '🚨',
      'title', e.service_code || ' — Phase 1 change hurt demand',
      'detail', e.decision_reason,
      'experiment_id', e.id,
      'service_code', e.service_code,
      'old_price', e.old_price,
      'test_price', e.test_price,
      'change_pct', e.change_pct,
      'decided_at', e.decided_at,
      'actions', jsonb_build_array('revert_price', 'dismiss')
    )
    FROM std_price_experiments e
    WHERE e.clinic_id = p_clinic_id
      AND e.experiment_type = 'phase1'
      AND e.decision = 'alert'
    LOOP
      v_insights := array_append(v_insights, v_item);
    END LOOP;

  -- 2. PHASE 2 REVIEWS (ambiguous, needs human)
  FOR v_item IN
    SELECT jsonb_build_object(
      'type', 'engine_review',
      'priority', 'high',
      'icon', '🔍',
      'title', e.service_code || ' — Engine needs your call',
      'detail', e.decision_reason,
      'experiment_id', e.id,
      'service_code', e.service_code,
      'old_price', e.old_price,
      'test_price', e.test_price,
      'decided_at', e.decided_at,
      'actions', jsonb_build_array('keep_price', 'revert_price', 'dismiss')
    )
    FROM std_price_experiments e
    WHERE e.clinic_id = p_clinic_id
      AND e.experiment_type = 'demand'
      AND e.decision = 'review'
    LOOP
      v_insights := array_append(v_insights, v_item);
    END LOOP;

  -- 3. PHASE 2 REVERTS (engine rolled back)
  FOR v_item IN
    SELECT jsonb_build_object(
      'type', 'engine_revert',
      'priority', 'medium',
      'icon', '↩️',
      'title', e.service_code || ' — Engine reverted price',
      'detail', e.decision_reason,
      'experiment_id', e.id,
      'service_code', e.service_code,
      'old_price', e.old_price,
      'test_price', e.test_price,
      'decided_at', e.decided_at,
      'actions', jsonb_build_array('dismiss')
    )
    FROM std_price_experiments e
    WHERE e.clinic_id = p_clinic_id
      AND e.experiment_type = 'demand'
      AND e.decision = 'revert'
      AND e.decided_at >= NOW() - INTERVAL '7 days'
    LOOP
      v_insights := array_append(v_insights, v_item);
    END LOOP;

  -- 4. SUCCESSES (engine or phase 1 worked)
  FOR v_item IN
    SELECT jsonb_build_object(
      'type', 'success',
      'priority', 'low',
      'icon', '✅',
      'title', e.service_code || ' — ' ||
        CASE WHEN e.experiment_type = 'phase1' THEN 'Phase 1 change working' ELSE 'Engine push successful' END,
      'detail', e.decision_reason,
      'experiment_id', e.id,
      'service_code', e.service_code,
      'revenue_change_pct', e.revenue_change_pct,
      'decided_at', e.decided_at,
      'actions', jsonb_build_array('dismiss')
    )
    FROM std_price_experiments e
    WHERE e.clinic_id = p_clinic_id
      AND e.decision IN ('success', 'pushed')
      AND e.decided_at >= NOW() - INTERVAL '7 days'
    LOOP
      v_insights := array_append(v_insights, v_item);
    END LOOP;

  -- 5. MONITORING (watch list)
  FOR v_item IN
    SELECT jsonb_build_object(
      'type', 'monitor',
      'priority', 'low',
      'icon', '⚠️',
      'title', e.service_code || ' — Watching volume',
      'detail', e.decision_reason,
      'experiment_id', e.id,
      'service_code', e.service_code,
      'revenue_change_pct', e.revenue_change_pct,
      'decided_at', e.decided_at,
      'actions', jsonb_build_array('dismiss')
    )
    FROM std_price_experiments e
    WHERE e.clinic_id = p_clinic_id
      AND e.decision IN ('monitor', 'hold')
      AND e.decided_at >= NOW() - INTERVAL '7 days'
    LOOP
      v_insights := array_append(v_insights, v_item);
    END LOOP;

  RETURN jsonb_build_object(
    'insights', to_jsonb(COALESCE(v_insights, ARRAY[]::JSONB[])),
    'total', COALESCE(array_length(v_insights, 1), 0)
  );
END;
$_$;

-- Action functions for inbox
CREATE OR REPLACE FUNCTION insight_dismiss(p_experiment_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $_$
BEGIN
  -- Mark as dismissed by adding to history
  INSERT INTO std_experiment_history (experiment_id, action, details)
  VALUES (p_experiment_id, 'insight_dismissed', jsonb_build_object('dismissed_at', NOW()));
  RETURN jsonb_build_object('dismissed', p_experiment_id);
END;
$_$;

CREATE OR REPLACE FUNCTION insight_revert_price(p_experiment_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $_$
DECLARE
  v_exp RECORD;
BEGIN
  SELECT * INTO v_exp FROM std_price_experiments WHERE id = p_experiment_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('error', 'not found'); END IF;

  -- Revert the price in std_service_prices back to old_price
  UPDATE std_service_prices
  SET current_price = v_exp.old_price, updated_at = NOW()
  WHERE clinic_id = v_exp.clinic_id AND service_code = v_exp.service_code;

  -- Log
  INSERT INTO std_experiment_history (experiment_id, action, details)
  VALUES (p_experiment_id, 'manual_revert',
    jsonb_build_object('reverted_from', v_exp.test_price, 'reverted_to', v_exp.old_price, 'by', 'owner'));

  RETURN jsonb_build_object(
    'reverted', v_exp.service_code,
    'price_restored', v_exp.old_price
  );
END;
$_$;

CREATE OR REPLACE FUNCTION insight_keep_price(p_experiment_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $_$
DECLARE
  v_exp RECORD;
BEGIN
  SELECT * INTO v_exp FROM std_price_experiments WHERE id = p_experiment_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('error', 'not found'); END IF;

  -- Mark as owner-approved
  INSERT INTO std_experiment_history (experiment_id, action, details)
  VALUES (p_experiment_id, 'manual_keep',
    jsonb_build_object('price_kept', v_exp.test_price, 'by', 'owner'));

  RETURN jsonb_build_object(
    'kept', v_exp.service_code,
    'price', v_exp.test_price
  );
END;
$_$;
