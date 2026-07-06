-- ============================================================
-- THE ALGORITHM: Evaluate every service, build guardrails
-- Looks at all 887 services and produces a complete plan
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
      -- Days at current price
      (CURRENT_DATE - sp.price_set_date) AS days_at_price,
      -- Inflation gap (from approval queue if available)
      aq.suggested_price AS inflation_target,
      CASE WHEN sp.current_price > 0 AND aq.suggested_price IS NOT NULL THEN
        ROUND((aq.suggested_price - sp.current_price) / sp.current_price * 100, 1)
      ELSE NULL END AS inflation_gap_pct,
      -- Is .99 compliant
      CASE WHEN sp.current_price = FLOOR(sp.current_price) + 0.99 THEN true ELSE false END AS is_99,
      -- Volume trend (last 90 days vs prior 90 days from data max)
      vol_trend.trend_pct,
      -- Elasticity (best adjusted reading)
      e.adjusted_elasticity,
      e.adjusted_label AS elasticity_label,
      e.confidence AS elasticity_confidence,
      e.measured_days AS elasticity_days,
      -- Statistical significance: can we measure a change?
      CASE WHEN sp.annual_volume >= 52 THEN 'high'   -- at least 1/week
           WHEN sp.annual_volume >= 26 THEN 'medium'  -- at least 2/month
           WHEN sp.annual_volume >= 12 THEN 'low'     -- at least 1/month
           ELSE 'insufficient' END AS measurability,
      -- Revenue weight
      sp.annual_revenue / NULLIF((SELECT SUM(annual_revenue) FROM std_service_prices WHERE clinic_id = p_clinic_id), 0) * 100 AS revenue_share
    FROM std_service_prices sp
    -- Get inflation target
    LEFT JOIN LATERAL (
      SELECT DISTINCT ON (service_code) service_code, suggested_price
      FROM std_approval_queue
      WHERE clinic_id = p_clinic_id AND strategy = 'inflation_catchup' AND status = 'pending'
      ORDER BY service_code, suggested_price DESC
    ) aq ON aq.service_code = sp.service_code
    -- Get volume trend (last 90 days vs prior 90 days)
    LEFT JOIN LATERAL (
      WITH dates AS (
        SELECT MAX(txn_date) AS max_date FROM std_transactions WHERE clinic_id = p_clinic_id
      )
      SELECT 
        CASE WHEN recent.cnt > 0 AND prior.cnt > 0 THEN
          ROUND((recent.cnt - prior.cnt)::numeric / prior.cnt * 100, 1)
        ELSE NULL END AS trend_pct
      FROM dates,
      LATERAL (SELECT COUNT(*) AS cnt FROM std_transactions WHERE clinic_id = p_clinic_id AND service_code = sp.service_code AND amount > 0 AND txn_date >= max_date - INTERVAL '90 days') recent,
      LATERAL (SELECT COUNT(*) AS cnt FROM std_transactions WHERE clinic_id = p_clinic_id AND service_code = sp.service_code AND amount > 0 AND txn_date >= max_date - INTERVAL '180 days' AND txn_date < max_date - INTERVAL '90 days') prior
    ) vol_trend ON true
    -- Get best elasticity reading (adjusted)
    LEFT JOIN LATERAL (
      SELECT adjusted_elasticity, adjusted_label, confidence, measured_days
      FROM std_elasticity
      WHERE clinic_id = p_clinic_id AND service_code = sp.service_code
        AND adjusted_label IS NOT NULL AND adjusted_label != 'unknown'
      ORDER BY 
        CASE confidence WHEN 'high' THEN 3 WHEN 'medium' THEN 2 ELSE 1 END DESC,
        measured_days DESC
      LIMIT 1
    ) e ON true
    WHERE sp.clinic_id = p_clinic_id AND sp.current_price > 0
  ),
  evaluated AS (
    SELECT *,
      -- CLASSIFICATION: test, hold, protect, or ignore
      CASE 
        -- IGNORE: too small to matter
        WHEN annual_revenue < 100 OR annual_volume < 5 THEN 'ignore'
        -- IGNORE: not enough volume to measure
        WHEN measurability = 'insufficient' THEN 'ignore'
        -- PROTECT: already at or above inflation target
        WHEN inflation_gap_pct IS NOT NULL AND inflation_gap_pct <= 2 THEN 'hold_optimal'
        -- TEST: has room to move and enough volume to measure
        WHEN measurability IN ('high', 'medium') AND (inflation_gap_pct IS NULL OR inflation_gap_pct > 2) THEN 'test'
        -- HOLD: low measurability but has room
        WHEN measurability = 'low' THEN 'hold_low_volume'
        ELSE 'hold'
      END AS action,
      -- NUDGE SIZE (percentage)
      CASE
        WHEN adjusted_label = 'inelastic' THEN 3.0
        WHEN adjusted_label = 'moderate' THEN 2.0
        WHEN adjusted_label IS NULL OR adjusted_label = 'unknown' THEN 1.0
        WHEN adjusted_label = 'elastic' THEN 0.0  -- don't test
        ELSE 1.0
      END AS nudge_pct,
      -- CEILING (max we'd ever push this service)
      CASE 
        WHEN inflation_target IS NOT NULL THEN LEAST(inflation_target, current_price * 1.10)
        ELSE current_price * 1.10
      END AS price_ceiling,
      -- FLOOR (revert trigger: if volume drops more than this vs clinic trend)
      CASE 
        WHEN adjusted_label = 'inelastic' THEN 15.0   -- tolerate big swings
        WHEN adjusted_label = 'moderate' THEN 10.0
        WHEN adjusted_label IS NULL THEN 8.0           -- conservative for unknowns
        ELSE 5.0
      END AS volume_floor_pct,
      -- PRIORITY SCORE (0-100)
      -- Revenue weight (max 30), inflation gap (max 25), elasticity safety (max 20), 
      -- measurability (max 15), days stale (max 10)
      LEAST(30, annual_revenue / 500) +
      LEAST(25, COALESCE(inflation_gap_pct, 0) * 1.5) +
      CASE adjusted_label 
        WHEN 'inelastic' THEN 20 
        WHEN 'moderate' THEN 12 
        WHEN NULL THEN 8
        WHEN 'unknown' THEN 8
        ELSE 0 END +
      CASE measurability 
        WHEN 'high' THEN 15 
        WHEN 'medium' THEN 10 
        WHEN 'low' THEN 5 
        ELSE 0 END +
      LEAST(10, COALESCE(days_at_price, 0) / 180.0 * 10) AS priority_score
    FROM service_data
  )
  SELECT jsonb_build_object(
    'total_services', COUNT(*),
    'test', (SELECT jsonb_agg(to_jsonb(e) ORDER BY e.priority_score DESC) FROM evaluated e WHERE e.action = 'test'),
    'hold_optimal', (SELECT COUNT(*) FROM evaluated WHERE action = 'hold_optimal'),
    'hold_low_volume', (SELECT COUNT(*) FROM evaluated WHERE action = 'hold_low_volume'),
    'hold', (SELECT COUNT(*) FROM evaluated WHERE action = 'hold'),
    'ignore', (SELECT COUNT(*) FROM evaluated WHERE action = 'ignore'),
    'inelastic_count', (SELECT COUNT(*) FROM evaluated WHERE elasticity_label = 'inelastic'),
    'moderate_count', (SELECT COUNT(*) FROM evaluated WHERE elasticity_label = 'moderate'),
    'elastic_count', (SELECT COUNT(*) FROM evaluated WHERE elasticity_label = 'elastic'),
    'unknown_elasticity', (SELECT COUNT(*) FROM evaluated WHERE elasticity_label IS NULL),
    'avg_priority', (SELECT ROUND(AVG(priority_score), 1) FROM evaluated WHERE action = 'test'),
    'total_testable_revenue', (SELECT ROUND(SUM(annual_revenue)) FROM evaluated WHERE action = 'test')
  )
  INTO result
  FROM evaluated;

  RETURN result;
END;
$_$;
