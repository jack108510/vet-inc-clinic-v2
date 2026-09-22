-- Enterprise workflow records are isolated from the legacy clinic pricing tables.
-- This migration intentionally seeds no organizations, members, clinics, changes or prices.
-- DEPLOY-SPLIT
CREATE TABLE IF NOT EXISTS public.enterprise_orgs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), name text NOT NULL CHECK (length(trim(name)) BETWEEN 2 AND 120),
  created_by uuid NOT NULL REFERENCES auth.users(id), created_at timestamptz NOT NULL DEFAULT now()
);
-- DEPLOY-SPLIT
CREATE TABLE IF NOT EXISTS public.enterprise_members (
  org_id uuid NOT NULL REFERENCES public.enterprise_orgs(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users(id),
  member_email text NOT NULL,
  role text NOT NULL CHECK (role IN ('admin','pricing','finance','operations','viewer')),
  created_at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY(org_id,user_id)
);
-- DEPLOY-SPLIT
CREATE TABLE IF NOT EXISTS public.enterprise_changes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),org_id uuid NOT NULL REFERENCES public.enterprise_orgs(id) ON DELETE CASCADE,
  title text NOT NULL CHECK (length(trim(title)) BETWEEN 3 AND 160),
  description text NOT NULL DEFAULT '' CHECK (length(description)<=4000),
  effective_date date, status text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','review','approved','rollout','confirmed')),
  owner_id uuid NOT NULL DEFAULT auth.uid() REFERENCES auth.users(id),
  created_at timestamptz NOT NULL DEFAULT now(),updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(id,org_id)
);
-- DEPLOY-SPLIT
CREATE TABLE IF NOT EXISTS public.enterprise_tasks (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),org_id uuid NOT NULL,change_id uuid NOT NULL,
  title text NOT NULL CHECK (length(trim(title)) BETWEEN 3 AND 250),
  assigned_to uuid, status text NOT NULL DEFAULT 'open' CHECK (status IN ('open','done')),
  created_by uuid NOT NULL DEFAULT auth.uid() REFERENCES auth.users(id),created_at timestamptz NOT NULL DEFAULT now(),completed_at timestamptz,
  FOREIGN KEY(change_id,org_id) REFERENCES public.enterprise_changes(id,org_id) ON DELETE CASCADE,
  FOREIGN KEY(org_id,assigned_to) REFERENCES public.enterprise_members(org_id,user_id)
);
-- DEPLOY-SPLIT
CREATE TABLE IF NOT EXISTS public.enterprise_locations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),org_id uuid NOT NULL,change_id uuid NOT NULL,
  name text NOT NULL CHECK (length(trim(name)) BETWEEN 2 AND 180),
  state text NOT NULL DEFAULT 'pending' CHECK (state IN ('pending','ready','held','confirmed')),
  implementation_method text CHECK (implementation_method IN ('manual','verified_integration')),
  confirmed_by uuid REFERENCES auth.users(id),confirmed_at timestamptz,
  FOREIGN KEY(change_id,org_id) REFERENCES public.enterprise_changes(id,org_id) ON DELETE CASCADE
);
-- DEPLOY-SPLIT
CREATE TABLE IF NOT EXISTS public.enterprise_approvals (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),org_id uuid NOT NULL,change_id uuid NOT NULL,
  actor_id uuid NOT NULL REFERENCES auth.users(id),decision text NOT NULL CHECK(decision IN ('approved','returned')),
  note text NOT NULL DEFAULT '',created_at timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY(change_id,org_id) REFERENCES public.enterprise_changes(id,org_id) ON DELETE CASCADE
);
-- DEPLOY-SPLIT
CREATE TABLE IF NOT EXISTS public.enterprise_events (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,org_id uuid NOT NULL,change_id uuid,
  actor_id uuid NOT NULL REFERENCES auth.users(id),action text NOT NULL,detail text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY(change_id,org_id) REFERENCES public.enterprise_changes(id,org_id) ON DELETE CASCADE
);
-- DEPLOY-SPLIT
CREATE INDEX IF NOT EXISTS enterprise_changes_org_idx ON public.enterprise_changes(org_id,created_at DESC);
-- DEPLOY-SPLIT
CREATE INDEX IF NOT EXISTS enterprise_tasks_change_idx ON public.enterprise_tasks(change_id);
-- DEPLOY-SPLIT
CREATE INDEX IF NOT EXISTS enterprise_locations_change_idx ON public.enterprise_locations(change_id);
-- DEPLOY-SPLIT
CREATE INDEX IF NOT EXISTS enterprise_events_change_idx ON public.enterprise_events(change_id,created_at DESC);
-- DEPLOY-SPLIT
CREATE OR REPLACE FUNCTION public.enterprise_role(p_org uuid) RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT m.role FROM public.enterprise_members m WHERE m.org_id=p_org AND m.user_id=(SELECT auth.uid()) LIMIT 1
$$;
-- DEPLOY-SPLIT
REVOKE ALL ON FUNCTION public.enterprise_role(uuid) FROM PUBLIC,anon;
-- DEPLOY-SPLIT
GRANT EXECUTE ON FUNCTION public.enterprise_role(uuid) TO authenticated;
-- DEPLOY-SPLIT
DO $$ DECLARE t text; BEGIN FOREACH t IN ARRAY ARRAY['enterprise_orgs','enterprise_members','enterprise_changes','enterprise_tasks','enterprise_locations','enterprise_approvals','enterprise_events'] LOOP EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY',t); EXECUTE format('ALTER TABLE public.%I FORCE ROW LEVEL SECURITY',t); EXECUTE format('REVOKE ALL ON public.%I FROM PUBLIC, anon, authenticated',t); EXECUTE format('GRANT SELECT ON public.%I TO authenticated',t); END LOOP; END $$;
-- DEPLOY-SPLIT
CREATE POLICY enterprise_org_read ON public.enterprise_orgs FOR SELECT TO authenticated USING (public.enterprise_role(id) IS NOT NULL);
-- DEPLOY-SPLIT
CREATE POLICY enterprise_members_read ON public.enterprise_members FOR SELECT TO authenticated USING (public.enterprise_role(org_id) IS NOT NULL);
-- DEPLOY-SPLIT
CREATE POLICY enterprise_changes_read ON public.enterprise_changes FOR SELECT TO authenticated USING (public.enterprise_role(org_id) IS NOT NULL);
-- DEPLOY-SPLIT
CREATE POLICY enterprise_tasks_read ON public.enterprise_tasks FOR SELECT TO authenticated USING (public.enterprise_role(org_id) IS NOT NULL);
-- DEPLOY-SPLIT
CREATE POLICY enterprise_locations_read ON public.enterprise_locations FOR SELECT TO authenticated USING (public.enterprise_role(org_id) IS NOT NULL);
-- DEPLOY-SPLIT
CREATE POLICY enterprise_approvals_read ON public.enterprise_approvals FOR SELECT TO authenticated USING (public.enterprise_role(org_id) IS NOT NULL);
-- DEPLOY-SPLIT
CREATE POLICY enterprise_events_read ON public.enterprise_events FOR SELECT TO authenticated USING (public.enterprise_role(org_id) IS NOT NULL);
-- DEPLOY-SPLIT
CREATE OR REPLACE FUNCTION public.enterprise_create_org(p_name text) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_id uuid; BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
 IF length(trim(p_name)) NOT BETWEEN 2 AND 120 THEN RAISE EXCEPTION 'Organization name required'; END IF;
 INSERT INTO public.enterprise_orgs(name,created_by) VALUES(trim(p_name),auth.uid()) RETURNING id INTO v_id;
 INSERT INTO public.enterprise_members(org_id,user_id,member_email,role) SELECT v_id,u.id,u.email,'admin' FROM auth.users u WHERE u.id=auth.uid();
 RETURN v_id;
