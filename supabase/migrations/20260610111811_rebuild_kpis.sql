-- Drop old table and rebuild with correct schema
DROP TABLE IF EXISTS std_daily_kpis CASCADE;

CREATE TABLE std_daily_kpis (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  clinic_id TEXT NOT NULL,
  day DATE NOT NULL,
  total_revenue NUMERIC(12,2),        -- sum of all positive amounts that day
  total_transactions INTEGER,          -- count of line items
  invoice_count INTEGER,               -- count of distinct txn_id (complete invoices)
  avg_invoice_value NUMERIC(10,2),     -- total_revenue / invoice_count
  new_clients INTEGER DEFAULT 0,       -- clients created that day
  total_visits INTEGER DEFAULT 0,      -- visits that day
  total_vaccines INTEGER DEFAULT 0,    -- vaccines administered that day
  total_appointments INTEGER DEFAULT 0,-- appointments that day
  unique_services INTEGER DEFAULT 0,   -- distinct service_codes sold that day
  computed_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(clinic_id, day)
);

ALTER TABLE std_daily_kpis ENABLE ROW LEVEL SECURITY;
CREATE POLICY "service_role_full" ON std_daily_kpis FOR ALL 
  USING (auth.role() = 'service_role') WITH CHECK (auth.role() = 'service_role');
CREATE POLICY "users_read_own" ON std_daily_kpis FOR SELECT 
  USING (clinic_id IN (SELECT clinic_id FROM meta_clinic_users WHERE user_id = auth.uid()));

CREATE INDEX idx_kpis_clinic_day ON std_daily_kpis(clinic_id, day DESC);

-- Compute function
CREATE OR REPLACE FUNCTION compute_daily_kpis(p_clinic_id TEXT, p_start_date DATE, p_end_date DATE)
RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  inserted BIGINT;
BEGIN
  DELETE FROM std_daily_kpis 
  WHERE clinic_id = p_clinic_id AND day >= p_start_date AND day < p_end_date;
  
  INSERT INTO std_daily_kpis (
    clinic_id, day, total_revenue, total_transactions, invoice_count, avg_invoice_value,
    new_clients, total_visits, total_vaccines, total_appointments, unique_services
  )
  SELECT 
    p_clinic_id,
    d.day,
    d.revenue,
    d.txn_count,
    d.invoice_count,
    CASE WHEN d.invoice_count > 0 THEN ROUND(d.revenue / d.invoice_count, 2) ELSE 0 END,
    COALESCE(c.new_clients, 0),
    COALESCE(v.visits, 0),
    COALESCE(vx.vaccines, 0),
    COALESCE(a.appts, 0),
    COALESCE(d.unique_svcs, 0)
  FROM (
    SELECT 
      txn_date AS day,
      SUM(amount) AS revenue,
      COUNT(*) AS txn_count,
      COUNT(DISTINCT txn_id) AS invoice_count,
      COUNT(DISTINCT service_code) AS unique_svcs
    FROM std_transactions
    WHERE clinic_id = p_clinic_id
      AND txn_date >= p_start_date
      AND txn_date < p_end_date
      AND amount > 0
    GROUP BY txn_date
  ) d
  LEFT JOIN (
    SELECT created_at::date AS day, COUNT(*) AS new_clients
    FROM std_clients
    WHERE clinic_id = p_clinic_id
      AND created_at >= p_start_date
      AND created_at < p_end_date
    GROUP BY created_at::date
  ) c ON c.day = d.day
  LEFT JOIN (
    SELECT visit_date AS day, COUNT(*) AS visits
    FROM std_visits
    WHERE clinic_id = p_clinic_id
      AND visit_date >= p_start_date
      AND visit_date < p_end_date
    GROUP BY visit_date
  ) v ON v.day = d.day
  LEFT JOIN (
    SELECT vaccine_date AS day, COUNT(*) AS vaccines
    FROM std_vaccines
    WHERE clinic_id = p_clinic_id
      AND vaccine_date >= p_start_date
      AND vaccine_date < p_end_date
    GROUP BY vaccine_date
  ) vx ON vx.day = d.day
  LEFT JOIN (
    SELECT appt_date AS day, COUNT(*) AS appts
    FROM std_appointments
    WHERE clinic_id = p_clinic_id
      AND appt_date >= p_start_date
      AND appt_date < p_end_date
    GROUP BY appt_date
  ) a ON a.day = d.day
  ORDER BY d.day;
  
  GET DIAGNOSTICS inserted = ROW_COUNT;
  RETURN inserted;
END;
$$;
