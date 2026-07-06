-- Drop and recreate with correct signature
DROP FUNCTION IF EXISTS compute_daily_kpis(TEXT, DATE, DATE);
DROP FUNCTION IF EXISTS compute_daily_kpis(TEXT);

CREATE OR REPLACE FUNCTION compute_daily_kpis(p_clinic_id TEXT, p_start_date DATE, p_end_date DATE)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER AS $_$
BEGIN
  DELETE FROM std_daily_kpis 
  WHERE clinic_id = p_clinic_id AND day >= p_start_date AND day <= p_end_date;

  INSERT INTO std_daily_kpis (
    clinic_id, day, total_revenue, total_transactions, total_visits,
    avg_invoice_value, new_clients, total_vaccines, total_appointments, unique_services
  )
  SELECT 
    p_clinic_id, d.day,
    COALESCE(rev.total, 0), COALESCE(rev.txns, 0), COALESCE(vis.cnt, 0),
    CASE WHEN COALESCE(vis.cnt, 0) > 0 THEN ROUND(COALESCE(rev.total, 0) / vis.cnt, 2) ELSE 0 END,
    COALESCE(nc.cnt, 0), COALESCE(vax.cnt, 0), COALESCE(appt.cnt, 0), COALESCE(svc.cnt, 0)
  FROM generate_series(p_start_date, p_end_date, '1 day'::interval) d(day)
  LEFT JOIN (SELECT txn_date::date as dd, SUM(amount) as total, COUNT(*) as txns FROM std_transactions WHERE clinic_id = p_clinic_id AND amount > 0 GROUP BY txn_date::date) rev ON rev.dd = d.day::date
  LEFT JOIN (SELECT visit_date::date as dd, COUNT(*) as cnt FROM std_visits WHERE clinic_id = p_clinic_id GROUP BY visit_date::date) vis ON vis.dd = d.day::date
  LEFT JOIN (SELECT first_visit::date as dd, COUNT(*) as cnt FROM (SELECT client_id, MIN(visit_date)::date as first_visit FROM std_visits WHERE clinic_id = p_clinic_id GROUP BY client_id) fv GROUP BY first_visit::date) nc ON nc.dd = d.day::date
  LEFT JOIN (SELECT vaccine_date::date as dd, COUNT(*) as cnt FROM std_vaccines WHERE clinic_id = p_clinic_id GROUP BY vaccine_date::date) vax ON vax.dd = d.day::date
  LEFT JOIN (SELECT appointment_date::date as dd, COUNT(*) as cnt FROM std_appointments WHERE clinic_id = p_clinic_id GROUP BY appointment_date::date) appt ON appt.dd = d.day::date
  LEFT JOIN (SELECT txn_date::date as dd, COUNT(DISTINCT service_code) as cnt FROM std_transactions WHERE clinic_id = p_clinic_id AND amount > 0 GROUP BY txn_date::date) svc ON svc.dd = d.day::date;
END;
$_$;
