-- Fix: alias the LATERAL subquery columns explicitly
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
      (CURRENT_DATE - sp.price_set_date) AS days_at_price,
      aq.suggested_price AS inflation_target,
      CASE WHEN sp.current_price > 0 AND aq.suggested_price IS NOT NULL THEN
        ROUND((aq.suggested_price - sp.current_price) / sp.current_price * 100, 1)
      ELSE NULL END AS inflation_gap_pct,
      CASE WHEN sp.current_price = FLOOR(sp.current_price) + 0.99 THEN true ELSE false END AS is_99,
      vol_trend.trend_pct,
      el.adj_elasticity,
      el.adj_label,
      el.el_confidence,
      el.el_days,
      CASE WHEN sp.annual_volume >= 52 THEN 'high'
           WHEN sp.annual_volume >= 26 THEN 'medium'
           WHEN sp.annual_volume >= 12 THEN 'low'
           ELSE 'insufficient' END AS measurability,
      sp.annual_revenue / NULLIF((SELECT SUM(annual_revenue) FROM std_service_prices WHERE clinic_id = p_clinic_id), 0) * 100 AS revenue_share
    FROM std_service_prices sp
    LEFT JOIN LATERAL (
      SELECT DISTINCT ON (service_code) service_code, suggested_price
      FROM std_approval_queue
      WHERE clinic_id = p_clinic_id AND strategy = 'inflation_catchup' AND status = 'pending'
      ORDER BY service_code, suggested_price DESC
    ) aq ON aq.service_code = sp.service_code
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
    LEFT JOIN LATERAL (
      SELECT adjusted_elasticity AS adj_elasticity, adjusted_label AS adj_label, 
             confidence AS el_confidence, measured_days AS el_days
      FROM std_elasticity
      WHERE clinic_id = p_clinic_id AND service_code = sp.service_code
        AND adjusted_label IS NOT NULL AND adjusted_label != 'unknown'
      ORDER BY 
        CASE confidence WHEN 'high' THEN 3 WHEN 'medium' THEN 2 ELSE 1 END DESC,
        measured_days DESC
      LIMIT 1
    ) el ON true
    WHERE sp.clinic_id = p_clinic_id AND sp.current_price > 0
  ),
  evaluated AS (
    SELECT *,
      CASE 
        WHEN annual_revenue < 100 OR annual_volume < 5 THEN 'ignore'
        WHEN measurability = 'insufficient' THEN 'ignore'
        WHEN inflation_gap_pct IS NOT NULL AND inflation_gap_pct <= 2 THEN 'hold_optimal'
        WHEN measurability IN ('high', 'medium') AND (inflation_gap_pct IS NULL OR inflation_gap_pct > 2) THEN 'test'
        WHEN measurability = 'low' THEN 'hold_low_volume'
        ELSE 'hold'
      END AS action,
      CASE
        WHEN adj_label = 'inelastic' THEN 3.0
        WHEN adj_label = 'moderate' THEN 2.0
        WHEN adj_label IS NULL OR adj_label = 'unknown' THEN 1.0
        WHEN adj_label = 'elastic' THEN 0.0
        ELSE 1.0
      END AS nudge_pct,
      CASE 
        WHEN inflation_target IS NOT NULL THEN LEAST(inflation_target, current_price * 1.10)
        ELSE current_price * 1.10
      END AS price_ceiling,
      CASE 
        WHEN adj_label = 'inelastic' THEN 15.0
        WHEN adj_label = 'moderate' THEN 10.0
        WHEN adj_label IS NULL THEN 8.0
        ELSE 5.0
      END AS volume_floor_pct,
      LEAST(30, annual_revenue / 500) +
      LEAST(25, COALESCE(inflation_gap_pct, 0) * 1.5) +
      CASE adj_label 
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
    'test_count', COUNT(*) FILTER (WHERE action = 'test'),
    'hold_optimal', COUNT(*) FILTER (WHERE action = 'hold_optimal'),
    'hold_low_volume', COUNT(*) FILTER (WHERE action = 'hold_low_volume'),
    'hold', COUNT(*) FILTER (WHERE action = 'hold'),
    'ignore', COUNT(*) FILTER (WHERE action = 'ignore'),
    'inelastic_count', COUNT(*) FILTER (WHERE adj_label = 'inelastic'),
    'moderate_count', COUNT(*) FILTER (WHERE adj_label = 'moderate'),
    'elastic_count', COUNT(*) FILTER (WHERE adj_label = 'elastic'),
    'unknown_elasticity', COUNT(*) FILTER (WHERE adj_label IS NULL),
    'avg_priority', ROUND(AVG(priority_score) FILTER (WHERE action = 'test'), 1),
    'total_testable_revenue', ROUND(SUM(annual_revenue) FILTER (WHERE action = 'test')),
    'top_test', COALESCE(jsonb_agg(to_jsonb(e) ORDER BY e.priority_score DESC) FILTER (WHERE e.action = 'test'), '[]'::jsonb)
  )
  INTO result
  FROM evaluated e;

  RETURN result;
END;
$_$;
