-- REVIEW ONLY. Apply only after additive migration, new Edge artifacts, old-writer
-- admission cutoff/drain, managed tests, backup/drift checks and explicit approval.
BEGIN;
DO $preflight$
DECLARE approved jsonb:=NULLIF(current_setting('waydrop.approved_cutover',true),'')::jsonb; sig text; p record;
BEGIN
  IF approved IS NULL THEN RAISE EXCEPTION 'Explicit reviewed cutover fingerprints required'; END IF;
  FOREACH sig IN ARRAY ARRAY[
    'public.accept_intercity_request(uuid,uuid)',
    'public.find_nearby_riders(uuid,double precision,double precision,double precision,integer,uuid[])',
    'public.assign_nearby_searching_orders_core(uuid,uuid,double precision,double precision,public.partner_service_mode_enum)',
    'public.send_push_notification_fnc(uuid,text,text,jsonb)'
  ] LOOP
    SELECT md5(pg_get_functiondef(oid)) AS hash,proowner::regrole::text AS owner,COALESCE(proacl::text,'NULL') AS acl
      INTO p FROM pg_proc WHERE oid=to_regprocedure(sig);
    IF p.hash IS NULL OR approved->sig->>'md5' IS DISTINCT FROM p.hash
      OR approved->sig->>'owner' IS DISTINCT FROM p.owner OR approved->sig->>'acl' IS DISTINCT FROM p.acl THEN
      RAISE EXCEPTION 'Cutover fingerprint/owner/ACL mismatch for %',sig;
    END IF;
  END LOOP;
END $preflight$;

ALTER FUNCTION public.find_nearby_riders(uuid,double precision,double precision,double precision,integer,uuid[]) SET SCHEMA waydrop_internal;
ALTER FUNCTION waydrop_internal.find_nearby_riders(uuid,double precision,double precision,double precision,integer,uuid[]) RENAME TO legacy_find_nearby_riders;
CREATE FUNCTION public.find_nearby_riders(p_order_id uuid,p_pickup_lat double precision,p_pickup_lng double precision,p_radius_km double precision,p_limit integer,p_excluded_rider_ids uuid[] DEFAULT '{}'::uuid[])
RETURNS TABLE(rider_id uuid,user_id uuid,full_name text,vehicle_type text,vehicle_number text,current_lat double precision,current_lng double precision,distance_km numeric)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$ BEGIN
  -- Retain the captured ownership check/distance semantics, then apply exactly
  -- the same current verification/freshness gates as all offer writers.
  RETURN QUERY SELECT q.* FROM waydrop_internal.legacy_find_nearby_riders(p_order_id,p_pickup_lat,p_pickup_lng,p_radius_km,least(50,greatest(1,p_limit)),p_excluded_rider_ids) q
  WHERE public.dispatch_eligibility(p_order_id,q.rider_id,'offer') IS NULL;
END $$;
REVOKE ALL ON FUNCTION public.find_nearby_riders(uuid,double precision,double precision,double precision,integer,uuid[]) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.find_nearby_riders(uuid,double precision,double precision,double precision,integer,uuid[]) TO authenticated,service_role;

