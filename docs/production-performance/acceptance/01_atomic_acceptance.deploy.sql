-- REVIEWED LOCAL IMPLEMENTATION. NOT APPLIED TO PRODUCTION.
-- Outside automatic migrations. Local tests replace terminal ROLLBACK only on
-- their fixed synthetic loopback database. Final release needs separate GO.
BEGIN;
SET LOCAL lock_timeout='1s';
SET LOCAL statement_timeout='15s';
DO $guard$
BEGIN
  IF to_regprocedure('public.claim_order_assignment_atomic(uuid,uuid,uuid)') IS NOT NULL
     OR to_regclass('public.rider_assignments_one_accepted_per_order') IS NOT NULL THEN
    RAISE EXCEPTION 'Acceptance objects already exist; inspect drift instead of replacing';
  END IF;
  IF EXISTS (SELECT 1 FROM public.rider_assignments WHERE assignment_status='accepted'
             GROUP BY order_id HAVING count(*)>1) THEN
    RAISE EXCEPTION 'Existing duplicate accepted assignments require separately reviewed remediation';
  END IF;
END $guard$;

-- Correctness constraint, not a speculative performance index. Covers every writer.
CREATE UNIQUE INDEX rider_assignments_one_accepted_per_order
ON public.rider_assignments(order_id) WHERE assignment_status='accepted';

