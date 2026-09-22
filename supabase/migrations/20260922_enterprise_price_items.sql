-- Adds actual proposed pricing line items. No seed data or PMS writeback.
-- DEPLOY-SPLIT
CREATE TABLE IF NOT EXISTS public.enterprise_price_items (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),org_id uuid NOT NULL,change_id uuid NOT NULL,
 service_name text NOT NULL CHECK(length(trim(service_name)) BETWEEN 2 AND 200),
 service_code text NOT NULL DEFAULT '' CHECK(length(service_code)<=80),
 current_price numeric(12,2) NOT NULL CHECK(current_price>=0),
 proposed_price numeric(12,2) NOT NULL CHECK(proposed_price>=0),
 currency text NOT NULL CHECK(currency IN ('CAD','USD')),
 note text NOT NULL DEFAULT '' CHECK(length(note)<=1000),
 created_at timestamptz NOT NULL DEFAULT now(),
 FOREIGN KEY(change_id,org_id) REFERENCES public.enterprise_changes(id,org_id) ON DELETE CASCADE
);
-- DEPLOY-SPLIT
CREATE INDEX IF NOT EXISTS enterprise_price_items_change_idx ON public.enterprise_price_items(change_id);
-- DEPLOY-SPLIT
ALTER TABLE public.enterprise_price_items ENABLE ROW LEVEL SECURITY;
-- DEPLOY-SPLIT
ALTER TABLE public.enterprise_price_items FORCE ROW LEVEL SECURITY;
-- DEPLOY-SPLIT
REVOKE ALL ON public.enterprise_price_items FROM PUBLIC,anon,authenticated;
-- DEPLOY-SPLIT
GRANT SELECT ON public.enterprise_price_items TO authenticated;
-- DEPLOY-SPLIT
CREATE POLICY enterprise_price_items_read ON public.enterprise_price_items FOR SELECT TO authenticated USING(public.enterprise_role(org_id) IS NOT NULL);
-- DEPLOY-SPLIT
CREATE OR REPLACE FUNCTION public.enterprise_add_price_item(p_change uuid,p_name text,p_code text,p_current numeric,p_proposed numeric,p_currency text,p_note text DEFAULT '') RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_org uuid;v_status text;v_id uuid; BEGIN
 SELECT org_id,status INTO v_org,v_status FROM public.enterprise_changes WHERE id=p_change FOR UPDATE;
 IF coalesce(public.enterprise_role(v_org),'') NOT IN ('admin','pricing') THEN RAISE EXCEPTION 'Pricing access required'; END IF;
 IF v_status<>'draft' THEN RAISE EXCEPTION 'Pricing scope is locked after submission'; END IF;
 INSERT INTO public.enterprise_price_items(org_id,change_id,service_name,service_code,current_price,proposed_price,currency,note)
 VALUES(v_org,p_change,trim(p_name),coalesce(trim(p_code),''),p_current,p_proposed,p_currency,coalesce(p_note,'')) RETURNING id INTO v_id;
 INSERT INTO public.enterprise_events(org_id,change_id,actor_id,action,detail) VALUES(v_org,p_change,auth.uid(),'Price proposed',trim(p_name));
 RETURN v_id;
END $$;
-- DEPLOY-SPLIT
CREATE OR REPLACE FUNCTION public.enterprise_transition(p_change uuid,p_action text,p_note text DEFAULT '') RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v public.enterprise_changes%ROWTYPE;v_role text;v_next text; BEGIN
 SELECT * INTO v FROM public.enterprise_changes WHERE id=p_change FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Change not found'; END IF;
 v_role:=public.enterprise_role(v.org_id);
 IF v_role IS NULL THEN RAISE EXCEPTION 'Not authorized'; END IF;
 IF p_action='submit' AND v.status='draft' AND v_role IN ('admin','pricing') THEN
  IF NOT EXISTS(SELECT 1 FROM public.enterprise_price_items WHERE change_id=p_change) THEN RAISE EXCEPTION 'Add at least one proposed price before submission'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.enterprise_locations WHERE change_id=p_change) THEN RAISE EXCEPTION 'Add at least one location before submission'; END IF;
  v_next:='review';
 ELSIF p_action='approve' AND v.status='review' AND v_role IN ('admin','finance') THEN
  IF v.owner_id=auth.uid() THEN RAISE EXCEPTION 'A different authorized team member must approve this change'; END IF;
  IF EXISTS (SELECT 1 FROM public.enterprise_tasks WHERE change_id=p_change AND status='open') THEN RAISE EXCEPTION 'Resolve open work before approval'; END IF;
  v_next:='approved';
  INSERT INTO public.enterprise_approvals(org_id,change_id,actor_id,decision,note) VALUES(v.org_id,p_change,auth.uid(),'approved',left(coalesce(p_note,''),1000));
 ELSIF p_action='return' AND v.status='review' AND v_role IN ('admin','finance') THEN
  v_next:='draft';INSERT INTO public.enterprise_approvals(org_id,change_id,actor_id,decision,note) VALUES(v.org_id,p_change,auth.uid(),'returned',left(coalesce(p_note,''),1000));
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
CREATE OR REPLACE FUNCTION public.enterprise_add_location(p_change uuid,p_name text) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_org uuid;v_status text;v_id uuid; BEGIN
 SELECT org_id,status INTO v_org,v_status FROM public.enterprise_changes WHERE id=p_change FOR UPDATE;
 IF coalesce(public.enterprise_role(v_org),'') NOT IN ('admin','pricing','operations') THEN RAISE EXCEPTION 'Team access required'; END IF;
 IF v_status<>'draft' THEN RAISE EXCEPTION 'Scope is locked after submission'; END IF;
 INSERT INTO public.enterprise_locations(org_id,change_id,name) VALUES(v_org,p_change,trim(p_name)) RETURNING id INTO v_id;
 INSERT INTO public.enterprise_events(org_id,change_id,actor_id,action,detail) VALUES(v_org,p_change,auth.uid(),'Location added',trim(p_name));
 RETURN v_id;
END $$;
-- DEPLOY-SPLIT
REVOKE ALL ON FUNCTION public.enterprise_add_price_item(uuid,text,text,numeric,numeric,text,text) FROM PUBLIC,anon;
-- DEPLOY-SPLIT
GRANT EXECUTE ON FUNCTION public.enterprise_add_price_item(uuid,text,text,numeric,numeric,text,text) TO authenticated;
