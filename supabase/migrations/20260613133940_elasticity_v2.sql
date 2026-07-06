-- ============================================================
-- Elasticity v2: Fix volume normalization
-- Use DAILY RATES (transactions per day) not raw totals
-- ============================================================

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
  SELECT
    p_clinic_id, service_code,
    price_before, price_after,
    ROUND((price_after - price_before) / NULLIF(price_before, 0) * 100, 1),
    -- Store daily rates (per-day averages)
    daily_rate_before,
    daily_rate_after,
    CASE WHEN daily_rate_before > 0 THEN ROUND((daily_rate_after - daily_rate_before) / daily_rate_before * 100, 1) ELSE NULL END,
    CASE WHEN daily_rate_before > 0 AND price_before > 0 THEN
      ROUND(((daily_rate_after - daily_rate_before) / daily_rate_before) / NULLIF((price_after - price_before) / price_before, 0), 3)
    END,
    CASE 
      WHEN daily_rate_before = 0 OR price_before = 0 THEN 'unknown'
      WHEN ABS(((daily_rate_after - daily_rate_before) / daily_rate_before) / NULLIF((price_after - price_before) / price_before, 0)) < 0.3 THEN 'inelastic'
      WHEN ABS(((daily_rate_after - daily_rate_before) / daily_rate_before) / NULLIF((price_after - price_before) / price_before, 0)) < 0.8 THEN 'moderate'
      ELSE 'elastic'
    END,
    LEAST(actual_days_before, actual_days_after),
    CASE 
      WHEN LEAST(actual_days_before, actual_days_after) >= 60 THEN 'high'
      WHEN LEAST(actual_days_before, actual_days_after) >= 30 THEN 'medium'
      ELSE 'low'
    END
  FROM (
    SELECT DISTINCT ON (curr.service_code, prev.price, curr.price)
      curr.service_code,
      prev.price as price_before,
      curr.price as price_after,
      -- Daily rate = total transactions / actual calendar days in the period
      -- Before: from when prev price started (or 30 days before change, whichever is shorter) to change date
      CASE WHEN (curr.first_seen::date - GREATEST(prev.first_seen, curr.first_seen - INTERVAL '30 days')::date) > 0
           THEN vol_before_total::numeric / (curr.first_seen::date - GREATEST(prev.first_seen, curr.first_seen - INTERVAL '30 days')::date)
           ELSE 0 END as daily_rate_before,
      CASE WHEN (LEAST(curr.last_seen, curr.first_seen + INTERVAL '30 days')::date - curr.first_seen::date) > 0
           THEN vol_after_total::numeric / (LEAST(curr.last_seen, curr.first_seen + INTERVAL '30 days')::date - curr.first_seen::date)
           ELSE 0 END as daily_rate_after,
      (curr.first_seen::date - GREATEST(prev.first_seen, curr.first_seen - INTERVAL '30 days')::date) as actual_days_before,
      (LEAST(curr.last_seen, curr.first_seen + INTERVAL '30 days')::date - curr.first_seen::date) as actual_days_after,
      vol_before_total,
      vol_after_total
    FROM (
      SELECT
        curr.service_code,
        prev.price as price_before_val,
        curr.price as price_after_val,
        prev.first_seen as prev_start,
        curr.first_seen as curr_start,
        curr.last_seen as curr_end,
        (SELECT COUNT(*) FROM std_transactions t WHERE t.clinic_id = p_clinic_id AND t.service_code = curr.service_code
         AND t.txn_date >= GREATEST(prev.first_seen, curr.first_seen - INTERVAL '30 days')
         AND t.txn_date < curr.first_seen AND t.amount > 0) as vol_before_total,
        (SELECT COUNT(*) FROM std_transactions t WHERE t.clinic_id = p_clinic_id AND t.service_code = curr.service_code
         AND t.txn_date >= curr.first_seen
         AND t.txn_date < LEAST(curr.last_seen + INTERVAL '1 day', curr.first_seen + INTERVAL '30 days')
         AND t.amount > 0) as vol_after_total,
        curr, prev
      FROM std_price_history curr
      JOIN std_price_history prev ON prev.service_code = curr.service_code
        AND prev.clinic_id = p_clinic_id AND curr.clinic_id = p_clinic_id
        AND prev.last_seen < curr.first_seen AND prev.id != curr.id
      WHERE curr.clinic_id = p_clinic_id AND curr.price != prev.price AND prev.price > 0
        AND NOT EXISTS (
          SELECT 1 FROM std_price_history mid WHERE mid.service_code = curr.service_code AND mid.clinic_id = p_clinic_id
          AND mid.first_seen > prev.first_seen AND mid.first_seen < curr.first_seen
        )
    ) raw,
    LATERAL (
      SELECT raw.curr.service_code, raw.prev.price as price_before, raw.curr.price as price_after,
            raw.curr.first_seen, raw.curr.last_seen
    ) curr,
    LATERAL (
      SELECT raw.prev.first_seen
    ) prev
    ORDER BY raw.curr.service_code, raw.prev.price, raw.curr.price, raw.curr.first_seen DESC
  ) changes
  WHERE daily_rate_before > 0 OR daily_rate_after > 0;

  GET DIAGNOSTICS computed = ROW_COUNT;
  RETURN jsonb_build_object(
    'clinic_id', p_clinic_id,
    'elasticity_records', computed,
    'inelastic', (SELECT COUNT(*) FROM std_elasticity WHERE clinic_id = p_clinic_id AND elasticity_label = 'inelastic'),
    'moderate', (SELECT COUNT(*) FROM std_elasticity WHERE clinic_id = p_clinic_id AND elasticity_label = 'moderate'),
    'elastic', (SELECT COUNT(*) FROM std_elasticity WHERE clinic_id = p_clinic_id AND elasticity_label = 'elastic'),
    'unknown', (SELECT COUNT(*) FROM std_elasticity WHERE clinic_id = p_clinic_id AND elasticity_label = 'unknown')
  );
END;
$_$;
