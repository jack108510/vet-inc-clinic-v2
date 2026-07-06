-- Fix: cast to numeric for ROUND()
CREATE OR REPLACE FUNCTION compute_elasticity(p_clinic_id TEXT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $_$
DECLARE
  computed INT;
BEGIN
  DELETE FROM std_elasticity WHERE clinic_id = p_clinic_id;

  CREATE TEMP TABLE _daily_counts AS
    SELECT service_code, txn_date::date AS d, COUNT(*) AS cnt
    FROM std_transactions
    WHERE clinic_id = p_clinic_id AND amount > 0
    GROUP BY service_code, txn_date::date;

  CREATE INDEX ON _daily_counts(service_code, d);

  INSERT INTO std_elasticity (
    clinic_id, service_code, price_before, price_after,
    price_change_pct, volume_before, volume_after, volume_change_pct,
    elasticity, elasticity_label, measured_days, confidence
  )
  WITH price_changes AS (
    SELECT DISTINCT ON (curr.service_code, prev.price, curr.price)
      curr.service_code,
      prev.price AS price_before,
      curr.price AS price_after,
      GREATEST(prev.first_seen::date, (curr.first_seen - INTERVAL '30 days')::date) AS before_start,
      curr.first_seen::date AS change_date,
      LEAST((curr.last_seen + INTERVAL '1 day')::date, (curr.first_seen + INTERVAL '30 days')::date) AS after_end
    FROM std_price_history curr
    JOIN std_price_history prev ON prev.service_code = curr.service_code
      AND prev.clinic_id = p_clinic_id AND curr.clinic_id = p_clinic_id
      AND prev.last_seen < curr.first_seen AND prev.id != curr.id
    WHERE curr.clinic_id = p_clinic_id AND curr.price != prev.price AND prev.price > 0
      AND NOT EXISTS (
        SELECT 1 FROM std_price_history mid WHERE mid.service_code = curr.service_code AND mid.clinic_id = p_clinic_id
        AND mid.first_seen > prev.first_seen AND mid.first_seen < curr.first_seen
      )
    ORDER BY curr.service_code, prev.price, curr.price, curr.first_seen DESC
  ),
  before_agg AS (
    SELECT pc.service_code, pc.price_before, pc.price_after,
      COALESCE(SUM(dc.cnt), 0)::numeric AS vol_before,
      COUNT(dc.d) AS days_before
    FROM price_changes pc
    LEFT JOIN _daily_counts dc ON dc.service_code = pc.service_code
      AND dc.d >= pc.before_start AND dc.d < pc.change_date
    GROUP BY pc.service_code, pc.price_before, pc.price_after
  ),
  after_agg AS (
    SELECT pc.service_code, pc.price_before, pc.price_after,
      COALESCE(SUM(dc.cnt), 0)::numeric AS vol_after,
      COUNT(dc.d) AS days_after
    FROM price_changes pc
    LEFT JOIN _daily_counts dc ON dc.service_code = pc.service_code
      AND dc.d >= pc.change_date AND dc.d < pc.after_end
    GROUP BY pc.service_code, pc.price_before, pc.price_after
  ),
  rates AS (
    SELECT b.service_code, b.price_before, b.price_after,
      b.vol_before, b.days_before,
      a.vol_after, a.days_after,
      CASE WHEN b.days_before > 0 THEN b.vol_before::numeric / b.days_before ELSE 0 END AS dr_before,
      CASE WHEN a.days_after > 0 THEN a.vol_after::numeric / a.days_after ELSE 0 END AS dr_after
    FROM before_agg b
    JOIN after_agg a ON a.service_code = b.service_code AND a.price_before = b.price_before AND a.price_after = b.price_after
  )
  SELECT
    p_clinic_id,
    service_code,
    price_before,
    price_after,
    ROUND((price_after - price_before) / NULLIF(price_before, 0) * 100, 1),
    dr_before::int,
    dr_after::int,
    CASE WHEN dr_before > 0 THEN ROUND((dr_after - dr_before) / dr_before * 100, 1) ELSE NULL END,
    CASE WHEN dr_before > 0 AND price_before > 0 THEN
      ROUND(((dr_after - dr_before) / dr_before) / NULLIF((price_after - price_before) / price_before, 0), 3)
    END,
    CASE 
      WHEN dr_before = 0 OR price_before = 0 OR days_after = 0 THEN 'unknown'
      WHEN ABS(((dr_after - dr_before) / dr_before) / NULLIF((price_after - price_before) / price_before, 0)) < 0.3 THEN 'inelastic'
      WHEN ABS(((dr_after - dr_before) / dr_before) / NULLIF((price_after - price_before) / price_before, 0)) < 0.8 THEN 'moderate'
      ELSE 'elastic'
    END,
    LEAST(days_before, days_after),
    CASE 
      WHEN LEAST(days_before, days_after) >= 60 THEN 'high'
      WHEN LEAST(days_before, days_after) >= 30 THEN 'medium'
      ELSE 'low'
    END
  FROM rates
  WHERE dr_before > 0 OR dr_after > 0;

  GET DIAGNOSTICS computed = ROW_COUNT;
  DROP TABLE _daily_counts;

  RETURN jsonb_build_object(
    'clinic_id', p_clinic_id,
    'elasticity_records', computed,
    'inelastic', (SELECT COUNT(*) FROM std_elasticity WHERE clinic_id = p_clinic_id AND elasticity_label = 'inelastic'),
    'moderate', (SELECT COUNT(*) FROM std_elasticity WHERE clinic_id = p_clinic_id AND elasticity_label = 'moderate'),
    'elastic', (SELECT COUNT(*) FROM std_elasticity WHERE clinic_id = p_clinic_id AND elasticity_label = 'elastic'),
    'unknown', (SELECT COUNT(*) FROM std_elasticity WHERE clinic_id = p_clinic_id AND elasticity_label = 'unknown'),
    'high_confidence', (SELECT COUNT(*) FROM std_elasticity WHERE clinic_id = p_clinic_id AND confidence = 'high'),
    'medium_confidence', (SELECT COUNT(*) FROM std_elasticity WHERE clinic_id = p_clinic_id AND confidence = 'medium')
  );
END;
$_$;
