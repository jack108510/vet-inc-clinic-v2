-- Fix: remove unique constraint, use ON CONFLICT DO UPDATE instead
ALTER TABLE std_elasticity DROP CONSTRAINT IF EXISTS std_elasticity_clinic_id_service_code_price_before_price_af_key;

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
    vol_before, vol_after,
    CASE WHEN vol_before > 0 THEN ROUND((vol_after - vol_before)::numeric / vol_before * 100, 1) ELSE NULL END,
    CASE WHEN vol_before > 0 AND price_before > 0 THEN
      ROUND(((vol_after - vol_before)::numeric / vol_before) / NULLIF((price_after - price_before) / price_before, 0), 3)
    END,
    CASE 
      WHEN vol_before = 0 OR price_before = 0 THEN 'unknown'
      WHEN ABS(((vol_after - vol_before)::numeric / vol_before) / NULLIF((price_after - price_before) / price_before, 0)) < 0.3 THEN 'inelastic'
      WHEN ABS(((vol_after - vol_before)::numeric / vol_before) / NULLIF((price_after - price_before) / price_before, 0)) < 0.8 THEN 'moderate'
      ELSE 'elastic'
    END,
    LEAST(days_before, days_after),
    CASE WHEN LEAST(days_before, days_after) >= 60 THEN 'high' WHEN LEAST(days_before, days_after) >= 30 THEN 'medium' ELSE 'low' END
  FROM (
    SELECT DISTINCT ON (curr.service_code, prev.price, curr.price)
      curr.service_code, prev.price as price_before, curr.price as price_after,
      (SELECT COUNT(*) FROM std_transactions t WHERE t.clinic_id = p_clinic_id AND t.service_code = curr.service_code AND t.txn_date >= GREATEST(prev.first_seen, curr.first_seen - INTERVAL '30 days') AND t.txn_date < curr.first_seen AND t.amount > 0) as vol_before,
      (SELECT COUNT(*) FROM std_transactions t WHERE t.clinic_id = p_clinic_id AND t.service_code = curr.service_code AND t.txn_date >= curr.first_seen AND t.txn_date < LEAST(curr.last_seen + INTERVAL '1 day', curr.first_seen + INTERVAL '30 days') AND t.amount > 0) as vol_after,
      (SELECT LEAST(30, COUNT(DISTINCT txn_date::date)) FROM std_transactions t WHERE t.clinic_id = p_clinic_id AND t.service_code = curr.service_code AND t.txn_date >= GREATEST(prev.first_seen, curr.first_seen - INTERVAL '30 days') AND t.txn_date < curr.first_seen AND t.amount > 0) as days_before,
      (SELECT LEAST(30, COUNT(DISTINCT txn_date::date)) FROM std_transactions t WHERE t.clinic_id = p_clinic_id AND t.service_code = curr.service_code AND t.txn_date >= curr.first_seen AND t.txn_date < LEAST(curr.last_seen + INTERVAL '1 day', curr.first_seen + INTERVAL '30 days') AND t.amount > 0) as days_after
    FROM std_price_history curr
    JOIN std_price_history prev ON prev.service_code = curr.service_code AND prev.clinic_id = p_clinic_id AND curr.clinic_id = p_clinic_id AND prev.last_seen < curr.first_seen AND prev.id != curr.id
    WHERE curr.clinic_id = p_clinic_id AND curr.price != prev.price AND prev.price > 0
      AND NOT EXISTS (SELECT 1 FROM std_price_history mid WHERE mid.service_code = curr.service_code AND mid.clinic_id = p_clinic_id AND mid.first_seen > prev.first_seen AND mid.first_seen < curr.first_seen)
    ORDER BY curr.service_code, prev.price, curr.price, curr.first_seen DESC
  ) changes
  WHERE vol_before > 0 OR vol_after > 0;

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
