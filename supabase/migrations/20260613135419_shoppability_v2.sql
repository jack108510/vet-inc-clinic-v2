-- Shoppability v2: Group by date + sequential txn_id to reconstruct visits
CREATE OR REPLACE FUNCTION compute_shoppability(p_clinic_id TEXT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $_$
DECLARE
  computed INT;
BEGIN
  DELETE FROM std_shoppability WHERE clinic_id = p_clinic_id;

  -- Create temp table mapping each transaction to a reconstructed visit key
  -- Visit key = date + cluster of sequential txn_ids (gap <= 3)
  CREATE TEMP TABLE _visit_map AS
  WITH numbered AS (
    SELECT *,
      ROW_NUMBER() OVER (PARTITION BY txn_date ORDER BY txn_id) AS rn,
      -- Extract numeric part of txn_id for gap detection
      CAST(REGEXP_REPLACE(txn_id, '[^0-9]', '', 'g') AS BIGINT) AS txn_num
    FROM std_transactions
    WHERE clinic_id = p_clinic_id AND amount > 0
  ),
  gaps AS (
    SELECT *,
      txn_num - LAG(txn_num) OVER (PARTITION BY txn_date ORDER BY txn_num) AS gap,
      -- New visit when gap > 3 or first row
      CASE 
        WHEN txn_num - LAG(txn_num) OVER (PARTITION BY txn_date ORDER BY txn_num) > 3 THEN 1
        ELSE 0 
      END AS is_new_visit
    FROM numbered
  ),
  visit_groups AS (
    SELECT *,
      SUM(is_new_visit) OVER (PARTITION BY txn_date ORDER BY txn_num) AS visit_seq
    FROM gaps
  )
  SELECT 
    id, service_code, txn_date,
    txn_date::text || '_v' || visit_seq AS visit_key
  FROM visit_groups;

  CREATE INDEX ON _visit_map(service_code);
  CREATE INDEX ON _visit_map(visit_key);

  -- Compute shoppability per service
  INSERT INTO std_shoppability (
    clinic_id, service_code, service_name,
    total_visits, standalone_visits, shoppability_score, visibility_label, avg_invoice_size
  )
  WITH visit_sizes AS (
    SELECT visit_key, COUNT(*) AS services_on_visit
    FROM _visit_map
    GROUP BY visit_key
  ),
  service_stats AS (
    SELECT 
      vm.service_code,
      MAX(sp.service_name) AS service_name,
      COUNT(DISTINCT vm.visit_key) AS total_visits,
      COUNT(DISTINCT CASE WHEN vs.services_on_visit <= 2 THEN vm.visit_key END) AS standalone_visits,
      AVG(vs.services_on_visit::numeric) AS avg_invoice_size
    FROM _visit_map vm
    LEFT JOIN std_service_prices sp ON sp.clinic_id = p_clinic_id AND sp.service_code = vm.service_code
    JOIN visit_sizes vs ON vs.visit_key = vm.visit_key
    GROUP BY vm.service_code
  )
  SELECT 
    p_clinic_id, service_code, service_name, total_visits, standalone_visits,
    CASE WHEN total_visits > 0 THEN ROUND(standalone_visits::numeric / total_visits, 3) ELSE 0 END,
    CASE 
      WHEN total_visits = 0 THEN 'unknown'
      WHEN standalone_visits::numeric / total_visits >= 0.5 THEN 'shoppable'
      WHEN standalone_visits::numeric / total_visits >= 0.25 THEN 'moderate'
      ELSE 'blind'
    END,
    ROUND(avg_invoice_size, 1)
  FROM service_stats
  WHERE total_visits >= 5;

  GET DIAGNOSTICS computed = ROW_COUNT;
  DROP TABLE _visit_map;

  RETURN jsonb_build_object(
    'clinic_id', p_clinic_id,
    'services_classified', computed,
    'shoppable', (SELECT COUNT(*) FROM std_shoppability WHERE clinic_id = p_clinic_id AND visibility_label = 'shoppable'),
    'moderate', (SELECT COUNT(*) FROM std_shoppability WHERE clinic_id = p_clinic_id AND visibility_label = 'moderate'),
    'blind', (SELECT COUNT(*) FROM std_shoppability WHERE clinic_id = p_clinic_id AND visibility_label = 'blind')
  );
END;
$_$;
