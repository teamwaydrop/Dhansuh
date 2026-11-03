-- ADDITIVE / DISABLED BY DEFAULT. Local candidate; never applied to production.
-- The separately reviewed cutover installs entry-point wrappers and write guards.
CREATE SCHEMA IF NOT EXISTS waydrop_internal;
REVOKE ALL ON SCHEMA waydrop_internal FROM PUBLIC, anon, authenticated;
CREATE TABLE waydrop_internal.runtime (
  singleton boolean PRIMARY KEY DEFAULT true CHECK(singleton), enabled boolean NOT NULL DEFAULT false
);
INSERT INTO waydrop_internal.runtime VALUES(true,false);
ALTER TABLE waydrop_internal.runtime ENABLE ROW LEVEL SECURITY;

CREATE TABLE waydrop_internal.dispatch_jobs (
  order_id uuid PRIMARY KEY REFERENCES public.orders(id) ON DELETE CASCADE,
  generation bigint NOT NULL DEFAULT 0, owner_token uuid, lease_until timestamptz,
  next_at timestamptz NOT NULL DEFAULT clock_timestamp(), last_step_at timestamptz,
  queued_until timestamptz, requests bigint NOT NULL DEFAULT 1, handled bigint NOT NULL DEFAULT 0,
  claimed_revision bigint, state text NOT NULL DEFAULT 'ready' CHECK(state IN ('ready','running','idle','terminal')),
  kicks bigint NOT NULL DEFAULT 0, last_error text, round_no integer NOT NULL DEFAULT 1,empty_passes integer NOT NULL DEFAULT 0
);
CREATE INDEX dispatch_jobs_due ON waydrop_internal.dispatch_jobs(next_at) WHERE state<>'terminal';
ALTER TABLE waydrop_internal.dispatch_jobs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.rider_assignments ADD COLUMN dispatch_generation bigint;

CREATE FUNCTION waydrop_internal.require_enabled() RETURNS void LANGUAGE plpgsql
SET search_path=pg_catalog,public AS $$ BEGIN
  IF NOT COALESCE((SELECT enabled FROM waydrop_internal.runtime WHERE singleton),false) THEN
    RAISE EXCEPTION 'Durable dispatch/delivery cutover not enabled' USING ERRCODE='55000';
  END IF;
END $$;

-- Strict, shared current eligibility. KYC approval/activation is the verification
-- authority; the legacy denormalized riders.is_verified flag is not sufficient.
-- Accept is a fresh available-order claim, not reuse of an expired offer capability.
CREATE FUNCTION public.dispatch_eligibility(p_order_id uuid,p_rider_id uuid,p_phase text)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE o public.orders%ROWTYPE; r public.riders%ROWTYPE; k public.rider_kyc%ROWTYPE;
  cfg public.dispatch_config%ROWTYPE; weight_kg double precision; vehicle text; required text;
