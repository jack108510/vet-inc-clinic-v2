-- Cast median_peer to numeric in peer_prices CTE
CREATE OR REPLACE FUNCTION compute_service_metrics(p_clinic_id TEXT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $_$
DECLARE
  computed INT; v_max_date DATE;
BEGIN
  SELECT MAX(txn_date)::date INTO v_max_date
  FROM std_transactions WHERE clinic_id = p_clinic_id AND amount > 0;
  DELETE FROM std_service_metrics WHERE clinic_id = p_clinic_id;

  CREATE TEMP TABLE _visits AS
  WITH numbered AS (
    SELECT *, CAST(REGEXP_REPLACE(txn_id, '[^0-9]', '', 'g') AS BIGINT) AS txn_num
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

  INSERT INTO std_service_metrics (
    clinic_id, service_code, top_co_purchased, avg_items_per_visit, co_purchase_rate,
    downstream_multiplier, revenue_trend_90d, revenue_trend_30d,
    peak_month, low_month, seasonal_volatility,
    price_changes_count, avg_years_between_changes, price_vs_median_peer,
    new_client_ratio, avg_repeat_interval_days
  )
  WITH visit_sizes AS (
    SELECT visit_key, COUNT(DISTINCT service_code) AS items FROM _visits GROUP BY visit_key
  ),
  co_purchase AS (
    SELECT svd.service_code,
      AVG(svd.items_per_visit)::numeric AS avg_items,
      (AVG(svd.items_per_visit) - 1)::numeric AS co_rate,
      (SELECT STRING_AGG(other_svc, ',' ORDER BY cnt DESC) FROM (
        SELECT v2.service_code AS other_svc, COUNT(*) AS cnt FROM _visits v2
        WHERE v2.visit_key IN (SELECT visit_key FROM _visits WHERE service_code = svd.service_code)
          AND v2.service_code != svd.service_code
        GROUP BY v2.service_code ORDER BY cnt DESC LIMIT 5) x) AS top_co
    FROM (SELECT v.service_code, v.visit_key, vs.items AS items_per_visit
          FROM _visits v JOIN visit_sizes vs ON vs.visit_key = v.visit_key
          GROUP BY v.service_code, v.visit_key, vs.items) svd
    GROUP BY svd.service_code
  ),
  rev_trends AS (
    SELECT t.service_code,
      CASE WHEN prior90.rev > 0 THEN (recent90.rev - prior90.rev)::numeric / prior90.rev * 100 END AS rev_90d,
      CASE WHEN prior30.rev > 0 THEN (recent30.rev - prior30.rev)::numeric / prior30.rev * 100 END AS rev_30d
    FROM (SELECT DISTINCT service_code FROM std_transactions WHERE clinic_id = p_clinic_id AND amount > 0) t
    LEFT JOIN LATERAL (SELECT COALESCE(SUM(amount),0) AS rev FROM std_transactions WHERE clinic_id = p_clinic_id AND service_code = t.service_code AND amount > 0 AND txn_date >= v_max_date - INTERVAL '90 days') recent90 ON true
    LEFT JOIN LATERAL (SELECT COALESCE(SUM(amount),0) AS rev FROM std_transactions WHERE clinic_id = p_clinic_id AND service_code = t.service_code AND amount > 0 AND txn_date >= v_max_date - INTERVAL '180 days' AND txn_date < v_max_date - INTERVAL '90 days') prior90 ON true
    LEFT JOIN LATERAL (SELECT COALESCE(SUM(amount),0) AS rev FROM std_transactions WHERE clinic_id = p_clinic_id AND service_code = t.service_code AND amount > 0 AND txn_date >= v_max_date - INTERVAL '30 days') recent30 ON true
    LEFT JOIN LATERAL (SELECT COALESCE(SUM(amount),0) AS rev FROM std_transactions WHERE clinic_id = p_clinic_id AND service_code = t.service_code AND amount > 0 AND txn_date >= v_max_date - INTERVAL '60 days' AND txn_date < v_max_date - INTERVAL '30 days') prior30 ON true
  ),
  monthly_counts AS (
    SELECT service_code, EXTRACT(MONTH FROM txn_date)::int AS month_num, COUNT(*) AS cnt
    FROM std_transactions WHERE clinic_id = p_clinic_id AND amount > 0
    GROUP BY service_code, EXTRACT(MONTH FROM txn_date)
  ),
  seasonal_agg AS (
    SELECT service_code,
      (SELECT month_num FROM monthly_counts mc2 WHERE mc2.service_code = mc.service_code ORDER BY cnt DESC LIMIT 1) AS peak_mo,
      (SELECT month_num FROM monthly_counts mc2 WHERE mc2.service_code = mc.service_code ORDER BY cnt ASC LIMIT 1) AS low_mo,
      CASE WHEN AVG(cnt) > 0 THEN STDDEV(cnt)::numeric / AVG(cnt)::numeric ELSE 0 END AS vol_volatility
    FROM monthly_counts mc GROUP BY service_code
  ),
  price_change_stats AS (
    SELECT service_code, COUNT(*) AS change_count,
      CASE WHEN COUNT(*) > 1 THEN (MAX(last_seen) - MIN(first_seen))::numeric / 365 / COUNT(*) END AS avg_years
    FROM std_price_history WHERE clinic_id = p_clinic_id GROUP BY service_code
  ),
  peer_prices AS (
    SELECT sp.service_code, sp.current_price,
      CAST(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY sp2.current_price) AS numeric) AS median_peer
    FROM std_service_prices sp
    LEFT JOIN std_service_prices sp2 ON sp2.clinic_id = sp.clinic_id AND sp2.category = sp.category AND sp2.service_code != sp.service_code
    WHERE sp.clinic_id = p_clinic_id
    GROUP BY sp.service_code, sp.current_price
  )
  SELECT p_clinic_id, sp.service_code,
    cp.top_co,
    ROUND(cp.avg_items, 1),
    ROUND(cp.co_rate, 1),
    ROUND(cp.avg_items, 2),
    ROUND(rt.rev_90d, 1),
    ROUND(rt.rev_30d, 1),
    sa.peak_mo, sa.low_mo,
    ROUND(sa.vol_volatility, 3),
    COALESCE(pcs.change_count, 0),
    ROUND(pcs.avg_years, 2),
    CASE WHEN pp.median_peer IS NOT NULL AND pp.median_peer > 0 THEN 
      ROUND((pp.current_price - pp.median_peer) / pp.median_peer * 100, 1) ELSE NULL END,
    NULL::numeric, NULL::int
  FROM std_service_prices sp
  LEFT JOIN co_purchase cp ON cp.service_code = sp.service_code
  LEFT JOIN rev_trends rt ON rt.service_code = sp.service_code
  LEFT JOIN seasonal_agg sa ON sa.service_code = sp.service_code
  LEFT JOIN price_change_stats pcs ON pcs.service_code = sp.service_code
  LEFT JOIN peer_prices pp ON pp.service_code = sp.service_code
  WHERE sp.clinic_id = p_clinic_id AND sp.current_price > 0;

  GET DIAGNOSTICS computed = ROW_COUNT;
  DROP TABLE _visits;
  RETURN jsonb_build_object('clinic_id', p_clinic_id, 'services_analyzed', computed,
    'with_co_purchase', (SELECT COUNT(*) FROM std_service_metrics WHERE clinic_id = p_clinic_id AND top_co_purchased IS NOT NULL),
    'avg_items', (SELECT ROUND(AVG(avg_items_per_visit), 1) FROM std_service_metrics WHERE clinic_id = p_clinic_id));
END;
$_$;
