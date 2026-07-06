-- Optimized: pre-compute co-purchase pairs instead of correlated subqueries
CREATE OR REPLACE FUNCTION compute_service_metrics(p_clinic_id TEXT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $_$
DECLARE
  computed INT; v_max_date DATE;
BEGIN
  SELECT MAX(txn_date)::date INTO v_max_date
  FROM std_transactions WHERE clinic_id = p_clinic_id AND amount > 0;
  DELETE FROM std_service_metrics WHERE clinic_id = p_clinic_id;

  -- Step 1: Build visit map
  CREATE TEMP TABLE _visits AS
  WITH numbered AS (
    SELECT service_code, txn_date, txn_id,
      CAST(REGEXP_REPLACE(txn_id, '[^0-9]', '', 'g') AS BIGINT) AS txn_num
    FROM std_transactions WHERE clinic_id = p_clinic_id AND amount > 0
  ),
  gaps AS (
    SELECT *, CASE WHEN txn_num - LAG(txn_num) OVER w > 3 THEN 1 ELSE 0 END AS is_new_visit
    FROM numbered WINDOW w AS (PARTITION BY txn_date ORDER BY txn_num)
  ),
  grouped AS (
    SELECT *, SUM(is_new_visit) OVER w AS visit_seq FROM gaps
    WINDOW w AS (PARTITION BY txn_date ORDER BY txn_num)
  )
  SELECT service_code, txn_date, txn_date::text || '_v' || visit_seq AS visit_key FROM grouped;

  CREATE INDEX ON _visits(service_code);
  CREATE INDEX ON _visits(visit_key);

  -- Step 2: Visit sizes
  CREATE TEMP TABLE _visit_sizes AS
    SELECT visit_key, COUNT(DISTINCT service_code) AS items 
    FROM _visits GROUP BY visit_key;
  CREATE INDEX ON _visit_sizes(visit_key);

  -- Step 3: Co-purchase pairs (limited — only top pairs)
  CREATE TEMP TABLE _co_pairs AS
    SELECT a.service_code AS svc, b.service_code AS co_svc, COUNT(*) AS cnt
    FROM _visits a
    JOIN _visits b ON b.visit_key = a.visit_key AND b.service_code > a.service_code
    GROUP BY a.service_code, b.service_code;
  CREATE INDEX ON _co_pairs(svc);

  -- Step 4: Insert metrics
  INSERT INTO std_service_metrics (
    clinic_id, service_code, top_co_purchased, avg_items_per_visit, co_purchase_rate,
    downstream_multiplier, revenue_trend_90d, revenue_trend_30d,
    peak_month, low_month, seasonal_volatility,
    price_changes_count, avg_years_between_changes, price_vs_median_peer,
    new_client_ratio, avg_repeat_interval_days
  )
  SELECT 
    p_clinic_id, sp.service_code,
    -- Top co-purchased
    (SELECT STRING_AGG(co_svc, ',' ORDER BY cnt DESC) FROM (
      SELECT co_svc, cnt FROM _co_pairs WHERE svc = sp.service_code
      UNION ALL
      SELECT svc AS co_svc, cnt FROM _co_pairs WHERE co_svc = sp.service_code
      ORDER BY cnt DESC LIMIT 5) y),
    -- Avg items per visit
    ROUND((SELECT AVG(items)::numeric FROM _visit_sizes vs WHERE vs.visit_key IN 
      (SELECT visit_key FROM _visits WHERE service_code = sp.service_code)), 1),
    -- Co-purchase rate
    ROUND((SELECT AVG(items)::numeric - 1 FROM _visit_sizes vs WHERE vs.visit_key IN 
      (SELECT visit_key FROM _visits WHERE service_code = sp.service_code)), 1),
    -- Downstream multiplier  
    ROUND((SELECT AVG(items)::numeric FROM _visit_sizes vs WHERE vs.visit_key IN 
      (SELECT visit_key FROM _visits WHERE service_code = sp.service_code)), 2),
    -- Revenue trends
    (SELECT CASE WHEN p90 > 0 THEN ROUND((r90 - p90)::numeric / p90 * 100, 1) END FROM
      (SELECT 
        COALESCE(SUM(amount) FILTER (WHERE txn_date >= v_max_date - INTERVAL '90 days'), 0) AS r90,
        COALESCE(SUM(amount) FILTER (WHERE txn_date >= v_max_date - INTERVAL '180 days' AND txn_date < v_max_date - INTERVAL '90 days'), 0) AS p90
       FROM std_transactions WHERE clinic_id = p_clinic_id AND service_code = sp.service_code AND amount > 0) rt),
    (SELECT CASE WHEN p30 > 0 THEN ROUND((r30 - p30)::numeric / p30 * 100, 1) END FROM
      (SELECT 
        COALESCE(SUM(amount) FILTER (WHERE txn_date >= v_max_date - INTERVAL '30 days'), 0) AS r30,
        COALESCE(SUM(amount) FILTER (WHERE txn_date >= v_max_date - INTERVAL '60 days' AND txn_date < v_max_date - INTERVAL '30 days'), 0) AS p30
       FROM std_transactions WHERE clinic_id = p_clinic_id AND service_code = sp.service_code AND amount > 0) rt2),
    -- Seasonal
    (SELECT EXTRACT(MONTH FROM txn_date)::int FROM std_transactions WHERE clinic_id = p_clinic_id AND service_code = sp.service_code AND amount > 0 GROUP BY EXTRACT(MONTH FROM txn_date) ORDER BY COUNT(*) DESC LIMIT 1),
    (SELECT EXTRACT(MONTH FROM txn_date)::int FROM std_transactions WHERE clinic_id = p_clinic_id AND service_code = sp.service_code AND amount > 0 GROUP BY EXTRACT(MONTH FROM txn_date) ORDER BY COUNT(*) ASC LIMIT 1),
    -- Volatility
    (SELECT CASE WHEN AVG(cnt) > 0 THEN ROUND(STDDEV(cnt)::numeric / AVG(cnt)::numeric, 3) ELSE 0 END FROM
      (SELECT COUNT(*) AS cnt FROM std_transactions WHERE clinic_id = p_clinic_id AND service_code = sp.service_code AND amount > 0 GROUP BY EXTRACT(MONTH FROM txn_date)) mc),
    -- Price changes
    (SELECT COUNT(*) FROM std_price_history WHERE clinic_id = p_clinic_id AND service_code = sp.service_code),
    (SELECT CASE WHEN COUNT(*) > 1 THEN ROUND((MAX(last_seen) - MIN(first_seen))::numeric / 365 / COUNT(*), 2) END FROM std_price_history WHERE clinic_id = p_clinic_id AND service_code = sp.service_code),
    -- Price vs peer
    CASE WHEN pp.median_peer IS NOT NULL AND pp.median_peer > 0 THEN 
      ROUND((sp.current_price - pp.median_peer) / pp.median_peer * 100, 1) END,
    NULL::numeric, NULL::int
  FROM std_service_prices sp
  LEFT JOIN LATERAL (
    SELECT CAST(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY sp2.current_price) AS numeric) AS median_peer
    FROM std_service_prices sp2 WHERE sp2.clinic_id = p_clinic_id AND sp2.category = sp.category AND sp2.service_code != sp.service_code
  ) pp ON true
  WHERE sp.clinic_id = p_clinic_id AND sp.current_price > 0;

  GET DIAGNOSTICS computed = ROW_COUNT;
  DROP TABLE _visits;
  DROP TABLE _visit_sizes;
  DROP TABLE _co_pairs;

  RETURN jsonb_build_object('clinic_id', p_clinic_id, 'services_analyzed', computed,
    'with_co_purchase', (SELECT COUNT(*) FROM std_service_metrics WHERE clinic_id = p_clinic_id AND top_co_purchased IS NOT NULL),
    'avg_items', (SELECT ROUND(AVG(avg_items_per_visit), 1) FROM std_service_metrics WHERE clinic_id = p_clinic_id));
END;
$_$;
