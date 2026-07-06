-- Shoppability metric: how often a service appears on a small invoice (≤2 services)
-- High ratio = clients price-shop it (exams, vaccines)
-- Low ratio = blind purchase (urinalysis, sedation, lab work)

CREATE TABLE std_shoppability (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  clinic_id TEXT NOT NULL,
  service_code TEXT NOT NULL,
  service_name TEXT,
  total_visits INT NOT NULL DEFAULT 0,
  standalone_visits INT NOT NULL DEFAULT 0,    -- visits where service had ≤2 total services
  shoppability_score NUMERIC NOT NULL DEFAULT 0, -- standalone_visits / total_visits (0-1)
  visibility_label TEXT NOT NULL DEFAULT 'unknown', -- shoppable, moderate, blind
  avg_invoice_size NUMERIC,                     -- avg total services on invoices containing this
  created_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(clinic_id, service_code)
);

ALTER TABLE std_shoppability ENABLE ROW LEVEL SECURITY;
CREATE POLICY "auth_shop" ON std_shoppability FOR SELECT USING (clinic_id IN (SELECT clinic_id FROM meta_clinic_users WHERE user_id = auth.uid()));
CREATE POLICY "svc_shop" ON std_shoppability FOR ALL USING (true) WITH CHECK (true);
CREATE INDEX idx_shop_clinic ON std_shoppability(clinic_id);

CREATE OR REPLACE FUNCTION compute_shoppability(p_clinic_id TEXT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $_$
DECLARE
  computed INT;
BEGIN
  DELETE FROM std_shoppability WHERE clinic_id = p_clinic_id;

  INSERT INTO std_shoppability (
    clinic_id, service_code, service_name,
    total_visits, standalone_visits, shoppability_score, visibility_label, avg_invoice_size
  )
  WITH service_visits AS (
    SELECT 
      t.service_code,
      sp.service_name,
      t.ref_id AS visit_id,
      COUNT(*) OVER (PARTITION BY t.ref_id) AS services_on_invoice,
      SUM(CASE WHEN t.amount > 0 THEN 1 ELSE 0 END) OVER (PARTITION BY t.ref_id) AS billable_on_invoice
    FROM std_transactions t
    LEFT JOIN std_service_prices sp ON sp.clinic_id = t.clinic_id AND sp.service_code = t.service_code
    WHERE t.clinic_id = p_clinic_id AND t.amount > 0
  ),
  classified AS (
    SELECT 
      service_code,
      MAX(service_name) AS service_name,
      COUNT(DISTINCT visit_id) AS total_visits,
      COUNT(DISTINCT CASE WHEN billable_on_invoice <= 2 THEN visit_id END) AS standalone_visits,
      AVG(billable_on_invoice::numeric) AS avg_invoice_size
    FROM service_visits
    GROUP BY service_code
  )
  SELECT 
    p_clinic_id,
    service_code,
    service_name,
    total_visits,
    standalone_visits,
    CASE WHEN total_visits > 0 THEN ROUND(standalone_visits::numeric / total_visits, 3) ELSE 0 END,
    CASE 
      WHEN total_visits = 0 THEN 'unknown'
      WHEN standalone_visits::numeric / total_visits >= 0.5 THEN 'shoppable'
      WHEN standalone_visits::numeric / total_visits >= 0.25 THEN 'moderate'
      ELSE 'blind'
    END,
    ROUND(avg_invoice_size, 1)
  FROM classified
  WHERE total_visits >= 5;  -- minimum 5 visits to classify

  GET DIAGNOSTICS computed = ROW_COUNT;

  RETURN jsonb_build_object(
    'clinic_id', p_clinic_id,
    'services_classified', computed,
    'shoppable', (SELECT COUNT(*) FROM std_shoppability WHERE clinic_id = p_clinic_id AND visibility_label = 'shoppable'),
    'moderate', (SELECT COUNT(*) FROM std_shoppability WHERE clinic_id = p_clinic_id AND visibility_label = 'moderate'),
    'blind', (SELECT COUNT(*) FROM std_shoppability WHERE clinic_id = p_clinic_id AND visibility_label = 'blind')
  );
END;
$_$;
