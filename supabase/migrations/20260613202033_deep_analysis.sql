-- ============================================================
-- DEEP ANALYSIS: Co-purchase patterns, seasonal adjustment, 
-- revenue trends, price consistency, downstream revenue
-- ============================================================

-- Table to store per-service deep metrics
CREATE TABLE IF NOT EXISTS std_service_metrics (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  clinic_id TEXT NOT NULL,
  service_code TEXT NOT NULL,
  
  -- Co-purchase data (what else gets bought with this)
  top_co_purchased TEXT,           -- comma-separated top 5 service codes
  avg_items_per_visit NUMERIC,     -- avg total items on invoices with this service
  co_purchase_rate NUMERIC,        -- avg # of OTHER services purchased alongside
  
  -- Downstream revenue (what this service leads to)
  downstream_multiplier NUMERIC,   -- total invoice value / this service's price
  
  -- Revenue trend
  revenue_trend_90d NUMERIC,       -- last 90d revenue vs prior 90d (% change)
  revenue_trend_30d NUMERIC,       -- last 30d vs prior 30d
  
  -- Seasonal volume pattern
  peak_month INT,                  -- month with highest avg volume
  low_month INT,                   -- month with lowest avg volume
  seasonal_volatility NUMERIC,     -- std dev of monthly volume / mean (higher = more seasonal)
  
  -- Price analysis
  price_changes_count INT,         -- how many times price has changed in history
  avg_years_between_changes NUMERIC, -- how often do they reprice this
  price_vs_median_peer NUMERIC,    -- this price vs median of same-category services
  
  -- Client behavior
  new_client_ratio NUMERIC,        -- % of visits from first-time clients
  avg_repeat_interval_days INT,    -- how often same client buys this again
  
  UNIQUE(clinic_id, service_code)
);

ALTER TABLE std_service_metrics ENABLE ROW LEVEL SECURITY;
CREATE POLICY "auth_metrics" ON std_service_metrics FOR SELECT USING (clinic_id IN (SELECT clinic_id FROM meta_clinic_users WHERE user_id = auth.uid()));
CREATE POLICY "svc_metrics" ON std_service_metrics FOR ALL USING (true) WITH CHECK (true);
CREATE INDEX idx_metrics_clinic ON std_service_metrics(clinic_id);

-- ============================================================
-- COMPUTE DEEP METRICS
-- ============================================================

