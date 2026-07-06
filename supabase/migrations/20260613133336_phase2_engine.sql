-- ============================================================
-- PHASE 2: PRICING ENGINE
-- Separate from Phase 1. Reads from Phase 1 tables, writes to own tables.
-- ============================================================

-- Elasticity table: demand curves computed from historical price changes
CREATE TABLE std_elasticity (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  clinic_id TEXT NOT NULL,
  service_code TEXT NOT NULL,
  price_before NUMERIC(10,2),
  price_after NUMERIC(10,2),
  price_change_pct NUMERIC,        -- % change in price
  volume_before INT,               -- avg daily volume at old price
  volume_after INT,                -- avg daily volume at new price
  volume_change_pct NUMERIC,        -- % change in volume
  elasticity NUMERIC,              -- volume_change_pct / price_change_pct
  elasticity_label TEXT,           -- inelastic, moderate, elastic, unknown
  measured_days INT,               -- how many days of data used
  confidence TEXT,                 -- high, medium, low
  created_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(clinic_id, service_code, price_before, price_after)
);

ALTER TABLE std_elasticity ENABLE ROW LEVEL SECURITY;
CREATE POLICY "auth_elasticity" ON std_elasticity FOR SELECT USING (clinic_id IN (SELECT clinic_id FROM meta_clinic_users WHERE user_id = auth.uid()));
CREATE POLICY "svc_role_elasticity" ON std_elasticity FOR ALL USING (true) WITH CHECK (true);
CREATE INDEX idx_elastic_clinic ON std_elasticity(clinic_id);

