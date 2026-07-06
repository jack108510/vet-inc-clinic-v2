-- Fix role constraint to include owner
ALTER TABLE meta_clinic_users DROP CONSTRAINT IF EXISTS meta_clinic_users_role_check;
ALTER TABLE meta_clinic_users ADD CONSTRAINT meta_clinic_users_role_check 
  CHECK (role IN ('owner', 'admin', 'editor', 'viewer'));

-- Update Jack to owner
UPDATE meta_clinic_users SET role = 'owner' 
WHERE user_id = 'f92d3323-3cbb-4030-a4f3-d51943c0caad' AND clinic_id = 'rosslyn';

-- RLS policies (idempotent via DO blocks)
DO $_$ BEGIN
  CREATE POLICY "Users see own memberships" ON meta_clinic_users FOR SELECT USING (user_id = auth.uid());
EXCEPTION WHEN duplicate_object THEN NULL;
END $_$;

DO $_$ BEGIN
  CREATE POLICY "Service role full mcu" ON meta_clinic_users FOR ALL USING (true) WITH CHECK (true);
EXCEPTION WHEN duplicate_object THEN NULL;
END $_$;

CREATE OR REPLACE FUNCTION user_has_clinic(p_user_id UUID, p_clinic_id TEXT)
RETURNS BOOLEAN AS $_$
  SELECT EXISTS (SELECT 1 FROM meta_clinic_users WHERE user_id = p_user_id AND clinic_id = p_clinic_id);
$_$ LANGUAGE sql SECURITY DEFINER STABLE;

-- std_ table RLS policies
DO $_$ BEGIN CREATE POLICY "auth_kpi" ON std_daily_kpis FOR SELECT USING (clinic_id IN (SELECT clinic_id FROM meta_clinic_users WHERE user_id = auth.uid())); EXCEPTION WHEN duplicate_object THEN NULL; END $_$;
DO $_$ BEGIN CREATE POLICY "auth_queue_sel" ON std_approval_queue FOR SELECT USING (clinic_id IN (SELECT clinic_id FROM meta_clinic_users WHERE user_id = auth.uid())); EXCEPTION WHEN duplicate_object THEN NULL; END $_$;
DO $_$ BEGIN CREATE POLICY "auth_queue_upd" ON std_approval_queue FOR UPDATE USING (clinic_id IN (SELECT clinic_id FROM meta_clinic_users WHERE user_id = auth.uid() AND role IN ('owner','admin','editor'))); EXCEPTION WHEN duplicate_object THEN NULL; END $_$;
DO $_$ BEGIN CREATE POLICY "auth_prices" ON std_service_prices FOR SELECT USING (clinic_id IN (SELECT clinic_id FROM meta_clinic_users WHERE user_id = auth.uid())); EXCEPTION WHEN duplicate_object THEN NULL; END $_$;
DO $_$ BEGIN CREATE POLICY "auth_phist" ON std_price_history FOR SELECT USING (clinic_id IN (SELECT clinic_id FROM meta_clinic_users WHERE user_id = auth.uid())); EXCEPTION WHEN duplicate_object THEN NULL; END $_$;
DO $_$ BEGIN CREATE POLICY "auth_txn" ON std_transactions FOR SELECT USING (clinic_id IN (SELECT clinic_id FROM meta_clinic_users WHERE user_id = auth.uid())); EXCEPTION WHEN duplicate_object THEN NULL; END $_$;
DO $_$ BEGIN CREATE POLICY "auth_visits" ON std_visits FOR SELECT USING (clinic_id IN (SELECT clinic_id FROM meta_clinic_users WHERE user_id = auth.uid())); EXCEPTION WHEN duplicate_object THEN NULL; END $_$;
DO $_$ BEGIN CREATE POLICY "auth_clients" ON std_clients FOR SELECT USING (clinic_id IN (SELECT clinic_id FROM meta_clinic_users WHERE user_id = auth.uid())); EXCEPTION WHEN duplicate_object THEN NULL; END $_$;
DO $_$ BEGIN CREATE POLICY "auth_patients" ON std_patients FOR SELECT USING (clinic_id IN (SELECT clinic_id FROM meta_clinic_users WHERE user_id = auth.uid())); EXCEPTION WHEN duplicate_object THEN NULL; END $_$;
DO $_$ BEGIN CREATE POLICY "auth_services" ON std_services FOR SELECT USING (clinic_id IN (SELECT clinic_id FROM meta_clinic_users WHERE user_id = auth.uid())); EXCEPTION WHEN duplicate_object THEN NULL; END $_$;
DO $_$ BEGIN CREATE POLICY "auth_results" ON std_campaign_results FOR SELECT USING (clinic_id IN (SELECT clinic_id FROM meta_clinic_users WHERE user_id = auth.uid())); EXCEPTION WHEN duplicate_object THEN NULL; END $_$;
DO $_$ BEGIN CREATE POLICY "auth_baselines" ON std_service_baselines FOR SELECT USING (clinic_id IN (SELECT clinic_id FROM meta_clinic_users WHERE user_id = auth.uid())); EXCEPTION WHEN duplicate_object THEN NULL; END $_$;
DO $_$ BEGIN CREATE POLICY "auth_vax" ON std_vaccines FOR SELECT USING (clinic_id IN (SELECT clinic_id FROM meta_clinic_users WHERE user_id = auth.uid())); EXCEPTION WHEN duplicate_object THEN NULL; END $_$;
DO $_$ BEGIN CREATE POLICY "auth_appt" ON std_appointments FOR SELECT USING (clinic_id IN (SELECT clinic_id FROM meta_clinic_users WHERE user_id = auth.uid())); EXCEPTION WHEN duplicate_object THEN NULL; END $_$;