-- Preserve the captured intercity transaction/fare/capacity code, but give it
-- the same rider-first lock and eligibility gate as ordinary acceptance.
ALTER FUNCTION public.accept_intercity_request(uuid,uuid) SET SCHEMA waydrop_internal;
ALTER FUNCTION waydrop_internal.accept_intercity_request(uuid,uuid) RENAME TO legacy_accept_intercity_request;
CREATE FUNCTION public.accept_intercity_request(p_request_id uuid,p_rider_user_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE rid uuid; oid uuid; reason text; current_order public.orders%ROWTYPE;
BEGIN
  IF auth.uid() IS NOT NULL AND auth.uid() IS DISTINCT FROM p_rider_user_id THEN
    RETURN jsonb_build_object('success',false,'code','UNAUTHORIZED','message','Actor mismatch');
  END IF;
  SELECT id INTO rid FROM public.riders WHERE user_id=p_rider_user_id FOR NO KEY UPDATE;
  SELECT parcel_id INTO oid FROM public.intercity_requests WHERE id=p_request_id AND traveller_id=rid;
  IF oid IS NULL THEN RETURN jsonb_build_object('success',false,'code','INVALID_REQUEST'); END IF;
  SELECT * INTO current_order FROM public.orders WHERE id=oid FOR NO KEY UPDATE;
  IF current_order.order_status::text<>'accepted' OR current_order.rider_id IS DISTINCT FROM rid THEN
    reason:=public.dispatch_eligibility(oid,rid,'accept');
    IF reason IS NOT NULL THEN RETURN jsonb_build_object('success',false,'code',reason,'message','Rider is not eligible for this order'); END IF;
  END IF;
  RETURN waydrop_internal.legacy_accept_intercity_request(p_request_id,p_rider_user_id);
END $$;
REVOKE ALL ON FUNCTION public.accept_intercity_request(uuid,uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.accept_intercity_request(uuid,uuid) TO authenticated,service_role;

CREATE OR REPLACE FUNCTION waydrop_internal.guard_order_dispatch() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE token uuid; j waydrop_internal.dispatch_jobs%ROWTYPE; reason text;
BEGIN
  IF NEW.order_status::text='accepted' AND OLD.order_status::text='searching' THEN
    reason:=public.dispatch_eligibility(OLD.id,NEW.rider_id,'accept');
    IF reason IS NOT NULL THEN RAISE EXCEPTION 'Eligibility rejected: %',reason USING ERRCODE='42501'; END IF;
  END IF;
  IF NEW.dispatch_state IS DISTINCT FROM OLD.dispatch_state OR NEW.dispatch_worker_running IS DISTINCT FROM OLD.dispatch_worker_running
     OR NEW.dispatch_worker_started_at IS DISTINCT FROM OLD.dispatch_worker_started_at THEN
    token:=NULLIF(current_setting('waydrop.dispatch_token',true),'')::uuid;
    SELECT * INTO j FROM waydrop_internal.dispatch_jobs WHERE order_id=OLD.id;
    IF token IS NULL OR j.owner_token IS DISTINCT FROM token OR j.state<>'running' OR j.lease_until<=clock_timestamp() THEN
      RAISE EXCEPTION 'Dispatch ownership required' USING ERRCODE='42501';
    END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER waydrop_guard_order_dispatch BEFORE UPDATE ON public.orders
FOR EACH ROW EXECUTE FUNCTION waydrop_internal.guard_order_dispatch();

CREATE OR REPLACE FUNCTION waydrop_internal.guard_assignment_dispatch() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE o public.orders%ROWTYPE; j waydrop_internal.dispatch_jobs%ROWTYPE; token uuid;
BEGIN
  SELECT * INTO o FROM public.orders WHERE id=NEW.order_id;
  -- Accepted rows must belong to the already atomically claimed order. This also
  -- rejects the old split acceptance writer before it can leave a losing row.
  IF NEW.assignment_status::text='accepted' AND (o.order_status::text<>'accepted' OR o.rider_id IS DISTINCT FROM NEW.rider_id) THEN
    RAISE EXCEPTION 'Atomic acceptance required' USING ERRCODE='42501';
  END IF;
  IF TG_OP='UPDATE' AND OLD.assignment_status::text='accepted' AND NEW.assignment_status::text IN ('sent','expired','rejected') THEN
    RAISE EXCEPTION 'Accepted assignment is immutable to dispatch' USING ERRCODE='42501';
  END IF;
  IF o.order_type::text NOT IN ('intercity_ride','intercity_parcel') AND NEW.assignment_status::text='sent' THEN
    token:=NULLIF(current_setting('waydrop.dispatch_token',true),'')::uuid;
    SELECT * INTO j FROM waydrop_internal.dispatch_jobs WHERE order_id=NEW.order_id;
    IF o.order_status::text<>'searching' OR token IS NULL OR j.owner_token IS DISTINCT FROM token
      OR j.state<>'running' OR j.lease_until<=clock_timestamp() OR NEW.dispatch_generation IS DISTINCT FROM j.generation THEN
      RAISE EXCEPTION 'Fenced offer required' USING ERRCODE='42501';
    END IF;
  END IF;
  IF TG_OP='UPDATE' AND OLD.assignment_status::text='sent' AND NEW.assignment_status::text='expired'
    AND o.order_status::text='searching' AND OLD.expires_at>clock_timestamp() THEN
    RAISE EXCEPTION 'Live offer cannot be expired early' USING ERRCODE='42501';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER waydrop_guard_assignment_dispatch BEFORE INSERT OR UPDATE ON public.rider_assignments
FOR EACH ROW EXECUTE FUNCTION waydrop_internal.guard_assignment_dispatch();

-- Eligibility writers serialize with the rider-first offer/accept transaction.
-- Readers never lock KYC rows, so this adds no rider -> KYC lock inversion.
CREATE FUNCTION waydrop_internal.serialize_kyc_eligibility() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$ BEGIN
  PERFORM 1 FROM public.riders WHERE kyc_id=OLD.id OR user_id=OLD.user_id ORDER BY id FOR NO KEY UPDATE;
  RETURN NEW;
END $$;
CREATE TRIGGER waydrop_serialize_kyc_eligibility BEFORE UPDATE OF kyc_status,activation_status,blocked_until,vehicle_type ON public.rider_kyc
FOR EACH ROW EXECUTE FUNCTION waydrop_internal.serialize_kyc_eligibility();

-- All former matching writers are now durable request entry points. Coordinates
-- and caller-supplied identity never authorize assignment writes.
CREATE OR REPLACE FUNCTION public.assign_new_order_to_nearby_online_riders_core(p_order_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$ BEGIN PERFORM public.request_order_dispatch(p_order_id); END $$;
REVOKE ALL ON FUNCTION public.assign_new_order_to_nearby_online_riders_core(uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.assign_new_order_to_nearby_online_riders_core(uuid) TO service_role;
CREATE OR REPLACE FUNCTION public.assign_new_order_to_nearby_online_riders() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$ BEGIN
  PERFORM public.request_order_dispatch(NEW.id); RETURN NEW;
END $$;
CREATE OR REPLACE FUNCTION public.assign_nearby_searching_orders_core(p_rider_id uuid,p_rider_user_id uuid,p_current_lat double precision,p_current_lng double precision,p_service_mode public.partner_service_mode_enum) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE x record; r public.riders%ROWTYPE; radius double precision;
BEGIN
  SELECT * INTO r FROM public.riders WHERE id=p_rider_id AND user_id=p_rider_user_id;
  IF NOT FOUND THEN RETURN; END IF;
  SELECT COALESCE(round_2_radius_km,6) INTO radius FROM public.dispatch_config WHERE is_active ORDER BY updated_at DESC,id LIMIT 1;
  radius:=COALESCE(radius,6);
  FOR x IN SELECT id FROM public.orders WHERE order_status::text='searching' AND order_type::text NOT IN ('intercity_ride','intercity_parcel')
    AND created_at>=clock_timestamp()-interval '1 day' AND pickup_lat BETWEEN r.current_lat-radius/111.0 AND r.current_lat+radius/111.0
    AND 6371*acos(least(1.0,greatest(-1.0,cos(radians(pickup_lat))*cos(radians(r.current_lat))*cos(radians(r.current_lng)-radians(pickup_lng))+sin(radians(pickup_lat))*sin(radians(r.current_lat)))))<=radius
    ORDER BY id LOOP
    IF public.dispatch_eligibility(x.id,p_rider_id,'offer') IS NULL THEN PERFORM public.request_order_dispatch(x.id); END IF;
  END LOOP;
END $$;
REVOKE ALL ON FUNCTION public.assign_nearby_searching_orders_core(uuid,uuid,double precision,double precision,public.partner_service_mode_enum) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.assign_nearby_searching_orders_core(uuid,uuid,double precision,double precision,public.partner_service_mode_enum) TO service_role;

CREATE OR REPLACE FUNCTION public.assign_nearby_searching_orders_to_rider() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$ BEGIN
  IF NEW.account_status::text='online' THEN
    PERFORM public.assign_nearby_searching_orders_core(NEW.id,NEW.user_id,NEW.current_lat,NEW.current_lng,NEW.service_mode);
  END IF;
  RETURN NEW;
END $$;
CREATE OR REPLACE FUNCTION public.assign_nearby_searching_orders_on_rider_freed() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE r public.riders%ROWTYPE;
BEGIN
  SELECT * INTO r FROM public.riders WHERE id=COALESCE(OLD.rider_id,NEW.rider_id);
  IF FOUND THEN PERFORM public.assign_nearby_searching_orders_core(r.id,r.user_id,r.current_lat,r.current_lng,r.service_mode); END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trigger_assign_nearby_orders_on_rider_freed ON public.orders;
CREATE TRIGGER trigger_assign_nearby_orders_on_rider_freed AFTER UPDATE OF order_status ON public.orders FOR EACH ROW
WHEN (OLD.order_status::text IN ('accepted','rider_arrived','picked_up','rider_at_drop','ongoing','payment_pending')
  AND NEW.order_status::text NOT IN ('accepted','rider_arrived','picked_up','rider_at_drop','ongoing','payment_pending'))
EXECUTE FUNCTION public.assign_nearby_searching_orders_on_rider_freed();

CREATE OR REPLACE FUNCTION public.redispatch_stalled_searching_orders() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE x record;
BEGIN
  -- Catch committed orders missing a request (legacy/crash/cutover), bounded.
  FOR x IN SELECT o.id FROM public.orders o LEFT JOIN waydrop_internal.dispatch_jobs j ON j.order_id=o.id
    WHERE o.order_status::text='searching' AND o.order_type::text NOT IN ('intercity_ride','intercity_parcel') AND j.order_id IS NULL
    ORDER BY o.created_at,o.id LIMIT 50 LOOP PERFORM public.request_order_dispatch(x.id); END LOOP;
  PERFORM public.recover_waydrop_work(50);
END $$;
CREATE OR REPLACE FUNCTION public.redispatch_freed_riders() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$ BEGIN
  PERFORM public.redispatch_stalled_searching_orders();
END $$;
REVOKE ALL ON FUNCTION public.redispatch_stalled_searching_orders(),public.redispatch_freed_riders() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.redispatch_stalled_searching_orders(),public.redispatch_freed_riders() TO service_role;

-- Essential inbox + outbox intent commit with the initiating DB transaction.
-- Transport failure is caught only after the persistent intent exists.
-- Registration versions are server-owned: a client cannot replace a token while
-- preserving its old version and cause a stale UNREGISTERED result to delete it.
CREATE FUNCTION waydrop_internal.version_device_registration() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog,public AS $$ BEGIN
  IF TG_OP='INSERT' THEN NEW.updated_at:=clock_timestamp();
  ELSIF NEW.fcm_token IS DISTINCT FROM OLD.fcm_token OR NEW.user_id IS DISTINCT FROM OLD.user_id
    OR NEW.updated_at IS DISTINCT FROM OLD.updated_at THEN
    NEW.updated_at:=greatest(clock_timestamp(),OLD.updated_at+interval '1 microsecond');
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER waydrop_version_device_registration BEFORE INSERT OR UPDATE ON public.user_device_tokens
FOR EACH ROW EXECUTE FUNCTION waydrop_internal.version_device_registration();
CREATE OR REPLACE FUNCTION public.on_notification_insert() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$ BEGIN
  INSERT INTO waydrop_internal.notification_jobs(notification_id,user_id) VALUES(NEW.id,NEW.user_id) ON CONFLICT DO NOTHING;
  PERFORM waydrop_internal.kick_notification(NEW.id); RETURN NEW;
END $$;
CREATE OR REPLACE FUNCTION public.deliver_push_notification_http_fnc(p_user_id uuid,p_title text,p_body text,p_data jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE nid uuid:=NULLIF(p_data->>'notification_id','')::uuid;
BEGIN
  IF nid IS NULL OR NOT EXISTS(SELECT 1 FROM public.notifications WHERE id=nid AND user_id=p_user_id) THEN RAISE EXCEPTION 'Persistent notification required'; END IF;
  INSERT INTO waydrop_internal.notification_jobs(notification_id,user_id) VALUES(nid,p_user_id) ON CONFLICT DO NOTHING;
  PERFORM waydrop_internal.kick_notification(nid);
END $$;
CREATE OR REPLACE FUNCTION public.send_push_notification_fnc(p_user_id uuid,p_title text,p_body text,p_data jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$ BEGIN
  INSERT INTO public.notifications(user_id,title,body,notification_type,reference_id,reference_type,payload)
  VALUES(p_user_id,p_title,p_body,COALESCE(p_data->>'type','general'),
    COALESCE(NULLIF(p_data->>'order_id',''),NULLIF(p_data->>'payment_id',''))::uuid,
    CASE WHEN p_data ? 'order_id' THEN 'order' WHEN p_data ? 'payment_id' THEN 'payment' END,p_data);
END $$;
REVOKE ALL ON FUNCTION public.send_push_notification_fnc(uuid,text,text,jsonb),public.deliver_push_notification_http_fnc(uuid,text,text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.send_push_notification_fnc(uuid,text,text,jsonb),public.deliver_push_notification_http_fnc(uuid,text,text,jsonb) TO service_role;

-- No cron.schedule call here: the existing minute recovery job invokes both
-- bounded recovery queues. Its schedule is unchanged; no paid resource needed.
UPDATE waydrop_internal.runtime SET enabled=true WHERE singleton;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA waydrop_internal FROM PUBLIC,anon,authenticated;
COMMIT;
