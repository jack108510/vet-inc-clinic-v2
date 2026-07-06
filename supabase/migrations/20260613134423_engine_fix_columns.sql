-- Fix column references in pick_experiments and start_experiment

CREATE OR REPLACE FUNCTION pick_experiments(
  p_clinic_id TEXT,
  p_limit INT DEFAULT 20
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $_$
BEGIN
  RETURN (
    WITH inflation_targets AS (
      SELECT DISTINCT ON (service_code) service_code, suggested_price
      FROM std_approval_queue
      WHERE clinic_id = p_clinic_id AND strategy = 'inflation_catchup' AND status = 'pending'
      ORDER BY service_code, suggested_price DESC
    ),
    scored AS (
      SELECT 
        sp.service_code,
        sp.service_name,
        sp.current_price,
        it.suggested_price,
        CASE WHEN sp.current_price > 0 AND it.suggested_price IS NOT NULL THEN
          ROUND((it.suggested_price - sp.current_price) / sp.current_price * 100, 1)
        ELSE 0 END AS headroom_pct,
        sp.annual_revenue,
        sp.annual_volume,
        COALESCE(e.elasticity_label, 'unknown') AS elasticity_label,
        e.elasticity AS elasticity_value,
        COALESCE(e.confidence, 'none') AS confidence,
        -- Score: revenue (40) + headroom (30) + elasticity (20) + volume (10)
        LEAST(40, sp.annual_revenue / 100) +
        LEAST(30, CASE WHEN sp.current_price > 0 AND it.suggested_price IS NOT NULL THEN
          (it.suggested_price - sp.current_price) / sp.current_price * 100 * 2 ELSE 0 END) +
        CASE COALESCE(e.elasticity_label, 'unknown')
          WHEN 'inelastic' THEN 20
          WHEN 'moderate' THEN 10
          WHEN 'unknown' THEN 5
          ELSE 0 END +
        LEAST(10, sp.annual_volume / 50) AS score
      FROM std_service_prices sp
      LEFT JOIN inflation_targets it ON it.service_code = sp.service_code
      LEFT JOIN LATERAL (
        SELECT elasticity_label, elasticity, confidence
        FROM std_elasticity 
        WHERE clinic_id = p_clinic_id AND service_code = sp.service_code
        ORDER BY CASE confidence WHEN 'high' THEN 3 WHEN 'medium' THEN 2 ELSE 1 END DESC,
                 ABS(elasticity) ASC
        LIMIT 1
      ) e ON true
      WHERE sp.clinic_id = p_clinic_id
        AND sp.current_price > 0
        AND sp.annual_volume >= 5  -- need minimum volume to test
        AND sp.service_code NOT IN (
          SELECT service_code FROM std_price_experiments 
          WHERE clinic_id = p_clinic_id AND status IN ('pending', 'running')
        )
    )
    SELECT COALESCE(jsonb_agg(to_jsonb(s) ORDER BY s.score DESC), '[]'::jsonb)
    FROM (SELECT * FROM scored ORDER BY score DESC LIMIT p_limit) s
  );
END;
$_$;

-- Fix start_experiment to use current_price instead of mode_price
CREATE OR REPLACE FUNCTION start_experiment(
  p_clinic_id TEXT,
  p_service_code TEXT,
  p_change_pct NUMERIC DEFAULT 2,
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
  SELECT current_price, service_name INTO v_price
  FROM std_service_prices
  WHERE clinic_id = p_clinic_id AND service_code = p_service_code;
  
  IF NOT FOUND THEN
    RETURN jsonb_build_object('error', 'service not found');
  END IF;

  v_old_price := v_price.current_price;

  IF p_direction = 'up' THEN
    v_new_price := ROUND((v_old_price * (1 + p_change_pct / 100))::numeric, 2);
  ELSE
    v_new_price := ROUND((v_old_price * (1 - p_change_pct / 100))::numeric, 2);
  END IF;
  v_new_price := FLOOR(v_new_price) + 0.99;

  IF ABS((v_new_price - v_old_price) / v_old_price * 100) > 15 THEN
    RETURN jsonb_build_object('error', 'change exceeds 15% safety limit');
  END IF;

  SELECT MAX(txn_date) - INTERVAL '30 days' INTO v_cutoff
  FROM std_transactions WHERE clinic_id = p_clinic_id;

  SELECT COALESCE(SUM(amount), 0), COUNT(*), COUNT(DISTINCT txn_date::date)
  INTO v_baseline_rev, v_baseline_vol, v_baseline_days
  FROM std_transactions
  WHERE clinic_id = p_clinic_id AND service_code = p_service_code
    AND txn_date >= v_cutoff AND amount > 0;

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

  INSERT INTO std_experiment_history (experiment_id, action, details)
  VALUES (v_exp_id, 'started', jsonb_build_object(
    'old_price', v_old_price, 'test_price', v_new_price,
    'change_pct', p_change_pct, 'direction', p_direction,
    'baseline_revenue', v_baseline_rev,
    'baseline_volume', v_baseline_vol,
    'baseline_days', v_baseline_days
  ));

  RETURN jsonb_build_object(
    'experiment_id', v_exp_id,
    'service_code', p_service_code,
    'service_name', v_price.service_name,
    'old_price', v_old_price,
    'test_price', v_new_price,
    'change_pct', p_change_pct,
    'baseline_revenue', v_baseline_rev,
    'baseline_volume', v_baseline_vol,
    'baseline_days', v_baseline_days
  );
END;
$_$;