-- Price experiments table
CREATE TABLE std_price_experiments (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  clinic_id TEXT NOT NULL,
  service_code TEXT NOT NULL,
  experiment_type TEXT DEFAULT 'inflation',  -- inflation, rounding, demand, margin, loss_leader
  old_price NUMERIC(10,2) NOT NULL,
  test_price NUMERIC(10,2) NOT NULL,
  change_pct NUMERIC NOT NULL,       -- percentage change (e.g. 2.5 = +2.5%)
  direction TEXT NOT NULL,           -- up, down
  start_date DATE NOT NULL,
  end_date DATE,                     -- null while running
  status TEXT DEFAULT 'pending',     -- pending, running, concluded, reverted, pushed
  -- Baseline (30 days before test)
  baseline_revenue NUMERIC,
  baseline_volume INT,
  baseline_days INT,
  -- Test results
  test_revenue NUMERIC,
  test_volume INT,
  test_days INT,
  -- Decision
  revenue_change_pct NUMERIC,
  volume_change_pct NUMERIC,
  net_revenue_change NUMERIC,        -- absolute $ change
  decision TEXT,                     -- push, hold, revert, review
  decision_reason TEXT,
  decided_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE std_price_experiments ENABLE ROW LEVEL SECURITY;
CREATE POLICY "auth_exp_sel" ON std_price_experiments FOR SELECT USING (clinic_id IN (SELECT clinic_id FROM meta_clinic_users WHERE user_id = auth.uid()));
CREATE POLICY "auth_exp_upd" ON std_price_experiments FOR UPDATE USING (clinic_id IN (SELECT clinic_id FROM meta_clinic_users WHERE user_id = auth.uid() AND role IN ('owner','admin','editor')));
CREATE POLICY "svc_role_exp" ON std_price_experiments FOR ALL USING (true) WITH CHECK (true);
CREATE INDEX idx_exp_clinic ON std_price_experiments(clinic_id);
CREATE INDEX idx_exp_status ON std_price_experiments(clinic_id, status);

-- Experiment history (audit trail)
CREATE TABLE std_experiment_history (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  experiment_id BIGINT REFERENCES std_price_experiments(id) ON DELETE CASCADE,
  action TEXT NOT NULL,              -- started, extended, measured, concluded, reverted, pushed
  details JSONB,                     -- snapshot of all metrics at this point
  created_at TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE std_experiment_history ENABLE ROW LEVEL SECURITY;
CREATE POLICY "auth_exphist" ON std_experiment_history FOR SELECT USING (
  experiment_id IN (SELECT id FROM std_price_experiments WHERE clinic_id IN (SELECT clinic_id FROM meta_clinic_users WHERE user_id = auth.uid()))
);
CREATE POLICY "svc_role_exphist" ON std_experiment_history FOR ALL USING (true) WITH CHECK (true);

-- ============================================================
-- FUNCTION 1: Compute elasticity from historical price changes
-- Reads: std_price_history + std_transactions
-- Writes: std_elasticity
-- ============================================================

CREATE OR REPLACE FUNCTION compute_elasticity(p_clinic_id TEXT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $_$
DECLARE
  computed INT;
  cutoff DATE;
BEGIN
  DELETE FROM std_elasticity WHERE clinic_id = p_clinic_id;
  
  SELECT MAX(txn_date) - INTERVAL '30 days' INTO cutoff
  FROM std_transactions WHERE clinic_id = p_clinic_id;

  -- For each price change in history, measure what happened to volume
  INSERT INTO std_elasticity (
    clinic_id, service_code, price_before, price_after,
    price_change_pct, volume_before, volume_after, volume_change_pct,
    elasticity, elasticity_label, measured_days, confidence
  )
  SELECT 
    p_clinic_id,
    service_code,
    price_before,
    price_after,
    ROUND((price_after - price_before) / NULLIF(price_before, 0) * 100, 1),
    vol_before,
    vol_after,
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
    CASE 
      WHEN LEAST(days_before, days_after) >= 60 THEN 'high'
      WHEN LEAST(days_before, days_after) >= 30 THEN 'medium'
      ELSE 'low'
    END
  FROM (
    SELECT 
      curr.service_code,
      prev.price as price_before,
      curr.price as price_after,
      -- Volume at old price (30 days before change, capped at available data)
      (SELECT COUNT(*) FROM std_transactions t 
       WHERE t.clinic_id = p_clinic_id AND t.service_code = curr.service_code 
         AND t.txn_date >= GREATEST(prev.first_seen, curr.first_seen - INTERVAL '30 days')
         AND t.txn_date < curr.first_seen AND t.amount > 0) as vol_before,
      (SELECT COUNT(*) FROM std_transactions t 
       WHERE t.clinic_id = p_clinic_id AND t.service_code = curr.service_code 
         AND t.txn_date >= curr.first_seen 
         AND t.txn_date < LEAST(curr.last_seen + INTERVAL '1 day', curr.first_seen + INTERVAL '30 days')
         AND t.amount > 0) as vol_after,
      (SELECT LEAST(30, COUNT(DISTINCT txn_date::date)) FROM std_transactions t 
       WHERE t.clinic_id = p_clinic_id AND t.service_code = curr.service_code 
         AND t.txn_date >= GREATEST(prev.first_seen, curr.first_seen - INTERVAL '30 days')
         AND t.txn_date < curr.first_seen AND t.amount > 0) as days_before,
      (SELECT LEAST(30, COUNT(DISTINCT txn_date::date)) FROM std_transactions t 
       WHERE t.clinic_id = p_clinic_id AND t.service_code = curr.service_code 
         AND t.txn_date >= curr.first_seen 
         AND t.txn_date < LEAST(curr.last_seen + INTERVAL '1 day', curr.first_seen + INTERVAL '30 days')
         AND t.amount > 0) as days_after
    FROM std_price_history curr
    JOIN std_price_history prev ON prev.service_code = curr.service_code 
      AND prev.clinic_id = p_clinic_id AND curr.clinic_id = p_clinic_id
      AND prev.last_seen < curr.first_seen
      AND prev.id != curr.id
    WHERE curr.clinic_id = p_clinic_id
      AND curr.price != prev.price
      AND prev.price > 0
      AND NOT EXISTS (
        SELECT 1 FROM std_price_history mid 
        WHERE mid.service_code = curr.service_code AND mid.clinic_id = p_clinic_id
          AND mid.first_seen > prev.first_seen AND mid.first_seen < curr.first_seen
      )
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