CREATE OR REPLACE FUNCTION compute_service_metrics(p_clinic_id TEXT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $_$
DECLARE
  computed INT;
  v_max_date DATE;
BEGIN
  SELECT MAX(txn_date)::date INTO v_max_date
  FROM std_transactions WHERE clinic_id = p_clinic_id AND amount > 0;

  DELETE FROM std_service_metrics WHERE clinic_id = p_clinic_id;

  -- Build visit groups (same date + sequential txn_id) for co-purchase analysis
  CREATE TEMP TABLE _visits AS
  WITH numbered AS (
    SELECT *,
      CAST(REGEXP_REPLACE(txn_id, '[^0-9]', '', 'g') AS BIGINT) AS txn_num
    FROM std_transactions
    WHERE clinic_id = p_clinic_id AND amount > 0
  ),
  gaps AS (
    SELECT *,
      CASE WHEN txn_num - LAG(txn_num) OVER (PARTITION BY txn_date ORDER BY txn_num) > 3 THEN 1
           ELSE 0 END AS is_new_visit
    FROM numbered
  ),
  grouped AS (
    SELECT *,
      SUM(is_new_visit) OVER (PARTITION BY txn_date ORDER BY txn_num) AS visit_seq
    FROM gaps
  )
  SELECT 
    service_code,
    txn_date,
    txn_date::text || '_v' || visit_seq AS visit_key
  FROM grouped;

  CREATE INDEX ON _visits(service_code);
  CREATE INDEX ON _visits(visit_key);

  -- Per-service deep metrics
  INSERT INTO std_service_metrics (
    clinic_id, service_code,
    top_co_purchased, avg_items_per_visit, co_purchase_rate, downstream_multiplier,
    revenue_trend_90d, revenue_trend_30d,
    peak_month, low_month, seasonal_volatility,
    price_changes_count, avg_years_between_changes,
    price_vs_median_peer,
    new_client_ratio, avg_repeat_interval_days
  )
  WITH visit_sizes AS (
    SELECT visit_key, COUNT(DISTINCT service_code) AS items, SUM(1) AS total_items
    FROM _visits GROUP BY visit_key
  ),
  service_visit_data AS (
    SELECT 
      v.service_code,
      v.visit_key,
      vs.items AS items_per_visit
    FROM _visits v
    JOIN visit_sizes vs ON vs.visit_key = v.visit_key
    GROUP BY v.service_code, v.visit_key, vs.items
  ),
  co_purchase AS (
    SELECT 
      svd.service_code,
      AVG(svd.items_per_visit::numeric) AS avg_items,
      AVG(svd.items_per_visit::numeric) - 1 AS co_rate,
      -- Downstream: total invoice value / this service price
      -- Use avg items as proxy for downstream multiplier
      AVG(svd.items_per_visit::numeric) AS downstream,
      -- Top co-purchased (most common other services)
      (SELECT STRING_AGG(other_svc, ',' ORDER BY cnt DESC) FROM (
        SELECT v2.service_code AS other_svc, COUNT(*) AS cnt
        FROM _visits v2
        WHERE v2.visit_key IN (SELECT visit_key FROM _visits WHERE service_code = svd.service_code)
          AND v2.service_code != svd.service_code
        GROUP BY v2.service_code
        ORDER BY cnt DESC
        LIMIT 5
      ) x) AS top_co
    FROM service_visit_data svd
    GROUP BY svd.service_code
  ),
  rev_trends AS (
    SELECT 
      t.service_code,
      -- 90 day trend
      CASE WHEN prior90.rev > 0 THEN
        ROUND((recent90.rev - prior90.rev) / prior90.rev * 100, 1) END AS rev_90d,
      CASE WHEN prior30.rev > 0 THEN
        ROUND((recent30.rev - prior30.rev) / prior30.rev * 100, 1) END AS rev_30d
    FROM (SELECT DISTINCT service_code FROM std_transactions WHERE clinic_id = p_clinic_id AND amount > 0) t
    LEFT JOIN LATERAL (
      SELECT COALESCE(SUM(amount),0) AS rev FROM std_transactions 
      WHERE clinic_id = p_clinic_id AND service_code = t.service_code AND amount > 0
        AND txn_date >= v_max_date - INTERVAL '90 days'
    ) recent90 ON true
    LEFT JOIN LATERAL (
      SELECT COALESCE(SUM(amount),0) AS rev FROM std_transactions 
      WHERE clinic_id = p_clinic_id AND service_code = t.service_code AND amount > 0
        AND txn_date >= v_max_date - INTERVAL '180 days' AND txn_date < v_max_date - INTERVAL '90 days'
    ) prior90 ON true
    LEFT JOIN LATERAL (
      SELECT COALESCE(SUM(amount),0) AS rev FROM std_transactions 
      WHERE clinic_id = p_clinic_id AND service_code = t.service_code AND amount > 0
        AND txn_date >= v_max_date - INTERVAL '30 days'
    ) recent30 ON true
    LEFT JOIN LATERAL (
      SELECT COALESCE(SUM(amount),0) AS rev FROM std_transactions 
      WHERE clinic_id = p_clinic_id AND service_code = t.service_code AND amount > 0
        AND txn_date >= v_max_date - INTERVAL '60 days' AND txn_date < v_max_date - INTERVAL '30 days'
    ) prior30 ON true
  ),
  seasonal AS (
    SELECT 
      service_code,
      MAX(CASE WHEN monthly_avg = max_monthly THEN month_num END) AS peak_mo,
      MAX(CASE WHEN monthly_avg = min_monthly THEN month_num END) AS low_mo,
      ROUND(COALESCE(STDDEV(monthly_cnt)::numeric / NULLIF(AVG(monthly_cnt), 0), 0), 3) AS vol_volatility
    FROM (
      SELECT 
        service_code,
        EXTRACT(MONTH FROM txn_date)::int AS month_num,
        COUNT(*) AS monthly_cnt,
        AVG(monthly_cnt) OVER (PARTITION BY service_code) AS monthly_avg,
        MAX(monthly_cnt) OVER (PARTITION BY service_code) AS max_monthly,
        MIN(monthly_cnt) OVER (PARTITION BY service_code) AS min_monthly
      FROM std_transactions
      WHERE clinic_id = p_clinic_id AND amount > 0
      GROUP BY service_code, EXTRACT(MONTH FROM txn_date), DATE_TRUNC('year', txn_date)
    ) s
    GROUP BY service_code
  ),
  price_change_stats AS (
    SELECT 
      service_code,
      COUNT(*) AS change_count,
      CASE WHEN COUNT(*) > 1 THEN
        ROUND((MAX(last_seen) - MIN(first_seen))::numeric / 365 / COUNT(*), 2)
      END AS avg_years
    FROM std_price_history
    WHERE clinic_id = p_clinic_id
    GROUP BY service_code
    HAVING COUNT(*) > 0
  ),
  peer_prices AS (
    SELECT 
      sp.service_code,
      sp.current_price,
      sp.category,
      PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY sp2.current_price) AS median_peer
    FROM std_service_prices sp
    LEFT JOIN std_service_prices sp2 ON sp2.clinic_id = sp.clinic_id 
      AND sp2.category = sp.category AND sp2.service_code != sp.service_code
    WHERE sp.clinic_id = p_clinic_id
    GROUP BY sp.service_code, sp.current_price, sp.category
  )
  SELECT 
    p_clinic_id,
    sp.service_code,
    cp.top_co,
    ROUND(cp.avg_items, 1),
    ROUND(cp.co_rate, 1),
    ROUND(cp.downstream, 2),
    rt.rev_90d,
    rt.rev_30d,
    s.peak_mo,
    s.low_mo,
    s.vol_volatility,
    COALESCE(pcs.change_count, 0),
    pcs.avg_years,
    CASE WHEN pp.median_peer > 0 THEN 
      ROUND((pp.current_price - pp.median_peer) / pp.median_peer * 100, 1)
    ELSE NULL END,
    NULL, -- new_client_ratio (needs client data we don't have linked)
    NULL  -- avg_repeat_interval (same)
  FROM std_service_prices sp
  LEFT JOIN co_purchase cp ON cp.service_code = sp.service_code
  LEFT JOIN rev_trends rt ON rt.service_code = sp.service_code
  LEFT JOIN seasonal s ON s.service_code = sp.service_code
  LEFT JOIN price_change_stats pcs ON pcs.service_code = sp.service_code
  LEFT JOIN peer_prices pp ON pp.service_code = sp.service_code
  WHERE sp.clinic_id = p_clinic_id AND sp.current_price > 0;

  GET DIAGNOSTICS computed = ROW_COUNT;
  DROP TABLE _visits;

  RETURN jsonb_build_object(
    'clinic_id', p_clinic_id,
    'services_analyzed', computed,
    'with_co_purchase', (SELECT COUNT(*) FROM std_service_metrics WHERE clinic_id = p_clinic_id AND top_co_purchased IS NOT NULL),
    'with_revenue_trend', (SELECT COUNT(*) FROM std_service_metrics WHERE clinic_id = p_clinic_id AND revenue_trend_90d IS NOT NULL),
    'avg_items_per_visit', (SELECT ROUND(AVG(avg_items_per_visit), 1) FROM std_service_metrics WHERE clinic_id = p_clinic_id)
  );
END;
$_$;