END $$;
-- DEPLOY-SPLIT
CREATE OR REPLACE FUNCTION public.enterprise_add_member(p_org uuid,p_email text,p_role text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_user uuid; BEGIN
 IF public.enterprise_role(p_org) <> 'admin' THEN RAISE EXCEPTION 'Administrator access required'; END IF;
 IF p_role NOT IN ('pricing','finance','operations','viewer') THEN RAISE EXCEPTION 'Invalid team role'; END IF;
 SELECT id INTO v_user FROM auth.users WHERE lower(email)=lower(trim(p_email)) LIMIT 1;
 IF v_user IS NULL THEN RAISE EXCEPTION 'This person must have a Vet INC login before being added'; END IF;
 INSERT INTO public.enterprise_members(org_id,user_id,member_email,role) SELECT p_org,u.id,u.email,p_role FROM auth.users u WHERE u.id=v_user ON CONFLICT(org_id,user_id) DO NOTHING;
END $$;
-- DEPLOY-SPLIT
CREATE OR REPLACE FUNCTION public.enterprise_create_change(p_org uuid,p_title text,p_description text DEFAULT '',p_date date DEFAULT NULL) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_id uuid; BEGIN
 IF coalesce(public.enterprise_role(p_org),'') NOT IN ('admin','pricing') THEN RAISE EXCEPTION 'Pricing access required'; END IF;
 INSERT INTO public.enterprise_changes(org_id,title,description,effective_date,owner_id)
 VALUES(p_org,trim(p_title),coalesce(p_description,''),p_date,auth.uid()) RETURNING id INTO v_id;
 INSERT INTO public.enterprise_events(org_id,change_id,actor_id,action) VALUES(p_org,v_id,auth.uid(),'Change created');
 RETURN v_id;
END $$;
-- DEPLOY-SPLIT
CREATE OR REPLACE FUNCTION public.enterprise_add_task(p_change uuid,p_title text,p_assigned_to uuid DEFAULT NULL) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_org uuid;v_status text;v_id uuid; BEGIN
 SELECT org_id,status INTO v_org,v_status FROM public.enterprise_changes WHERE id=p_change;
 IF coalesce(public.enterprise_role(v_org),'') NOT IN ('admin','pricing','operations') THEN RAISE EXCEPTION 'Team access required'; END IF;
 IF v_status='confirmed' THEN RAISE EXCEPTION 'Confirmed changes are locked'; END IF;
 INSERT INTO public.enterprise_tasks(org_id,change_id,title,assigned_to,created_by)
 VALUES(v_org,p_change,trim(p_title),p_assigned_to,auth.uid()) RETURNING id INTO v_id;
 INSERT INTO public.enterprise_events(org_id,change_id,actor_id,action,detail) VALUES(v_org,p_change,auth.uid(),'Work added',trim(p_title));
 RETURN v_id;
END $$;
-- DEPLOY-SPLIT
CREATE OR REPLACE FUNCTION public.enterprise_finish_task(p_task uuid) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v public.enterprise_tasks%ROWTYPE; BEGIN
 SELECT * INTO v FROM public.enterprise_tasks WHERE id=p_task FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Work item not found'; END IF;
 IF coalesce(public.enterprise_role(v.org_id),'') NOT IN ('admin','pricing','operations') AND v.assigned_to IS DISTINCT FROM auth.uid() THEN RAISE EXCEPTION 'Not assigned to this work'; END IF;
 IF v.status='done' THEN RETURN; END IF;
 UPDATE public.enterprise_tasks SET status='done',completed_at=now() WHERE id=p_task;
 INSERT INTO public.enterprise_events(org_id,change_id,actor_id,action,detail) VALUES(v.org_id,v.change_id,auth.uid(),'Work completed',v.title);
END $$;
-- DEPLOY-SPLIT
CREATE OR REPLACE FUNCTION public.enterprise_add_location(p_change uuid,p_name text) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_org uuid;v_status text;v_id uuid; BEGIN
 SELECT org_id,status INTO v_org,v_status FROM public.enterprise_changes WHERE id=p_change;
 IF coalesce(public.enterprise_role(v_org),'') NOT IN ('admin','pricing','operations') THEN RAISE EXCEPTION 'Team access required'; END IF;
 IF v_status NOT IN ('draft','review') THEN RAISE EXCEPTION 'Scope is locked after approval'; END IF;
 INSERT INTO public.enterprise_locations(org_id,change_id,name) VALUES(v_org,p_change,trim(p_name)) RETURNING id INTO v_id;
 INSERT INTO public.enterprise_events(org_id,change_id,actor_id,action,detail) VALUES(v_org,p_change,auth.uid(),'Location added',trim(p_name));
 RETURN v_id;
END $$;
-- DEPLOY-SPLIT
CREATE OR REPLACE FUNCTION public.enterprise_set_location(p_location uuid,p_state text,p_method text DEFAULT NULL) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v public.enterprise_locations%ROWTYPE;v_status text; BEGIN
 SELECT * INTO v FROM public.enterprise_locations WHERE id=p_location FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Location not found'; END IF;
 IF coalesce(public.enterprise_role(v.org_id),'') NOT IN ('admin','operations') THEN RAISE EXCEPTION 'Operations access required'; END IF;
 SELECT status INTO v_status FROM public.enterprise_changes WHERE id=v.change_id;
 IF v_status='confirmed' THEN RAISE EXCEPTION 'Change is locked'; END IF;
 IF p_state NOT IN ('ready','held','confirmed') THEN RAISE EXCEPTION 'Invalid location state'; END IF;
 IF p_state='confirmed' AND (v_status<>'rollout' OR coalesce(p_method,'') NOT IN ('manual','verified_integration')) THEN RAISE EXCEPTION 'Active rollout and confirmation method required'; END IF;
 UPDATE public.enterprise_locations SET state=p_state,implementation_method=CASE WHEN p_state='confirmed' THEN p_method ELSE NULL END,
 confirmed_by=CASE WHEN p_state='confirmed' THEN auth.uid() ELSE NULL END,confirmed_at=CASE WHEN p_state='confirmed' THEN now() ELSE NULL END WHERE id=p_location;
 INSERT INTO public.enterprise_events(org_id,change_id,actor_id,action,detail) VALUES(v.org_id,v.change_id,auth.uid(),'Location '||p_state,v.name||CASE WHEN p_state='confirmed' THEN ' ('||p_method||')' ELSE '' END);
END $$;
-- DEPLOY-SPLIT
CREATE OR REPLACE FUNCTION public.enterprise_transition(p_change uuid,p_action text,p_note text DEFAULT '') RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v public.enterprise_changes%ROWTYPE;v_role text;v_next text; BEGIN
 SELECT * INTO v FROM public.enterprise_changes WHERE id=p_change FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Change not found'; END IF;
 v_role:=public.enterprise_role(v.org_id);
 IF v_role IS NULL THEN RAISE EXCEPTION 'Not authorized'; END IF;
 IF p_action='submit' AND v.status='draft' AND v_role IN ('admin','pricing') THEN v_next:='review';
 ELSIF p_action='approve' AND v.status='review' AND v_role IN ('admin','finance') THEN
  IF EXISTS (SELECT 1 FROM public.enterprise_tasks WHERE change_id=p_change AND status='open') THEN RAISE EXCEPTION 'Resolve open work before approval'; END IF;
  v_next:='approved';
  INSERT INTO public.enterprise_approvals(org_id,change_id,actor_id,decision,note) VALUES(v.org_id,p_change,auth.uid(),'approved',coalesce(p_note,''));
 ELSIF p_action='return' AND v.status='review' AND v_role IN ('admin','finance') THEN
  v_next:='draft';INSERT INTO public.enterprise_approvals(org_id,change_id,actor_id,decision,note) VALUES(v.org_id,p_change,auth.uid(),'returned',coalesce(p_note,''));
 ELSIF p_action='start' AND v.status='approved' AND v_role IN ('admin','operations') THEN v_next:='rollout';
 ELSIF p_action='confirm' AND v.status='rollout' AND v_role IN ('admin','operations') THEN
  IF NOT EXISTS (SELECT 1 FROM public.enterprise_locations WHERE change_id=p_change) OR
     EXISTS (SELECT 1 FROM public.enterprise_locations WHERE change_id=p_change AND state<>'confirmed') THEN RAISE EXCEPTION 'Confirm every included location first'; END IF;
  v_next:='confirmed';
 ELSE RAISE EXCEPTION 'Action unavailable in this stage or role'; END IF;
 UPDATE public.enterprise_changes SET status=v_next,updated_at=now() WHERE id=p_change;
 INSERT INTO public.enterprise_events(org_id,change_id,actor_id,action,detail) VALUES(v.org_id,p_change,auth.uid(),'Change '||v_next,left(coalesce(p_note,''),1000));
END $$;
-- DEPLOY-SPLIT
DO $$ DECLARE f record; BEGIN FOR f IN SELECT p.oid::regprocedure::text signature FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname LIKE 'enterprise_%' AND p.prokind='f' LOOP EXECUTE 'REVOKE ALL ON FUNCTION '||f.signature||' FROM PUBLIC,anon'; EXECUTE 'GRANT EXECUTE ON FUNCTION '||f.signature||' TO authenticated'; END LOOP; END $$;
