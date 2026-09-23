-- A rollout time is a plan for the central pricing team, not an automatic PMS write.
-- DEPLOY-SPLIT
ALTER TABLE public.enterprise_changes ADD COLUMN IF NOT EXISTS scheduled_for timestamptz;
-- DEPLOY-SPLIT
CREATE OR REPLACE FUNCTION public.enterprise_schedule_change(p_change uuid, p_scheduled_for timestamptz)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v public.enterprise_changes%ROWTYPE;
BEGIN
  SELECT * INTO v FROM public.enterprise_changes WHERE id = p_change FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Change not found'; END IF;
  IF coalesce(public.enterprise_role(v.org_id), '') NOT IN ('admin', 'pricing') THEN
    RAISE EXCEPTION 'Pricing access required';
  END IF;
  IF v.status NOT IN ('draft', 'review', 'approved') THEN
    RAISE EXCEPTION 'Rollout time cannot be changed after rollout begins';
  END IF;
  IF p_scheduled_for IS NOT NULL AND p_scheduled_for <= now() THEN
    RAISE EXCEPTION 'Choose a future rollout time';
  END IF;
  UPDATE public.enterprise_changes SET scheduled_for = p_scheduled_for, updated_at = now() WHERE id = p_change;
  INSERT INTO public.enterprise_events(org_id, change_id, actor_id, action, detail)
  VALUES (v.org_id, p_change, auth.uid(),
    CASE WHEN p_scheduled_for IS NULL THEN 'Rollout schedule cleared' ELSE 'Rollout scheduled' END,
    coalesce(to_char(p_scheduled_for AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI "UTC"'), ''));
END $$;
-- DEPLOY-SPLIT
REVOKE ALL ON FUNCTION public.enterprise_schedule_change(uuid,timestamptz) FROM PUBLIC, anon;
-- DEPLOY-SPLIT
GRANT EXECUTE ON FUNCTION public.enterprise_schedule_change(uuid,timestamptz) TO authenticated;
