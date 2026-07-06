-- Simplify measure_experiment: remove downstream check, keep clinic growth + seasonal
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
  v_clinic_growth NUMERIC;
  v_adj_vol_change NUMERIC;
  v_seasonal_adj NUMERIC;
  v_net_change NUMERIC;
  v_decision TEXT;
  v_reason TEXT;
  v_cutoff DATE;
  v_month_of_year INT;
BEGIN
  SELECT * INTO v_exp FROM std_price_experiments WHERE id = p_experiment_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('error', 'not found'); END IF;
  IF v_exp.status != 'running' THEN RETURN jsonb_build_object('error', 'not running'); END IF;
  IF CURRENT_DATE - v_exp.start_date < 7 THEN
    RETURN jsonb_build_object('status', 'too_early', 'days', CURRENT_DATE - v_exp.start_date);
  END IF;

  SELECT MAX(txn_date) INTO v_cutoff FROM std_transactions WHERE clinic_id = v_exp.clinic_id;

  SELECT COALESCE(SUM(amount), 0), COUNT(*), COUNT(DISTINCT txn_date::date)
  INTO v_test_rev, v_test_vol, v_test_days
  FROM std_transactions
  WHERE clinic_id = v_exp.clinic_id AND service_code = v_exp.service_code
    AND txn_date >= v_exp.start_date AND txn_date <= COALESCE(v_cutoff, CURRENT_DATE) AND amount > 0;

  IF v_test_days < 5 THEN
    RETURN jsonb_build_object('status', 'insufficient_data', 'days', v_test_days);
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

  -- Seasonal adjustment
  v_month_of_year := EXTRACT(MONTH FROM v_exp.start_date)::int;
  SELECT CASE WHEN seasonal_volatility > 0.2 AND low_month = v_month_of_year THEN -seasonal_volatility * 20
              WHEN seasonal_volatility > 0.2 AND peak_month = v_month_of_year THEN seasonal_volatility * 20
              ELSE 0 END
  INTO v_seasonal_adj
  FROM std_service_metrics WHERE clinic_id = v_exp.clinic_id AND service_code = v_exp.service_code;

  v_adj_vol_change := CASE WHEN v_vol_change_pct IS NOT NULL THEN
    v_vol_change_pct - COALESCE(v_clinic_growth, 0) - COALESCE(v_seasonal_adj, 0) END;

  v_net_change := v_test_rev - (v_exp.baseline_revenue / NULLIF(v_exp.baseline_days, 0) * v_test_days);

  -- DECISION (no downstream check)
  IF v_vol_change_pct IS NULL THEN
    v_decision := 'review'; v_reason := 'insufficient baseline data';
  ELSIF v_adj_vol_change < -15 THEN
    v_decision := 'revert';
    v_reason := 'adjusted volume ' || ROUND(v_adj_vol_change::numeric,1) || '% (clinic: ' || ROUND(COALESCE(v_clinic_growth,0)::numeric,1) || '%, seasonal: ' || ROUND(COALESCE(v_seasonal_adj,0)::numeric,1) || '%)';
  ELSIF v_rev_change_pct > 3 AND v_adj_vol_change >= -5 THEN
    v_decision := 'push';
    v_reason := 'revenue +' || ROUND(v_rev_change_pct::numeric,1) || '%, adjusted volume ' || ROUND(v_adj_vol_change::numeric,1) || '%';
  ELSIF v_rev_change_pct > 0 AND v_adj_vol_change >= -15 THEN
    v_decision := 'hold';
    v_reason := 'revenue +' || ROUND(v_rev_change_pct::numeric,1) || '% but volume ' || ROUND(v_adj_vol_change::numeric,1) || '% — monitor';
  ELSIF v_rev_change_pct <= 0 THEN
    v_decision := 'revert';
    v_reason := 'revenue ' || ROUND(v_rev_change_pct::numeric,1) || '%, adjusted volume ' || ROUND(v_adj_vol_change::numeric,1) || '%';
  ELSIF v_adj_vol_change >= 0 THEN
    v_decision := 'push';
    v_reason := 'adjusted volume stable at ' || ROUND(v_adj_vol_change::numeric,1) || '%';
  ELSE
    v_decision := 'review';
    v_reason := 'ambiguous — rev ' || COALESCE(ROUND(v_rev_change_pct::numeric,1)::text,'?') || '%, adj vol ' || COALESCE(ROUND(v_adj_vol_change::numeric,1)::text,'?') || '%';
  END IF;

  UPDATE std_price_experiments SET
    test_revenue = v_test_rev, test_volume = v_test_vol, test_days = v_test_days,
    revenue_change_pct = ROUND(v_rev_change_pct::numeric, 1),
    volume_change_pct = ROUND(v_vol_change_pct::numeric, 1),
    net_revenue_change = v_net_change,
    decision = v_decision, decision_reason = v_reason,
    decided_at = NOW(), end_date = CURRENT_DATE,
    status = CASE WHEN v_decision = 'push' THEN 'pushed' ELSE 'concluded' END
  WHERE id = p_experiment_id;

  INSERT INTO std_experiment_history (experiment_id, action, details)
  VALUES (p_experiment_id, 'measured', jsonb_build_object(
    'test_revenue', v_test_rev, 'test_volume', v_test_vol, 'test_days', v_test_days,
    'revenue_change_pct', ROUND(v_rev_change_pct::numeric, 1),
    'raw_volume_change', ROUND(v_vol_change_pct::numeric, 1),
    'clinic_growth_pct', ROUND(COALESCE(v_clinic_growth,0)::numeric, 1),
    'seasonal_adj', ROUND(COALESCE(v_seasonal_adj,0)::numeric, 1),
    'adjusted_volume_change', ROUND(v_adj_vol_change::numeric, 1),
    'decision', v_decision, 'reason', v_reason
  ));

  RETURN jsonb_build_object(
    'experiment_id', p_experiment_id,
    'service_code', v_exp.service_code,
    'revenue_change_pct', ROUND(v_rev_change_pct::numeric, 1),
    'raw_volume_change', ROUND(v_vol_change_pct::numeric, 1),
    'clinic_growth', ROUND(COALESCE(v_clinic_growth,0)::numeric, 1),
    'seasonal_adj', ROUND(COALESCE(v_seasonal_adj,0)::numeric, 1),
    'adjusted_volume_change', ROUND(v_adj_vol_change::numeric, 1),
    'decision', v_decision, 'reason', v_reason
  );
END;
$_$;
