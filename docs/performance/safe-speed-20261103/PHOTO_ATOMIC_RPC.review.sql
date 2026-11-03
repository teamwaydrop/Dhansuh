-- LOCAL REVIEW CANDIDATE ONLY. Not an automatic migration or production approval.
-- Install with the matching handler only after managed trigger/Auth/cutover checks.
CREATE OR REPLACE FUNCTION public.record_order_photo_proof_v1(
 p_order_id uuid, p_actor_user_id uuid, p_rider_id uuid, p_photo_type text,
 p_photo_url text, p_file_sha256 text, p_latitude numeric DEFAULT NULL,
 p_longitude numeric DEFAULT NULL, p_device_id text DEFAULT NULL, p_ip_address inet DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp
AS $proof$
DECLARE
 v_order public.orders%ROWTYPE;
 v_owner uuid;
 v_photo public.order_parcel_photos%ROWTYPE;
BEGIN
 IF p_photo_type IS NULL OR p_photo_type NOT IN ('pickup','dropoff')
 OR p_photo_url IS NULL OR p_photo_url=''
 OR p_file_sha256 IS NULL OR p_file_sha256 !~ '^[0-9a-f]{64}$'
 THEN RAISE EXCEPTION 'INVALID_PROOF' USING ERRCODE='22023'; END IF;
 -- Order first, then rider: same order row serializes assignment changes and proof effects.
 SELECT * INTO v_order FROM public.orders WHERE id=p_order_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'ORDER_NOT_FOUND' USING ERRCODE='P0002'; END IF;
 IF p_rider_id IS NULL OR v_order.rider_id IS DISTINCT FROM p_rider_id
 THEN RAISE EXCEPTION 'PROOF_FORBIDDEN' USING ERRCODE='42501'; END IF;
 SELECT user_id INTO v_owner FROM public.riders WHERE id=p_rider_id FOR SHARE;
 IF NOT FOUND OR p_actor_user_id IS NULL OR v_owner IS DISTINCT FROM p_actor_user_id
 THEN RAISE EXCEPTION 'PROOF_FORBIDDEN' USING ERRCODE='42501'; END IF;

 SELECT * INTO v_photo FROM public.order_parcel_photos
 WHERE order_id=p_order_id AND rider_id=p_rider_id AND photo_type=p_photo_type AND photo_url=p_photo_url
 ORDER BY captured_at DESC,id LIMIT 1;
 IF FOUND THEN
   IF v_photo.file_sha256 IS DISTINCT FROM p_file_sha256
   OR NOT EXISTS(SELECT 1 FROM public.order_verifications v WHERE v.order_id=p_order_id
     AND v.verification_type=p_photo_type AND v.verification_status='verified'
     AND v.photo_url=p_photo_url AND v.created_by=p_actor_user_id
     AND v.metadata->>'photo_log_id'=v_photo.id::text AND v.metadata->>'file_sha256'=p_file_sha256)
   OR NOT EXISTS(SELECT 1 FROM public.parcel_security_logs l WHERE l.order_id=p_order_id
     AND l.rider_id=p_rider_id AND l.event_type=p_photo_type||'_photo_uploaded'
     AND l.metadata->>'photo_id'=v_photo.id::text AND l.metadata->>'file_sha256'=p_file_sha256)
   OR (p_photo_type='pickup' AND v_order.pickup_verification_completed IS DISTINCT FROM true)
   THEN RAISE EXCEPTION 'PROOF_RECONCILIATION_REQUIRED'; END IF;
   RETURN jsonb_build_object('success',true,'photo_log_id',v_photo.id,'file_sha256',p_file_sha256,'replayed',true);
 END IF;
 IF EXISTS(SELECT 1 FROM public.order_verifications v WHERE v.order_id=p_order_id
   AND v.verification_type=p_photo_type AND v.photo_url=p_photo_url)
 THEN RAISE EXCEPTION 'PROOF_RECONCILIATION_REQUIRED'; END IF;

 INSERT INTO public.order_parcel_photos(order_id,rider_id,photo_url,photo_type,latitude,longitude,file_sha256)
 VALUES(p_order_id,p_rider_id,p_photo_url,p_photo_type,p_latitude,p_longitude,p_file_sha256)
 RETURNING * INTO v_photo;
 IF p_photo_type='pickup' THEN
   UPDATE public.orders SET pickup_verification_completed=true,pickup_verification_completed_at=clock_timestamp()
   WHERE id=p_order_id; -- order remains locked; assignment cannot change before commit.
 END IF;
 INSERT INTO public.order_verifications(order_id,verification_type,verification_status,photo_url,latitude,longitude,metadata,created_by)
 VALUES(p_order_id,p_photo_type,'verified',p_photo_url,p_latitude,p_longitude,
   jsonb_build_object('file_sha256',p_file_sha256,'photo_log_id',v_photo.id,'device_id',p_device_id),p_actor_user_id);
 INSERT INTO public.parcel_security_logs(order_id,sender_user_id,rider_id,event_type,latitude,longitude,event_latitude,event_longitude,ip_address,device_id,metadata)
 VALUES(p_order_id,v_order.user_id,p_rider_id,p_photo_type||'_photo_uploaded',p_latitude,p_longitude,p_latitude,p_longitude,p_ip_address,p_device_id,
   jsonb_build_object('photo_id',v_photo.id,'photo_type',p_photo_type,'file_sha256',p_file_sha256,'client_timestamp',clock_timestamp()));
 RETURN jsonb_build_object('success',true,'photo_log_id',v_photo.id,'file_sha256',p_file_sha256,'replayed',false);
END;
$proof$;
REVOKE ALL ON FUNCTION public.record_order_photo_proof_v1(uuid,uuid,uuid,text,text,text,numeric,numeric,text,inet) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.record_order_photo_proof_v1(uuid,uuid,uuid,text,text,text,numeric,numeric,text,inet) TO service_role;
