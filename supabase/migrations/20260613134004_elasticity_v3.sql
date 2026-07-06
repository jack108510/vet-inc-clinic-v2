-- Elasticity v3: Clean rewrite with daily-rate normalization
CREATE OR REPLACE FUNCTION compute_elasticity(p_clinic_id TEXT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $_$
DECLARE
  computed INT;
BEGIN
  DELETE FROM std_elasticity WHERE clinic_id = p_clinic_id;

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
      prev.first_seen AS prev_start,
      curr.first_seen AS change_date,
      curr.last_seen AS curr_end
    FROM std_price_history curr
    JOIN std_price_history prev ON prev.service_code = curr.service_code
      AND prev.clinic_id = p_clinic_id
      AND curr.clinic_id = p_clinic_id
      AND prev.last_seen < curr.first_seen
      AND prev.id != curr.id
    WHERE curr.clinic_id = p_clinic_id
      AND curr.price != prev.price
      AND prev.price > 0
      AND NOT EXISTS (
        SELECT 1 FROM std_price_history mid
        WHERE mid.service_code = curr.service_code
          AND mid.clinic_id = p_clinic_id
          AND mid.first_seen > prev.first_seen
          AND mid.first_seen < curr.first_seen
      )
    ORDER BY curr.service_code, prev.price, curr.price, curr.first_seen DESC
  ),
  measured AS (
    SELECT
      pc.service_code,
      pc.price_before,
      pc.price_after,
      -- Before period: from max(prev_start, change_date - 30 days) to change_date
      COUNT(t1.id) AS vol_before_total,
      COUNT(DISTINCT t1.txn_date::date) AS days_before,
      -- After period: from change_date to min(curr_end + 1, change_date + 30 days)
      COUNT(t2.id) AS vol_after_total,
      COUNT(DISTINCT t2.txn_date::date) AS days_after
    FROM price_changes pc
    LEFT JOIN std_transactions t1 ON t1.clinic_id = p_clinic_id
      AND t1.service_code = pc.service_code
      AND t1.txn_date >= GREATEST(pc.prev_start, pc.change_date - INTERVAL '30 days')
      AND t1.txn_date < pc.change_date
      AND t1.amount > 0
    LEFT JOIN std_transactions t2 ON t2.clinic_id = p_clinic_id
      AND t2.service_code = pc.service_code
      AND t2.txn_date >= pc.change_date
      AND t2.txn_date < LEAST(pc.curr_end + INTERVAL '1 day', pc.change_date + INTERVAL '30 days')
      AND t2.amount > 0
    GROUP BY pc.service_code, pc.price_before, pc.price_after, pc.change_date, pc.prev_start, pc.curr_end
  ),
  daily_rates AS (
    SELECT
      service_code,
      price_before,
      price_after,
      vol_before_total,
      vol_after_total,
      days_before,
      days_after,
      -- Daily rate = total txns / actual days with transactions (not calendar days)
      CASE WHEN days_before > 0 THEN vol_before_total::numeric / days_before ELSE 0 END AS dr_before,
      CASE WHEN days_after > 0 THEN vol_after_total::numeric / days_after ELSE 0 END AS dr_after
    FROM measured
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
      WHEN dr_before = 0 OR price_before = 0 THEN 'unknown'
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
  FROM daily_rates
  WHERE dr_before > 0 OR dr_after > 0;

  GET DIAGNOSTICS computed = ROW_COUNT;
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
