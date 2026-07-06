-- Fix: new_clients must check ALL history, not just the compute range
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
    COALESCE(v.visits, 0) AS invoice_count,
    CASE WHEN COALESCE(v.visits, 0) > 0 THEN ROUND(d.revenue / v.visits, 2) ELSE 0 END AS avg_invoice_value,
    COALESCE(nc.new_clients, 0),
    COALESCE(v.visits, 0),
    COALESCE(vx.vaccines, 0),
    COALESCE(a.appts, 0),
    COALESCE(d.unique_svcs, 0)
  FROM (
    SELECT 
      txn_date AS day,
      SUM(amount) AS revenue,
      COUNT(*) AS txn_count,
      COUNT(DISTINCT service_code) AS unique_svcs
    FROM std_transactions
    WHERE clinic_id = p_clinic_id
      AND txn_date >= p_start_date
      AND txn_date < p_end_date
      AND amount > 0
    GROUP BY txn_date
  ) d
  LEFT JOIN (
    SELECT visit_date AS day, COUNT(*) AS visits
    FROM std_visits
    WHERE clinic_id = p_clinic_id
      AND visit_date >= p_start_date
      AND visit_date < p_end_date
    GROUP BY visit_date
  ) v ON v.day = d.day
  LEFT JOIN (
    -- New clients: look at ALL visits to find true first visit date
    -- Only count if that first visit falls within our compute range
    SELECT first_visit AS day, COUNT(*) AS new_clients
    FROM (
      SELECT client_id, MIN(visit_date) AS first_visit
      FROM std_visits
      WHERE clinic_id = p_clinic_id
        AND client_id IS NOT NULL
      GROUP BY client_id
    ) sub
    WHERE first_visit >= p_start_date AND first_visit < p_end_date
    GROUP BY first_visit
  ) nc ON nc.day = d.day
  LEFT JOIN (
    SELECT vaccine_date AS day, COUNT(*) AS vaccines
    FROM std_vaccines
    WHERE clinic_id = p_clinic_id
      AND vaccine_date >= p_start_date
      AND vaccine_date < p_end_date
    GROUP BY vaccine_date
  ) vx ON vx.day = d.day
  LEFT JOIN (
    SELECT appointment_date AS day, COUNT(*) AS appts
    FROM std_appointments
    WHERE clinic_id = p_clinic_id
      AND appointment_date >= p_start_date
      AND appointment_date < p_end_date
    GROUP BY appointment_date
  ) a ON a.day = d.day
  ORDER BY d.day;
  
  GET DIAGNOSTICS inserted = ROW_COUNT;
  RETURN inserted;
END;
$$;