CREATE FUNCTION public.claim_order_assignment_atomic(
  p_order_id uuid, p_rider_id uuid, p_actor_user_id uuid
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,public
AS $function$
DECLARE
  v_order public.orders%ROWTYPE;
  v_rider public.riders%ROWTYPE;
  v_assignment public.rider_assignments%ROWTYPE;
  v_required_mode public.partner_service_mode_enum;
  v_breakdown jsonb;
  v_subscription boolean;
  v_estimated_earnings numeric;
  v_now timestamptz:=now();
BEGIN
  -- Only the authenticated Edge service client may call this RPC. The actor
  -- comes from getUser(token), never from the request body. No client grants.
  IF (SELECT auth.role()) IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'Service-role caller required' USING ERRCODE='42501';
  END IF;
  -- PostgREST uses READ COMMITTED. A caller with a pinned older snapshot could
  -- miss another order accepted while waiting for the rider lock. Fail closed
  -- instead of allowing that REPEATABLE READ write-skew case.
  IF current_setting('transaction_isolation')<>'read committed' THEN
    RAISE EXCEPTION 'Acceptance requires READ COMMITTED isolation' USING ERRCODE='40001';
  END IF;
  IF p_order_id IS NULL OR p_rider_id IS NULL OR p_actor_user_id IS NULL THEN
    RETURN jsonb_build_object('http_status',400,'success',false,'message','Order, rider and authenticated actor are required');
  END IF;

  -- Rider first serializes simultaneous accepts of DIFFERENT orders by one
  -- rider. The subsequent order lock serializes DIFFERENT riders for one order.
  SELECT * INTO v_rider FROM public.riders WHERE id=p_rider_id FOR NO KEY UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('http_status',404,'success',false,'message','Rider not found');
  END IF;
  IF v_rider.user_id IS DISTINCT FROM p_actor_user_id THEN
    RETURN jsonb_build_object('http_status',403,'success',false,'message','Forbidden: rider_id does not belong to authenticated user');
  END IF;
  SELECT * INTO v_order FROM public.orders WHERE id=p_order_id FOR NO KEY UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('http_status',404,'success',false,'message','Order not found');
  END IF;

  -- Idempotent retry reads committed state; no timestamps, fares, logs or
  -- notifications are rewritten. Ownership was checked before this branch.
  IF v_order.order_status='accepted' AND v_order.rider_id=p_rider_id THEN
    SELECT * INTO v_assignment FROM public.rider_assignments
    WHERE order_id=p_order_id AND rider_id=p_rider_id AND assignment_status='accepted';
    IF NOT FOUND THEN
      RETURN jsonb_build_object('http_status',409,'success',false,'code','ACCEPTANCE_STATE_INCONSISTENT','message','Accepted order has no matching accepted assignment');
    END IF;
    RETURN jsonb_build_object('http_status',200,'success',true,'idempotent',true,
      'message','Order already accepted by this rider','order',to_jsonb(v_order),'assignment',to_jsonb(v_assignment));
  END IF;
  IF v_order.order_status<>'searching' THEN
    RETURN jsonb_build_object('http_status',409,'success',false,
      'message',CASE WHEN v_order.order_status='accepted' THEN 'Order already accepted by another rider' ELSE 'Order no longer available' END,
      'current_status',v_order.order_status);
  END IF;

  -- Re-read and validate eligibility under the locks. Existing rules retained.
  v_required_mode:=public.get_required_service_mode(v_order.order_type::text,v_order.distance_meters);
  IF v_rider.service_mode IS DISTINCT FROM v_required_mode THEN
    RETURN jsonb_build_object('http_status',403,'success',false,'code','WRONG_SERVICE_MODE',
      'message',CASE WHEN v_rider.service_mode IS NULL THEN 'Choose a Service Mode in your Profile before accepting orders.'
        WHEN v_required_mode='local' THEN 'Switch to Local Rides mode to accept this order.' ELSE 'Switch to Intercity Traveller mode to accept this order.' END);
  END IF;
  IF v_rider.user_id=v_order.user_id THEN
    RETURN jsonb_build_object('http_status',400,'success',false,'message','You cannot accept your own order');
  END IF;
  IF v_rider.account_status IS DISTINCT FROM 'online' THEN
    RETURN jsonb_build_object('http_status',400,'success',false,'message','Rider not online');
  END IF;
  IF public.is_rider_blocked_by_tax_due(p_rider_id) THEN
    RETURN jsonb_build_object('http_status',403,'success',false,'code','TAX_DUE_THRESHOLD_BLOCKED',
      'message','New orders are paused because your Government Tax Due has reached the limit. Pay the due amount to continue receiving orders.');
  END IF;
  IF public.is_rider_blocked_by_cod_limit(p_rider_id) THEN
    RETURN jsonb_build_object('http_status',403,'success',false,'code','COD_LIMIT_EXCEEDED',
      'message','You''ve reached your cash collection limit. Please settle your pending cash amount to resume receiving orders.');
  END IF;
  IF public.rider_is_on_active_trip(p_rider_id) THEN
    RETURN jsonb_build_object('http_status',400,'success',false,'message','Rider already has an active order');
  END IF;

  SELECT * INTO v_assignment FROM public.rider_assignments
  WHERE order_id=p_order_id AND rider_id=p_rider_id FOR UPDATE;
  IF FOUND AND v_assignment.assignment_status NOT IN ('sent','accepted_by_user','rejected','expired') THEN
    RETURN jsonb_build_object('http_status',400,'success',false,'message','Assignment already handled',
      'assignment_status',v_assignment.assignment_status);
  END IF;

  -- Use the SAME canonical function and locked order rates. Preserve the
  -- passenger total and existing promo discount; no formula is duplicated.
  v_estimated_earnings:=v_order.rider_earning;
  v_subscription:=COALESCE(v_rider.subscription_active AND v_rider.subscription_expires_at>v_now,false);
  v_breakdown:=public.calculate_fare_breakdown(
    v_order.current_fare,v_order.actual_fare,COALESCE(v_order.gst_percentage,5),
    CASE WHEN v_subscription THEN 0 ELSE COALESCE(v_order.commission_percentage,10) END,
    GREATEST(0,v_order.current_fare-COALESCE(v_order.final_fare,v_order.current_fare)));
  IF v_breakdown IS NULL THEN
    RAISE EXCEPTION 'Failed to calculate fare breakdown';
  END IF;

  -- Every write below belongs to this single RPC transaction. Any constraint,
  -- trigger, assignment, log, timeout or commit failure aborts all its writes.
  UPDATE public.orders SET order_status='accepted',rider_id=p_rider_id,
    accepted_at=v_now,updated_at=v_now,
    current_fare=(v_breakdown->>'current_fare')::numeric,
    final_fare=(v_breakdown->>'final_fare')::numeric,
    commission_amount=(v_breakdown->>'commission_amount')::numeric,
    gst_amount=(v_breakdown->>'gst_amount')::numeric,
    rider_earning=(v_breakdown->>'rider_earning')::numeric,
    subscription_commission_waived=v_subscription
  WHERE id=p_order_id RETURNING * INTO v_order;

  UPDATE public.rider_assignments SET assignment_status='expired',updated_at=v_now,
    response_type='ignored',last_response_at=v_now
  WHERE order_id=p_order_id AND rider_id<>p_rider_id AND assignment_status='sent';
  UPDATE public.order_assignment_logs SET assignment_status='expired',responded_at=v_now
  WHERE order_id=p_order_id AND rider_id<>p_rider_id AND assignment_status='sent';

  IF v_assignment.id IS NULL THEN
    INSERT INTO public.rider_assignments AS ra(order_id,rider_id,assignment_round,assignment_status,
      sent_at,responded_at,accepted_at,updated_at,response_type,last_response_at,estimated_earnings,
      expires_at)
    VALUES(p_order_id,p_rider_id,1,'accepted',v_now,v_now,v_now,v_now,'accepted',v_now,v_estimated_earnings,
      v_now+(COALESCE((SELECT rider_response_timeout_sec FROM public.dispatch_config WHERE is_active=true LIMIT 1),25)||' seconds')::interval)
    ON CONFLICT(order_id,rider_id) DO UPDATE SET assignment_status='accepted',
      responded_at=EXCLUDED.responded_at,updated_at=EXCLUDED.updated_at,
      response_type='accepted',last_response_at=EXCLUDED.last_response_at
    WHERE ra.assignment_status IN ('sent','accepted_by_user','rejected','expired')
    RETURNING * INTO v_assignment;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Assignment changed during acceptance; retry' USING ERRCODE='40001';
    END IF;
  ELSE
    UPDATE public.rider_assignments SET assignment_status='accepted',responded_at=v_now,
      updated_at=v_now,response_type='accepted',last_response_at=v_now
    WHERE id=v_assignment.id RETURNING * INTO v_assignment;
  END IF;
  UPDATE public.order_assignment_logs SET assignment_status='accepted',responded_at=v_now
  WHERE order_id=p_order_id AND rider_id=p_rider_id;
  IF NOT FOUND THEN
    INSERT INTO public.order_assignment_logs(order_id,rider_id,assignment_round,assignment_status,sent_at,responded_at)
    VALUES(p_order_id,p_rider_id,1,'accepted',v_now,v_now);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.rider_assignments
                 WHERE order_id=p_order_id AND rider_id=p_rider_id AND assignment_status='accepted') THEN
    RAISE EXCEPTION 'Accepted assignment was not retained; retry' USING ERRCODE='40001';
  END IF;
  RETURN jsonb_build_object('http_status',200,'success',true,'order',to_jsonb(v_order),'assignment',to_jsonb(v_assignment));
END;
$function$;
REVOKE ALL ON FUNCTION public.claim_order_assignment_atomic(uuid,uuid,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.claim_order_assignment_atomic(uuid,uuid,uuid) TO service_role;
COMMIT;
