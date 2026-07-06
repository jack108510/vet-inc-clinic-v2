-- ============================================================
-- THE BRAIN: Smart decision engine using all data points
-- ============================================================

CREATE OR REPLACE FUNCTION evaluate_all_services(p_clinic_id TEXT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $_$
DECLARE
  result JSONB;
BEGIN
  WITH service_data AS (
    SELECT 
      sp.service_code,
      sp.service_name,
      sp.current_price,
      sp.price_set_date,
      sp.annual_revenue,
      sp.annual_volume,
      sp.total_transactions,
      sp.last_charged_date,
      sp.category,
      (CURRENT_DATE - sp.price_set_date) AS days_at_price,
      -- Inflation gap
      aq.suggested_price AS inflation_target,
      CASE WHEN sp.current_price > 0 AND aq.suggested_price IS NOT NULL THEN
        (aq.suggested_price - sp.current_price) / sp.current_price * 100
      ELSE NULL END AS inflation_gap_pct,
      -- .99 compliance
      CASE WHEN sp.current_price = FLOOR(sp.current_price) + 0.99 THEN true ELSE false END AS is_99,
      -- Volume trend (90d vs prior 90d)
      vol_trend.trend_pct,
      -- Adjusted elasticity
      el.adj_elasticity,
      el.adj_label AS elasticity_label,
      el.el_confidence,
      el.el_days,
      -- Deep metrics
      sm.avg_items_per_visit,
      sm.downstream_multiplier,
      sm.top_co_purchased,
      sm.revenue_trend_90d,
      sm.revenue_trend_30d,
      sm.peak_month,
      sm.low_month,
      sm.seasonal_volatility,
      sm.price_changes_count,
      sm.avg_years_between_changes,
      sm.price_vs_median_peer,
      -- Measurability
      CASE WHEN sp.annual_volume >= 52 THEN 'high'
           WHEN sp.annual_volume >= 26 THEN 'medium'
           WHEN sp.annual_volume >= 12 THEN 'low'
           ELSE 'insufficient' END AS measurability,
      -- Revenue share
      sp.annual_revenue / NULLIF((SELECT SUM(annual_revenue) FROM std_service_prices WHERE clinic_id = p_clinic_id), 0) * 100 AS revenue_share,
      -- Current month (for seasonal timing)
      EXTRACT(MONTH FROM CURRENT_DATE)::int AS current_month
    FROM std_service_prices sp
    LEFT JOIN LATERAL (
      SELECT DISTINCT ON (service_code) service_code, suggested_price
      FROM std_approval_queue
      WHERE clinic_id = p_clinic_id AND strategy = 'inflation_catchup' AND status = 'pending'
      ORDER BY service_code, suggested_price DESC
    ) aq ON aq.service_code = sp.service_code
    LEFT JOIN LATERAL (
      WITH dates AS (SELECT MAX(txn_date) AS max_date FROM std_transactions WHERE clinic_id = p_clinic_id)
      SELECT CASE WHEN recent.cnt > 0 AND prior.cnt > 0 THEN
        (recent.cnt - prior.cnt)::numeric / prior.cnt * 100 ELSE NULL END AS trend_pct
      FROM dates,
      LATERAL (SELECT COUNT(*) AS cnt FROM std_transactions WHERE clinic_id = p_clinic_id AND service_code = sp.service_code AND amount > 0 AND txn_date >= max_date - INTERVAL '90 days') recent,
      LATERAL (SELECT COUNT(*) AS cnt FROM std_transactions WHERE clinic_id = p_clinic_id AND service_code = sp.service_code AND amount > 0 AND txn_date >= max_date - INTERVAL '180 days' AND txn_date < max_date - INTERVAL '90 days') prior
    ) vol_trend ON true
    LEFT JOIN LATERAL (
      SELECT adjusted_elasticity AS adj_elasticity, adjusted_label AS adj_label,
             confidence AS el_confidence, measured_days AS el_days
      FROM std_elasticity WHERE clinic_id = p_clinic_id AND service_code = sp.service_code
        AND adjusted_label IS NOT NULL AND adjusted_label != 'unknown'
      ORDER BY CASE confidence WHEN 'high' THEN 3 WHEN 'medium' THEN 2 ELSE 1 END DESC, measured_days DESC LIMIT 1
    ) el ON true
    LEFT JOIN std_service_metrics sm ON sm.clinic_id = p_clinic_id AND sm.service_code = sp.service_code
    WHERE sp.clinic_id = p_clinic_id AND sp.current_price > 0
  ),
  evaluated AS (
    SELECT *,
      -- ============================================================
      -- ACTION CLASSIFICATION
      -- ============================================================
      CASE 
        -- IGNORE: too small
        WHEN annual_revenue < 100 OR annual_volume < 5 THEN 'ignore'
        -- IGNORE: can't measure
        WHEN measurability = 'insufficient' THEN 'ignore'
        -- HOLD: already optimal (at or near inflation target)
        WHEN inflation_gap_pct IS NOT NULL AND inflation_gap_pct <= 2 THEN 'hold_optimal'
        -- HOLD: revenue declining fast — investigate first
        WHEN revenue_trend_90d IS NOT NULL AND revenue_trend_90d < -30 THEN 'hold_declining'
        -- WAIT: it's peak season — don't test during unusual volume
        WHEN peak_month = EXTRACT(MONTH FROM CURRENT_DATE)::int AND seasonal_volatility > 0.2 THEN 'wait_seasonal'
        -- WAIT: it's low season — baseline will be misleading
        WHEN low_month = EXTRACT(MONTH FROM CURRENT_DATE)::int AND seasonal_volatility > 0.2 THEN 'wait_seasonal'
        -- HOLD: price was changed very recently (< 60 days)
        WHEN days_at_price < 60 THEN 'hold_recent_change'
        -- TEST: elastic services with room — test very carefully
        WHEN elasticity_label = 'elastic' AND measurability IN ('high', 'medium') 
          AND (inflation_gap_pct IS NULL OR inflation_gap_pct > 2) THEN 'test_careful'
        -- TEST: has room and enough volume to measure
        WHEN measurability IN ('high', 'medium') AND (inflation_gap_pct IS NULL OR inflation_gap_pct > 2) THEN 'test'
        -- HOLD: low volume
        WHEN measurability = 'low' THEN 'hold_low_volume'
        ELSE 'hold'
      END AS action,

      -- ============================================================
      -- NUDGE SIZE — based on elasticity, confidence, and downstream impact
      -- ============================================================
      CASE
        -- Inelastic + high confidence = push harder
        WHEN elasticity_label = 'inelastic' AND el_confidence = 'high' THEN 4.0
        WHEN elasticity_label = 'inelastic' AND el_confidence = 'medium' THEN 3.0
        WHEN elasticity_label = 'inelastic' THEN 2.5
        -- Moderate
        WHEN elasticity_label = 'moderate' AND el_confidence IN ('high', 'medium') THEN 2.0
        WHEN elasticity_label = 'moderate' THEN 1.5
        -- Unknown — start very small
        WHEN elasticity_label IS NULL AND downstream_multiplier > 5 THEN 2.0
        WHEN elasticity_label IS NULL THEN 1.0
        -- Elastic — barely move
        WHEN elasticity_label = 'elastic' THEN 0.5
        ELSE 1.0
      END AS nudge_pct,

      -- ============================================================
      -- PRICE CEILING — max we'll ever push this service
      -- ============================================================
      CASE 
        WHEN inflation_target IS NOT NULL THEN LEAST(inflation_target, current_price * 1.10)
        ELSE current_price * 1.10
      END AS price_ceiling,

      -- ============================================================
      -- VOLUME FLOOR — revert trigger (adjusted for seasonality)
      -- ============================================================
      CASE 
        WHEN elasticity_label = 'inelastic' THEN 15.0
        WHEN elasticity_label = 'moderate' THEN 10.0
        WHEN elasticity_label IS NULL THEN 8.0
        ELSE 5.0
      END 
      -- Widen floor during high-volatility periods
      * CASE WHEN seasonal_volatility > 0.25 THEN 1.3 ELSE 1.0 END
      AS volume_floor_pct,

      -- ============================================================
      -- TIMING SCORE — when is the best month to test this?
      -- Higher = good time to test now
      -- ============================================================
      CASE 
        -- Low season = good time (baseline won't be inflated)
        WHEN EXTRACT(MONTH FROM CURRENT_DATE)::int = low_month THEN 1.0
        -- Peak season = bad time (everything looks good)
        WHEN EXTRACT(MONTH FROM CURRENT_DATE)::int = peak_month THEN 0.3
        -- Normal month
        ELSE 0.7
      END AS timing_score,

      -- ============================================================
      -- PRIORITY SCORE (0-100) — multi-factor
      -- ============================================================
      -- Revenue weight (max 25)
      LEAST(25, annual_revenue / 500) +
      -- Inflation gap (max 20)
      LEAST(20, COALESCE(inflation_gap_pct, 0)) +
      -- Elasticity safety (max 15)
      CASE elasticity_label 
        WHEN 'inelastic' THEN 15 
        WHEN 'moderate' THEN 10 
        ELSE 5 END +
      -- Measurability (max 15)
      CASE measurability 
        WHEN 'high' THEN 15 WHEN 'medium' THEN 10 WHEN 'low' THEN 5 ELSE 0 END +
      -- Price staleness (max 10)
      LEAST(10, COALESCE(days_at_price, 0) / 180.0 * 10) +
      -- Downstream value (max 10) — services that drive other purchases
      LEAST(10, COALESCE(downstream_multiplier, 1) * 2) +
      -- Revenue trend bonus (max 5) — growing services are safer to test
      CASE WHEN revenue_trend_90d IS NOT NULL AND revenue_trend_90d > 0 THEN 5 ELSE 0 END
      AS priority_score,

      -- ============================================================
      -- RISK ASSESSMENT
      -- ============================================================
      CASE 
        WHEN elasticity_label = 'elastic' AND downstream_multiplier > 5 THEN 'high'
        WHEN elasticity_label = 'elastic' THEN 'medium'
        WHEN elasticity_label IS NULL AND revenue_trend_90d IS NOT NULL AND revenue_trend_90d < -15 THEN 'medium'
        WHEN elasticity_label = 'moderate' AND el_confidence = 'low' THEN 'medium'
        ELSE 'low'
      END AS risk_level,

      -- ============================================================
      -- REASONING — human-readable explanation
      -- ============================================================
      CASE elasticity_label
        WHEN 'inelastic' THEN 'Demand stable through past price changes'
        WHEN 'moderate' THEN 'Some volume sensitivity detected'
        WHEN 'elastic' THEN 'Volume drops when price increases'
        ELSE 'No elasticity data — testing will establish baseline'
      END ||
      COALESCE(' | Downstream: ' || downstream_multiplier || 'x items/visit', '') ||
      COALESCE(' | Revenue trend: ' || ROUND(revenue_trend_90d::numeric, 1) || '% (90d)', '') ||
      CASE WHEN seasonal_volatility > 0.2 THEN ' | Seasonal — be careful with timing' ELSE '' END
      AS reasoning
    FROM service_data
  )
  SELECT jsonb_build_object(
    'total_services', COUNT(*),
    'test', COUNT(*) FILTER (WHERE action = 'test'),
    'test_careful', COUNT(*) FILTER (WHERE action = 'test_careful'),
    'hold_optimal', COUNT(*) FILTER (WHERE action = 'hold_optimal'),
    'hold_declining', COUNT(*) FILTER (WHERE action = 'hold_declining'),
    'hold_low_volume', COUNT(*) FILTER (WHERE action = 'hold_low_volume'),
    'hold_recent_change', COUNT(*) FILTER (WHERE action = 'hold_recent_change'),
    'wait_seasonal', COUNT(*) FILTER (WHERE action = 'wait_seasonal'),
    'ignore', COUNT(*) FILTER (WHERE action = 'ignore'),
    'total_testable_revenue', ROUND(SUM(annual_revenue) FILTER (WHERE action IN ('test', 'test_careful'))),
    'avg_priority', ROUND(AVG(priority_score) FILTER (WHERE action IN ('test', 'test_careful')), 1),
    'high_risk', COUNT(*) FILTER (WHERE risk_level = 'high' AND action IN ('test', 'test_careful')),
    'top_test', COALESCE(jsonb_agg(to_jsonb(e) ORDER BY e.priority_score DESC) FILTER (WHERE e.action IN ('test', 'test_careful')), '[]'::jsonb)
  )
  INTO result
  FROM evaluated e;

  RETURN result;
END;
$_$;

-- ============================================================
-- SMART MEASUREMENT — uses adjusted comparison
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
  v_clinic_growth NUMERIC;
  v_adj_vol_change NUMERIC;
  v_seasonal_adj NUMERIC;
  v_downstream_before NUMERIC;
  v_downstream_after NUMERIC;
  v_net_change NUMERIC;
  v_decision TEXT;
  v_reason TEXT;
  v_cutoff DATE;
  v_month_of_year INT;
  v_expected_seasonal_drop NUMERIC;
  v_exp_metrics RECORD;
BEGIN
  SELECT * INTO v_exp FROM std_price_experiments WHERE id = p_experiment_id;
  
  IF NOT FOUND THEN RETURN jsonb_build_object('error', 'not found'); END IF;
  IF v_exp.status != 'running' THEN RETURN jsonb_build_object('error', 'not running'); END IF;

  -- Need at least 7 days
  IF CURRENT_DATE - v_exp.start_date < 7 THEN
    RETURN jsonb_build_object('status', 'too_early', 'days', CURRENT_DATE - v_exp.start_date);
  END IF;

  SELECT MAX(txn_date) INTO v_cutoff
  FROM std_transactions WHERE clinic_id = v_exp.clinic_id;

  -- Test period
  SELECT COALESCE(SUM(amount), 0), COUNT(*), COUNT(DISTINCT txn_date::date)
  INTO v_test_rev, v_test_vol, v_test_days
  FROM std_transactions
  WHERE clinic_id = v_exp.clinic_id AND service_code = v_exp.service_code
    AND txn_date >= v_exp.start_date AND txn_date <= COALESCE(v_cutoff, CURRENT_DATE) AND amount > 0;

  IF v_test_days < 5 THEN
    RETURN jsonb_build_object('status', 'insufficient_data', 'days', v_test_days);
  END IF;

  -- Daily rates
  v_rev_change_pct := CASE WHEN v_exp.baseline_days > 0 AND v_exp.baseline_revenue > 0 THEN
    ((v_test_rev::numeric / v_test_days) - (v_exp.baseline_revenue / v_exp.baseline_days)) 
    / (v_exp.baseline_revenue / v_exp.baseline_days) * 100 END;

  v_vol_change_pct := CASE WHEN v_exp.baseline_days > 0 AND v_exp.baseline_volume > 0 THEN
    ((v_test_vol::numeric / v_test_days) - (v_exp.baseline_volume::numeric / v_exp.baseline_days))
    / (v_exp.baseline_volume::numeric / v_exp.baseline_days) * 100 END;

  -- Clinic growth during this period
  SELECT CASE WHEN AVG(avg_daily_volume) FILTER (WHERE month_date >= (v_exp.start_date - INTERVAL '30 days')::date) > 0 THEN
    (AVG(avg_daily_volume) FILTER (WHERE month_date >= v_exp.start_date) - 
     AVG(avg_daily_volume) FILTER (WHERE month_date >= (v_exp.start_date - INTERVAL '30 days')::date AND month_date < v_exp.start_date))
    / AVG(avg_daily_volume) FILTER (WHERE month_date >= (v_exp.start_date - INTERVAL '30 days')::date AND month_date < v_exp.start_date) * 100
  END INTO v_clinic_growth
  FROM std_clinic_baseline WHERE clinic_id = v_exp.clinic_id;

  -- Seasonal adjustment: is this service in its low season during the test?
  v_month_of_year := EXTRACT(MONTH FROM v_exp.start_date)::int;
  SELECT CASE WHEN seasonal_volatility > 0.2 AND low_month = v_month_of_year THEN
    -seasonal_volatility * 20  -- expect volume to be lower due to seasonality
  WHEN seasonal_volatility > 0.2 AND peak_month = v_month_of_year THEN
    seasonal_volatility * 20
  ELSE 0 END INTO v_seasonal_adj
  FROM std_service_metrics WHERE clinic_id = v_exp.clinic_id AND service_code = v_exp.service_code;

  -- Adjusted volume change (raw - clinic growth - seasonal effect)
  v_adj_vol_change := CASE WHEN v_vol_change_pct IS NOT NULL THEN
    v_vol_change_pct - COALESCE(v_clinic_growth, 0) - v_seasonal_adj END;

  -- Downstream check: did co-purchased services change?
  SELECT 
    COALESCE(AVG(items_before), 1),
    COALESCE(AVG(items_after), 1)
  INTO v_downstream_before, v_downstream_after
  FROM (
    SELECT 
      AVG(CASE WHEN t.txn_date < v_exp.start_date THEN cnt END) AS items_before,
      AVG(CASE WHEN t.txn_date >= v_exp.start_date THEN cnt END) AS items_after
    FROM (
      SELECT t1.txn_date, t1.txn_id, COUNT(DISTINCT t1.service_code) AS cnt
      FROM std_transactions t1
      WHERE t1.clinic_id = v_exp.clinic_id AND t1.amount > 0
        AND t1.txn_id IN (SELECT txn_id FROM std_transactions WHERE clinic_id = v_exp.clinic_id AND service_code = v_exp.service_code AND amount > 0)
        AND t1.txn_date >= v_exp.start_date - INTERVAL '30 days'
        AND t1.txn_date <= COALESCE(v_cutoff, CURRENT_DATE)
      GROUP BY t1.txn_date, t1.txn_id
    ) t
  ) d;

  v_net_change := v_test_rev - (v_exp.baseline_revenue / v_exp.baseline_days * v_test_days);

  -- ============================================================
  -- SMART DECISION MATRIX
  -- ============================================================
  IF v_vol_change_pct IS NULL THEN
    v_decision := 'review';
    v_reason := 'insufficient baseline data';
  ELSIF v_adj_vol_change < -15 THEN
    v_decision := 'revert';
    v_reason := 'adjusted volume dropped ' || ROUND(v_adj_vol_change::numeric, 1) || '% (clinic: ' || ROUND(COALESCE(v_clinic_growth,0)::numeric,1) || '%, seasonal: ' || ROUND(v_seasonal_adj::numeric,1) || '%)';
  ELSIF v_downstream_after < v_downstream_before * 0.85 THEN
    v_decision := 'review';
    v_reason := 'downstream revenue declining — co-purchase items dropped from ' || ROUND(v_downstream_before::numeric,1) || ' to ' || ROUND(v_downstream_after::numeric,1) || ' per visit';
  ELSIF v_rev_change_pct > 3 AND v_adj_vol_change >= -5 THEN
    v_decision := 'push';
    v_reason := 'revenue +' || ROUND(v_rev_change_pct::numeric,1) || '%, adjusted volume ' || ROUND(v_adj_vol_change::numeric,1) || '% (stable)';
  ELSIF v_rev_change_pct > 0 AND v_adj_vol_change < -5 AND v_adj_vol_change >= -15 THEN
    v_decision := 'hold';
    v_reason := 'revenue up but volume softened — net positive, monitor closely';
  ELSIF v_rev_change_pct <= 0 AND v_adj_vol_change < 0 THEN
    v_decision := 'revert';
    v_reason := 'revenue ' || ROUND(v_rev_change_pct::numeric,1) || '% and volume ' || ROUND(v_adj_vol_change::numeric,1) || '% — not working';
  ELSIF v_adj_vol_change >= 0 AND v_rev_change_pct > 0 THEN
    v_decision := 'push';
    v_reason := 'both revenue and volume up — clear signal to push further';
  ELSE
    v_decision := 'review';
    v_reason := 'ambiguous — revenue ' || COALESCE(ROUND(v_rev_change_pct::numeric,1)::text, '?') || '%, adj volume ' || COALESCE(ROUND(v_adj_vol_change::numeric,1)::text, '?') || '%';
  END IF;

  -- Update experiment
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
    'raw_volume_change_pct', ROUND(v_vol_change_pct::numeric, 1),
    'clinic_growth_pct', ROUND(COALESCE(v_clinic_growth,0)::numeric, 1),
    'seasonal_adjustment', ROUND(v_seasonal_adj::numeric, 1),
    'adjusted_volume_change', ROUND(v_adj_vol_change::numeric, 1),
    'downstream_before', ROUND(v_downstream_before::numeric, 1),
    'downstream_after', ROUND(v_downstream_after::numeric, 1),
    'decision', v_decision, 'reason', v_reason
  ));

  RETURN jsonb_build_object(
    'experiment_id', p_experiment_id,
    'service_code', v_exp.service_code,
    'revenue_change_pct', ROUND(v_rev_change_pct::numeric, 1),
    'raw_volume_change', ROUND(v_vol_change_pct::numeric, 1),
    'clinic_growth', ROUND(COALESCE(v_clinic_growth,0)::numeric, 1),
    'seasonal_adj', ROUND(v_seasonal_adj::numeric, 1),
    'adjusted_volume_change', ROUND(v_adj_vol_change::numeric, 1),
    'downstream_change', ROUND(((v_downstream_after - v_downstream_before) / NULLIF(v_downstream_before,0) * 100)::numeric, 1),
    'decision', v_decision, 'reason', v_reason
  );
END;
$_$;