BEGIN
  PERFORM waydrop_internal.require_enabled();
  IF p_phase NOT IN ('offer','accept') THEN RETURN 'INVALID_PHASE'; END IF;
  SELECT * INTO o FROM public.orders WHERE id=p_order_id;
  SELECT * INTO r FROM public.riders WHERE id=p_rider_id;
  IF o.id IS NULL OR r.id IS NULL THEN RETURN 'NOT_FOUND'; END IF;
  IF o.order_status::text<>'searching' THEN RETURN 'ORDER_UNAVAILABLE'; END IF;
  IF r.user_id=o.user_id THEN RETURN 'SELF_ORDER'; END IF;
  IF r.account_status::text IS DISTINCT FROM 'online' THEN RETURN 'RIDER_OFFLINE'; END IF;
  SELECT * INTO k FROM public.rider_kyc WHERE id=r.kyc_id AND user_id=r.user_id;
  IF k.id IS NULL OR k.kyc_status::text IS DISTINCT FROM 'approved'
     OR k.activation_status::text IS DISTINCT FROM 'active'
     OR k.blocked_until>clock_timestamp() THEN RETURN 'KYC_NOT_VERIFIED'; END IF;
  required:=public.get_required_service_mode(o.order_type::text,o.distance_meters)::text;
  IF r.service_mode::text IS DISTINCT FROM required THEN RETURN 'WRONG_SERVICE_MODE'; END IF;
  IF public.is_rider_blocked_by_tax_due(r.id) THEN RETURN 'TAX_DUE_THRESHOLD_BLOCKED'; END IF;
  IF public.is_rider_blocked_by_cod_limit(r.id) THEN RETURN 'COD_LIMIT_EXCEEDED'; END IF;
  IF public.rider_is_on_active_trip(r.id) THEN RETURN 'RIDER_BUSY'; END IF;
  SELECT * INTO cfg FROM public.dispatch_config WHERE is_active ORDER BY updated_at DESC,id LIMIT 1;
  IF o.created_at<clock_timestamp()-make_interval(secs=>COALESCE(cfg.max_search_duration_sec,900)) THEN RETURN 'SEARCH_EXPIRED'; END IF;
  IF r.current_lat IS NULL OR r.current_lng IS NULL OR r.current_lat NOT BETWEEN -90 AND 90
    OR r.current_lng NOT BETWEEN -180 AND 180 OR r.last_location_updated_at IS NULL
    OR r.last_location_updated_at<clock_timestamp()-make_interval(secs=>COALESCE(cfg.rider_location_stale_sec,60))
    OR r.last_location_updated_at>clock_timestamp()+interval '30 seconds' THEN RETURN 'LOCATION_STALE'; END IF;
  vehicle:=lower(k.vehicle_type::text);
  weight_kg:=COALESCE(o.actual_weight_kg,COALESCE(NULLIF(regexp_replace(o.weight_category::text,'[^0-9.]','','g'),''),'0')::double precision);
  IF o.order_type::text IN ('ride','intercity_ride','intercity') AND vehicle IS DISTINCT FROM lower(o.vehicle_type::text) THEN RETURN 'WRONG_VEHICLE'; END IF;
  IF o.order_type::text='ride_sharing' AND vehicle NOT IN ('auto','cab') THEN RETURN 'WRONG_VEHICLE'; END IF;
  IF o.order_type::text LIKE '%parcel%' OR o.order_type::text LIKE '%delivery%' THEN
    IF (o.order_type::text<>'intercity_parcel' AND vehicle IS DISTINCT FROM CASE WHEN weight_kg<10 THEN 'bike' ELSE 'auto' END)
      OR (o.order_type::text='intercity_parcel' AND vehicle NOT IN ('bike','auto','cab')) THEN RETURN 'WRONG_VEHICLE'; END IF;
  END IF;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public.dispatch_eligibility(uuid,uuid,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.dispatch_eligibility(uuid,uuid,text) TO service_role;

-- Queue transport is best-effort; the job is the durable source of truth.
CREATE FUNCTION waydrop_internal.kick_dispatch(p_order_id uuid) RETURNS boolean
LANGUAGE plpgsql SET search_path=pg_catalog,public AS $$
DECLARE j waydrop_internal.dispatch_jobs%ROWTYPE; secret text;
BEGIN
  SELECT * INTO j FROM waydrop_internal.dispatch_jobs WHERE order_id=p_order_id FOR UPDATE;
  IF NOT FOUND OR j.state='terminal' OR (j.state='running' AND j.lease_until>clock_timestamp())
    OR j.next_at>clock_timestamp()+interval '2 seconds' OR j.queued_until>clock_timestamp() THEN RETURN false; END IF;
  BEGIN
    SELECT decrypted_secret INTO STRICT secret FROM vault.decrypted_secrets WHERE name='supabase_service_role_key' LIMIT 1;
    PERFORM net.http_post(url:='https://yvwpchffctiagevpqgwy.supabase.co/functions/v1/start-dispatch',
      headers:=jsonb_build_object('Content-Type','application/json','Authorization','Bearer '||secret),
      body:=jsonb_build_object('order_id',p_order_id,'is_background',true),timeout_milliseconds:=5000);
    UPDATE waydrop_internal.dispatch_jobs SET queued_until=clock_timestamp()+interval '30 seconds',kicks=kicks+1,last_error=NULL WHERE order_id=p_order_id;
    RETURN true;
  EXCEPTION WHEN OTHERS THEN
    UPDATE waydrop_internal.dispatch_jobs SET queued_until=NULL,last_error='ENQUEUE_FAILED',next_at=clock_timestamp()+interval '8 seconds' WHERE order_id=p_order_id;
    RETURN false;
  END;
END $$;

CREATE FUNCTION public.request_order_dispatch(p_order_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE o public.orders%ROWTYPE; kicked boolean;
BEGIN
  PERFORM waydrop_internal.require_enabled();
  SELECT * INTO o FROM public.orders WHERE id=p_order_id FOR NO KEY UPDATE;
  IF NOT FOUND OR o.order_status::text<>'searching' OR o.order_type::text IN ('intercity_ride','intercity_parcel') THEN RETURN jsonb_build_object('available',false); END IF;
  INSERT INTO waydrop_internal.dispatch_jobs(order_id) VALUES(p_order_id)
  ON CONFLICT(order_id) DO UPDATE SET requests=waydrop_internal.dispatch_jobs.requests+1,
    next_at=least(waydrop_internal.dispatch_jobs.next_at,greatest(clock_timestamp(),COALESCE(waydrop_internal.dispatch_jobs.last_step_at,clock_timestamp())+interval '2 seconds')),
    state=CASE WHEN waydrop_internal.dispatch_jobs.state='running' THEN 'running' ELSE 'ready' END;
  kicked:=waydrop_internal.kick_dispatch(p_order_id);
  RETURN jsonb_build_object('available',true,'enqueued',kicked,'coalesced',NOT kicked);
END $$;

CREATE FUNCTION public.claim_order_dispatch(p_order_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE j waydrop_internal.dispatch_jobs%ROWTYPE; o public.orders%ROWTYPE;
BEGIN
  PERFORM waydrop_internal.require_enabled();
  SELECT * INTO o FROM public.orders WHERE id=p_order_id FOR NO KEY UPDATE;
  SELECT * INTO j FROM waydrop_internal.dispatch_jobs WHERE order_id=p_order_id FOR UPDATE;
  IF j.order_id IS NULL THEN RETURN jsonb_build_object('claimed',false); END IF;
  IF o.order_status::text<>'searching' THEN
    UPDATE waydrop_internal.dispatch_jobs SET state='terminal',owner_token=NULL,lease_until=NULL WHERE order_id=p_order_id;
    RETURN jsonb_build_object('claimed',false);
  END IF;
  IF (j.state='running' AND j.lease_until>clock_timestamp()) OR j.next_at>clock_timestamp() OR j.state='terminal' THEN
    RETURN jsonb_build_object('claimed',false,'wait_ms',greatest(0,extract(epoch FROM (j.next_at-clock_timestamp()))*1000));
  END IF;
  UPDATE waydrop_internal.dispatch_jobs SET generation=generation+1,owner_token=gen_random_uuid(),
    lease_until=clock_timestamp()+interval '30 seconds',state='running',claimed_revision=requests,queued_until=NULL
  WHERE order_id=p_order_id RETURNING * INTO j;
  RETURN jsonb_build_object('claimed',true,'token',j.owner_token,'generation',j.generation);
END $$;

-- Lock order is rider(s), order, job, assignments. It matches atomic acceptance.
-- No locks are held while Edge waits for a response window or sends HTTP.
CREATE FUNCTION public.step_order_dispatch(p_order_id uuid,p_token uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE o public.orders%ROWTYPE; j waydrop_internal.dispatch_jobs%ROWTYPE;
  cfg public.dispatch_config%ROWTYPE; r public.riders%ROWTYPE; a public.rider_assignments%ROWTYPE;
  ids uuid[]; rid uuid; dist double precision; radius double precision; batch_size integer;
  age_sec double precision; rn integer:=1; offers integer:=0; active_offers integer:=0; due timestamptz; now_at timestamptz:=clock_timestamp();
BEGIN
  PERFORM waydrop_internal.require_enabled();
  -- Bounded candidate lookup, then lock/revalidate each selected rider.
  SELECT * INTO o FROM public.orders WHERE id=p_order_id;
  SELECT * INTO cfg FROM public.dispatch_config WHERE is_active ORDER BY updated_at DESC,id LIMIT 1;
  IF cfg.id IS NULL THEN RAISE EXCEPTION 'Dispatch configuration required'; END IF;
  age_sec:=extract(epoch FROM (now_at-o.created_at));
  IF cfg.allow_round_3 AND age_sec>=cfg.round_3_trigger_after_sec THEN rn:=3;
  ELSIF age_sec>=cfg.round_2_trigger_after_sec OR
    (NULLIF(o.dispatch_state->>'round1_no_rider_since','')::timestamptz<=now_at-make_interval(secs=>COALESCE(cfg.round_2_trigger_if_no_riders_sec,60))) THEN rn:=2; END IF;
  radius:=CASE rn WHEN 3 THEN cfg.round_3_radius_km WHEN 2 THEN cfg.round_2_radius_km ELSE cfg.round_1_radius_km END;
  batch_size:=greatest(1,least(50,CASE rn WHEN 3 THEN cfg.round_3_batch_size WHEN 2 THEN cfg.round_2_batch_size ELSE cfg.round_1_batch_size END));
  SELECT count(*) INTO active_offers FROM public.rider_assignments WHERE order_id=p_order_id AND assignment_status::text='sent' AND expires_at>now_at;
  batch_size:=greatest(0,batch_size-active_offers);
  SELECT array_agg(x.id ORDER BY x.id) INTO ids FROM (
    SELECT q.id FROM public.riders q WHERE q.account_status::text='online'
    AND q.current_lat BETWEEN o.pickup_lat-radius/111.0 AND o.pickup_lat+radius/111.0
    AND public.dispatch_eligibility(p_order_id,q.id,'offer') IS NULL
    AND 6371*acos(least(1.0,greatest(-1.0,cos(radians(o.pickup_lat))*cos(radians(q.current_lat))*cos(radians(q.current_lng)-radians(o.pickup_lng))+sin(radians(o.pickup_lat))*sin(radians(q.current_lat)))))<=radius
    AND NOT EXISTS(SELECT 1 FROM public.rider_assignments a0 WHERE a0.order_id=p_order_id AND a0.rider_id=q.id AND
      (a0.assignment_status::text='accepted' OR (a0.assignment_status::text='sent' AND a0.expires_at>now_at)
       OR (a0.assignment_status::text IN ('rejected','expired','sent') AND (o.rider_earning<=COALESCE(a0.last_seen_fare,a0.estimated_earnings,0) OR a0.hidden_until>now_at))))
    ORDER BY 6371*acos(least(1.0,greatest(-1.0,cos(radians(o.pickup_lat))*cos(radians(q.current_lat))*cos(radians(q.current_lng)-radians(o.pickup_lng))+sin(radians(o.pickup_lat))*sin(radians(q.current_lat))))),q.id LIMIT batch_size
  ) x;
  PERFORM 1 FROM public.riders WHERE id=ANY(COALESCE(ids,'{}'::uuid[])) ORDER BY id FOR NO KEY UPDATE;
  SELECT * INTO o FROM public.orders WHERE id=p_order_id FOR NO KEY UPDATE;
  SELECT * INTO j FROM waydrop_internal.dispatch_jobs WHERE order_id=p_order_id FOR UPDATE;
  IF p_token IS NULL OR j.order_id IS NULL OR j.owner_token IS DISTINCT FROM p_token OR j.state<>'running' OR j.lease_until<=clock_timestamp() THEN
    RETURN jsonb_build_object('applied',false,'code','STALE_OWNER');
  END IF;
  IF o.order_status::text<>'searching' THEN
    UPDATE waydrop_internal.dispatch_jobs SET state='terminal',owner_token=NULL,lease_until=NULL WHERE order_id=p_order_id;
    RETURN jsonb_build_object('applied',false,'code','ORDER_UNAVAILABLE');
  END IF;
  PERFORM set_config('waydrop.dispatch_token',p_token::text,true);
  UPDATE public.rider_assignments SET assignment_status='expired',updated_at=now_at,response_type='ignored'
  WHERE order_id=p_order_id AND assignment_status::text='sent' AND expires_at<=now_at;
  FOREACH rid IN ARRAY COALESCE(ids,'{}'::uuid[]) LOOP
    IF public.dispatch_eligibility(p_order_id,rid,'offer') IS NOT NULL THEN CONTINUE; END IF;
    SELECT * INTO r FROM public.riders WHERE id=rid;
    dist:=6371*acos(least(1.0,greatest(-1.0,cos(radians(o.pickup_lat))*cos(radians(r.current_lat))*cos(radians(r.current_lng)-radians(o.pickup_lng))+sin(radians(o.pickup_lat))*sin(radians(r.current_lat)))));
    IF dist>radius THEN CONTINUE; END IF;
    SELECT * INTO a FROM public.rider_assignments WHERE order_id=p_order_id AND rider_id=rid FOR UPDATE;
    IF FOUND AND (a.assignment_status::text NOT IN ('expired','rejected') OR a.hidden_until>now_at
      OR o.rider_earning<=COALESCE(a.last_seen_fare,a.estimated_earnings,0)) THEN CONTINUE; END IF;
    INSERT INTO public.rider_assignments AS target(order_id,rider_id,assignment_round,assignment_status,distance_km,
      estimated_earnings,sent_at,expires_at,last_seen_at,last_seen_fare,dispatch_generation)
    VALUES(p_order_id,rid,rn,'sent',dist,o.rider_earning,now_at,now_at+make_interval(secs=>greatest(1,cfg.rider_response_timeout_sec)),now_at,o.rider_earning,j.generation)
    ON CONFLICT(order_id,rider_id) DO UPDATE SET assignment_round=excluded.assignment_round,assignment_status='sent',distance_km=excluded.distance_km,
      estimated_earnings=excluded.estimated_earnings,sent_at=excluded.sent_at,expires_at=excluded.expires_at,last_seen_at=excluded.last_seen_at,
      last_seen_fare=excluded.last_seen_fare,dispatch_generation=excluded.dispatch_generation,responded_at=NULL,accepted_at=NULL,rejected_at=NULL,hidden_until=NULL
    WHERE target.assignment_status::text IN ('expired','rejected') AND COALESCE(target.hidden_until,now_at)<=now_at
      AND excluded.last_seen_fare>COALESCE(target.last_seen_fare,target.estimated_earnings,0);
    IF FOUND THEN
      offers:=offers+1;
      INSERT INTO public.order_assignment_logs(order_id,rider_id,assignment_round,assignment_status,rider_distance_km,estimated_pickup_time_min,sent_at)
      VALUES(p_order_id,rid,rn,'sent',dist,ceil(dist*3),now_at) ON CONFLICT(order_id,rider_id,assignment_round) DO NOTHING;
    END IF;
  END LOOP;
  UPDATE public.orders SET dispatch_state=CASE WHEN rn=1 AND offers=0 AND active_offers=0 THEN
      COALESCE(dispatch_state,'{}'::jsonb)||jsonb_build_object('round1_no_rider_since',COALESCE(dispatch_state->>'round1_no_rider_since',now_at::text))
    WHEN offers>0 THEN COALESCE(dispatch_state,'{}'::jsonb)-'round1_no_rider_since' ELSE dispatch_state END,
    dispatch_worker_running=false WHERE id=p_order_id AND (dispatch_worker_running IS TRUE OR
      (rn=1 AND offers=0 AND active_offers=0 AND NOT COALESCE(dispatch_state,'{}'::jsonb) ? 'round1_no_rider_since') OR
      (offers>0 AND COALESCE(dispatch_state,'{}'::jsonb) ? 'round1_no_rider_since'));
  SELECT min(expires_at) INTO due FROM public.rider_assignments WHERE order_id=p_order_id AND assignment_status::text='sent' AND expires_at>now_at;
  due:=least(COALESCE(due,'infinity'::timestamptz),now_at+make_interval(secs=>CASE
    WHEN offers>0 OR active_offers>0 THEN 5 WHEN j.empty_passes<3 THEN 2 ELSE 15 END));
  UPDATE waydrop_internal.dispatch_jobs SET state='idle',owner_token=NULL,lease_until=NULL,last_step_at=now_at,
    next_at=due,handled=requests,round_no=rn,last_error=NULL,
    empty_passes=CASE WHEN offers>0 OR active_offers>0 THEN 0 ELSE empty_passes+1 END WHERE order_id=p_order_id;
  PERFORM set_config('waydrop.dispatch_token','',true);
  RETURN jsonb_build_object('applied',true,'offers',offers,'round',rn,'next_ms',least(15000,greatest(1000,extract(epoch FROM (due-now_at))*1000)));
END $$;

CREATE FUNCTION public.release_order_dispatch(p_order_id uuid,p_token uuid) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE j waydrop_internal.dispatch_jobs%ROWTYPE;
BEGIN
  PERFORM 1 FROM public.orders WHERE id=p_order_id FOR NO KEY UPDATE;
  SELECT * INTO j FROM waydrop_internal.dispatch_jobs WHERE order_id=p_order_id FOR UPDATE;
  IF p_token IS NULL OR j.order_id IS NULL OR j.owner_token IS DISTINCT FROM p_token OR j.state<>'running' OR j.lease_until<=clock_timestamp() THEN RETURN false; END IF;
  PERFORM set_config('waydrop.dispatch_token',p_token::text,true);
  UPDATE public.orders SET dispatch_worker_running=false WHERE id=p_order_id AND dispatch_worker_running IS TRUE;
  UPDATE waydrop_internal.dispatch_jobs SET state='ready',owner_token=NULL,lease_until=NULL,next_at=clock_timestamp()+interval '8 seconds',last_error='WORKER_INTERRUPTED' WHERE order_id=p_order_id;
  PERFORM set_config('waydrop.dispatch_token','',true);
  RETURN true;
END $$;

-- Durable, per-notification/per-registration work. Never store tokens twice.
CREATE TABLE waydrop_internal.notification_jobs (
  notification_id uuid PRIMARY KEY REFERENCES public.notifications(id) ON DELETE CASCADE,
  user_id uuid NOT NULL, snapshot_done boolean NOT NULL DEFAULT false,
  next_at timestamptz NOT NULL DEFAULT clock_timestamp(), queued_until timestamptz,
  state text NOT NULL DEFAULT 'pending', kicks bigint NOT NULL DEFAULT 0,last_error text
);
CREATE TABLE waydrop_internal.notification_devices (
  notification_id uuid NOT NULL REFERENCES waydrop_internal.notification_jobs(notification_id) ON DELETE CASCADE,
  device_id uuid NOT NULL, registered_at timestamptz NOT NULL,
  state text NOT NULL DEFAULT 'pending' CHECK(state IN ('pending','claimed','sending','retry','sent','terminal','uncertain','skipped')),
  owner_token uuid, lease_until timestamptz, attempts integer NOT NULL DEFAULT 0 CHECK(attempts BETWEEN 0 AND 5),
  next_at timestamptz NOT NULL DEFAULT clock_timestamp(), last_code text,
  PRIMARY KEY(notification_id,device_id,registered_at)
);
CREATE INDEX notification_jobs_due ON waydrop_internal.notification_jobs(next_at) WHERE state IN ('pending','retry','partial');
ALTER TABLE waydrop_internal.notification_jobs ENABLE ROW LEVEL SECURITY;
ALTER TABLE waydrop_internal.notification_devices ENABLE ROW LEVEL SECURITY;

CREATE FUNCTION waydrop_internal.refresh_notification(p_id uuid) RETURNS void LANGUAGE plpgsql SET search_path=pg_catalog,public AS $$
DECLARE n integer; successes integer; pending integer; ambiguous integer; failures integer; due timestamptz; status text;
BEGIN
  SELECT count(*),count(*) FILTER(WHERE state='sent'),count(*) FILTER(WHERE state IN ('pending','claimed','sending','retry')),
    count(*) FILTER(WHERE state='uncertain'),count(*) FILTER(WHERE state='terminal'),
    min(CASE WHEN state IN ('claimed','sending') THEN lease_until ELSE next_at END) FILTER(WHERE state IN ('pending','claimed','sending','retry'))
  INTO n,successes,pending,ambiguous,failures,due FROM waydrop_internal.notification_devices WHERE notification_id=p_id;
  status:=CASE WHEN pending>0 THEN CASE WHEN successes>0 THEN 'partial' ELSE 'retry' END
    WHEN ambiguous>0 THEN 'uncertain' WHEN failures>0 THEN CASE WHEN successes>0 THEN 'partial_failed' ELSE 'failed' END
    WHEN successes>0 THEN 'sent' ELSE 'skipped' END;
  UPDATE waydrop_internal.notification_jobs SET state=status,next_at=COALESCE(due,'infinity'::timestamptz),queued_until=NULL WHERE notification_id=p_id;
  UPDATE public.notifications SET delivery_status=status,push_sent=successes>0,
    delivery_error=CASE WHEN ambiguous>0 THEN 'DELIVERY_UNCERTAIN' WHEN failures>0 THEN 'DELIVERY_TERMINAL' WHEN n=0 THEN 'NO_REGISTERED_TOKENS' ELSE NULL END
  WHERE id=p_id AND (delivery_status,push_sent,delivery_error) IS DISTINCT FROM
    (status,successes>0,CASE WHEN ambiguous>0 THEN 'DELIVERY_UNCERTAIN' WHEN failures>0 THEN 'DELIVERY_TERMINAL' WHEN n=0 THEN 'NO_REGISTERED_TOKENS' ELSE NULL END);
END $$;

CREATE FUNCTION waydrop_internal.kick_notification(p_id uuid) RETURNS boolean LANGUAGE plpgsql SET search_path=pg_catalog,public AS $$
DECLARE j waydrop_internal.notification_jobs%ROWTYPE; secret text;
BEGIN
  SELECT * INTO j FROM waydrop_internal.notification_jobs WHERE notification_id=p_id FOR UPDATE;
  IF NOT FOUND OR j.state NOT IN ('pending','retry','partial') OR j.next_at>clock_timestamp() OR j.queued_until>clock_timestamp() THEN RETURN false; END IF;
  BEGIN
    SELECT decrypted_secret INTO STRICT secret FROM vault.decrypted_secrets WHERE name='supabase_service_role_key' LIMIT 1;
    PERFORM net.http_post(url:='https://yvwpchffctiagevpqgwy.supabase.co/functions/v1/send-push-notification',
      headers:=jsonb_build_object('Content-Type','application/json','Authorization','Bearer '||secret),
      body:=jsonb_build_object('data',jsonb_build_object('notification_id',p_id)),timeout_milliseconds:=5000);
    UPDATE waydrop_internal.notification_jobs SET queued_until=clock_timestamp()+interval '30 seconds',kicks=kicks+1,last_error=NULL WHERE notification_id=p_id;
    RETURN true;
  EXCEPTION WHEN OTHERS THEN
    UPDATE waydrop_internal.notification_jobs SET queued_until=NULL,last_error='ENQUEUE_FAILED',next_at=clock_timestamp()+interval '8 seconds' WHERE notification_id=p_id;
    RETURN false;
  END;
END $$;

CREATE FUNCTION public.claim_notification_delivery(p_id uuid,p_actor uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE n public.notifications%ROWTYPE; j waydrop_internal.notification_jobs%ROWTYPE; result jsonb;
BEGIN
  PERFORM waydrop_internal.require_enabled();
  SELECT * INTO n FROM public.notifications WHERE id=p_id;
  IF NOT FOUND OR (p_actor IS NOT NULL AND n.user_id IS DISTINCT FROM p_actor) THEN RAISE EXCEPTION 'Notification unavailable' USING ERRCODE='42501'; END IF;
  INSERT INTO waydrop_internal.notification_jobs(notification_id,user_id) VALUES(n.id,n.user_id) ON CONFLICT DO NOTHING;
  SELECT * INTO j FROM waydrop_internal.notification_jobs WHERE notification_id=p_id FOR UPDATE;
  IF NOT j.snapshot_done THEN
    INSERT INTO waydrop_internal.notification_devices(notification_id,device_id,registered_at)
    SELECT p_id,t.id,t.updated_at FROM public.user_device_tokens t WHERE t.user_id=n.user_id AND t.updated_at IS NOT NULL ON CONFLICT DO NOTHING;
    UPDATE waydrop_internal.notification_jobs SET snapshot_done=true WHERE notification_id=p_id;
  END IF;
  -- Pre-send crash is recoverable. A committed send-intent crash is uncertain,
  -- never automatically re-sent: FCM has no transactional idempotency key.
  UPDATE waydrop_internal.notification_devices SET state=CASE WHEN attempts>=5 THEN 'terminal' ELSE 'retry' END,owner_token=NULL,next_at=clock_timestamp(),last_code='CLAIM_ABANDONED'
    WHERE notification_id=p_id AND state='claimed' AND lease_until<=clock_timestamp();
  UPDATE waydrop_internal.notification_devices SET state='uncertain',last_code='SEND_ABANDONED'
    WHERE notification_id=p_id AND state='sending' AND lease_until<=clock_timestamp();
  UPDATE waydrop_internal.notification_devices d SET state='skipped',last_code='REGISTRATION_CHANGED'
    WHERE d.notification_id=p_id AND d.state IN ('pending','retry') AND NOT EXISTS(
      SELECT 1 FROM public.user_device_tokens t WHERE t.id=d.device_id AND t.user_id=n.user_id AND t.updated_at=d.registered_at);
  WITH chosen AS (
    SELECT d.notification_id,d.device_id,d.registered_at FROM waydrop_internal.notification_devices d
    WHERE d.notification_id=p_id AND d.state IN ('pending','retry') AND d.next_at<=clock_timestamp() AND d.attempts<5
    ORDER BY d.device_id LIMIT 20 FOR UPDATE
  ), claimed AS (
    UPDATE waydrop_internal.notification_devices d SET state='claimed',attempts=attempts+1,owner_token=gen_random_uuid(),lease_until=clock_timestamp()+interval '30 seconds'
    FROM chosen c WHERE (d.notification_id,d.device_id,d.registered_at)=(c.notification_id,c.device_id,c.registered_at) RETURNING d.*
  ) SELECT COALESCE(jsonb_agg(jsonb_build_object('device_id',c.device_id,'registered_at',c.registered_at,'token',c.owner_token,'fcm_token',t.fcm_token)),'[]'::jsonb)
  INTO result FROM claimed c JOIN public.user_device_tokens t ON t.id=c.device_id AND t.user_id=n.user_id AND t.updated_at=c.registered_at;
  PERFORM waydrop_internal.refresh_notification(p_id);
  RETURN jsonb_build_object('state',(SELECT state FROM waydrop_internal.notification_jobs WHERE notification_id=p_id),
    'notification',jsonb_build_object('id',n.id,'user_id',n.user_id,'title',n.title,'body',n.body,'data',COALESCE(n.payload,'{}'::jsonb)||jsonb_build_object('type',n.notification_type,'notification_id',n.id,'reference_id',n.reference_id,'reference_type',n.reference_type)), 'devices',result);
END $$;

CREATE FUNCTION public.begin_notification_device(p_id uuid,p_device uuid,p_registered timestamptz,p_token uuid) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE d waydrop_internal.notification_devices%ROWTYPE; recipient uuid;
BEGIN
  SELECT user_id INTO recipient FROM waydrop_internal.notification_jobs WHERE notification_id=p_id FOR UPDATE;
  SELECT * INTO d FROM waydrop_internal.notification_devices WHERE notification_id=p_id AND device_id=p_device AND registered_at=p_registered FOR UPDATE;
  IF p_token IS NULL OR d.notification_id IS NULL OR d.owner_token IS DISTINCT FROM p_token OR d.state<>'claimed' OR d.lease_until<=clock_timestamp() THEN RETURN false; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.user_device_tokens WHERE id=p_device AND user_id=recipient AND updated_at=p_registered) THEN
    UPDATE waydrop_internal.notification_devices SET state='skipped',last_code='REGISTRATION_CHANGED' WHERE notification_id=p_id AND device_id=p_device AND registered_at=p_registered;
    PERFORM waydrop_internal.refresh_notification(p_id); RETURN false;
  END IF;
  UPDATE waydrop_internal.notification_devices SET state='sending',lease_until=clock_timestamp()+interval '30 seconds'
  WHERE notification_id=p_id AND device_id=p_device AND registered_at=p_registered;
  PERFORM waydrop_internal.refresh_notification(p_id);
  RETURN true;
END $$;

CREATE FUNCTION public.finish_notification_device(p_id uuid,p_device uuid,p_registered timestamptz,p_token uuid,p_result text,p_retry_after integer DEFAULT 0) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE d waydrop_internal.notification_devices%ROWTYPE; recipient uuid; wait_sec integer;
BEGIN
  IF p_result NOT IN ('SENT','UNREGISTERED','PERMANENT','TRANSIENT','QUOTA','UNCERTAIN','SKIPPED') THEN RAISE EXCEPTION 'Invalid delivery outcome'; END IF;
  SELECT user_id INTO recipient FROM waydrop_internal.notification_jobs WHERE notification_id=p_id FOR UPDATE;
  SELECT * INTO d FROM waydrop_internal.notification_devices WHERE notification_id=p_id AND device_id=p_device AND registered_at=p_registered FOR UPDATE;
  IF p_result='SENT' AND d.state='sent' AND d.owner_token=p_token THEN RETURN true; END IF;
  IF p_token IS NULL OR d.notification_id IS NULL OR d.owner_token IS DISTINCT FROM p_token OR d.state NOT IN ('claimed','sending','uncertain') THEN RETURN false; END IF;
  IF d.state='claimed' AND (d.lease_until<=clock_timestamp() OR p_result NOT IN ('TRANSIENT','PERMANENT','SKIPPED')) THEN RETURN false; END IF;
  wait_sec:=greatest(least(greatest(0,COALESCE(p_retry_after,0)),3600),CASE WHEN p_result='QUOTA' THEN 60 ELSE least(120,8*(2^greatest(0,d.attempts-1))::integer) END);
  UPDATE waydrop_internal.notification_devices SET state=CASE
    WHEN p_result='SENT' THEN 'sent' WHEN p_result='SKIPPED' THEN 'skipped' WHEN p_result='UNCERTAIN' THEN 'uncertain'
    WHEN p_result IN ('TRANSIENT','QUOTA') AND attempts<5 THEN 'retry' ELSE 'terminal' END,
    last_code=p_result,next_at=clock_timestamp()+make_interval(secs=>wait_sec)
  WHERE notification_id=p_id AND device_id=p_device AND registered_at=p_registered;
  IF p_result='UNREGISTERED' THEN
    DELETE FROM public.user_device_tokens WHERE id=p_device AND user_id=recipient AND updated_at=p_registered;
  END IF;
  PERFORM waydrop_internal.refresh_notification(p_id);
  RETURN true;
END $$;

CREATE FUNCTION public.recover_waydrop_work(p_limit integer DEFAULT 50) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE x record; d integer:=0; n integer:=0;
BEGIN
  PERFORM waydrop_internal.require_enabled();
  -- Each helper takes parent locks in the same order as its worker. SKIP LOCKED
  -- is deliberately not used on jobs before their order lock (no inversion).
  FOR x IN SELECT order_id FROM (SELECT order_id FROM waydrop_internal.dispatch_jobs WHERE next_at<=clock_timestamp()
      AND (queued_until IS NULL OR queued_until<=clock_timestamp())
      AND state<>'terminal' AND (state<>'running' OR lease_until<=clock_timestamp()) ORDER BY next_at,order_id LIMIT least(100,greatest(1,p_limit))) batch ORDER BY order_id LOOP
    PERFORM 1 FROM public.orders WHERE id=x.order_id FOR NO KEY UPDATE;
    IF waydrop_internal.kick_dispatch(x.order_id) THEN d:=d+1; END IF;
  END LOOP;
  FOR x IN SELECT notification_id FROM (SELECT notification_id FROM waydrop_internal.notification_jobs WHERE next_at<=clock_timestamp()
      AND (queued_until IS NULL OR queued_until<=clock_timestamp())
      AND state IN ('pending','retry','partial') ORDER BY next_at,notification_id LIMIT least(100,greatest(1,p_limit))) batch ORDER BY notification_id LOOP
    IF waydrop_internal.kick_notification(x.notification_id) THEN n:=n+1; END IF;
  END LOOP;
  RETURN jsonb_build_object('dispatch_kicks',d,'notification_kicks',n);
END $$;

-- No table is exposed to client roles. Only narrow service RPCs are exposed.
REVOKE ALL ON ALL TABLES IN SCHEMA waydrop_internal FROM PUBLIC,anon,authenticated;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA waydrop_internal FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.request_order_dispatch(uuid),public.claim_order_dispatch(uuid),public.step_order_dispatch(uuid,uuid),public.release_order_dispatch(uuid,uuid),
  public.claim_notification_delivery(uuid,uuid),public.begin_notification_device(uuid,uuid,timestamptz,uuid),public.finish_notification_device(uuid,uuid,timestamptz,uuid,text,integer),public.recover_waydrop_work(integer) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.request_order_dispatch(uuid),public.claim_order_dispatch(uuid),public.step_order_dispatch(uuid,uuid),public.release_order_dispatch(uuid,uuid),
  public.claim_notification_delivery(uuid,uuid),public.begin_notification_device(uuid,uuid,timestamptz,uuid),public.finish_notification_device(uuid,uuid,timestamptz,uuid,text,integer),public.recover_waydrop_work(integer) TO service_role;
