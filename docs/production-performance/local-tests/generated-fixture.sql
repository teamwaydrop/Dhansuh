DO $$ BEGIN IF current_database() IS DISTINCT FROM 'waydrop_perf_test' OR inet_server_addr() IS DISTINCT FROM inet '127.0.0.1' OR inet_server_port() IS DISTINCT FROM 54329 THEN RAISE EXCEPTION 'Synthetic loopback database required'; END IF; END $$; DROP SCHEMA public CASCADE; CREATE SCHEMA public; DROP SCHEMA IF EXISTS auth CASCADE; CREATE SCHEMA auth;DO $$ BEGIN IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='anon') THEN CREATE ROLE anon NOLOGIN; CREATE ROLE authenticated NOLOGIN; CREATE ROLE service_role NOLOGIN BYPASSRLS; END IF; END $$;CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$; CREATE FUNCTION auth.role() RETURNS text LANGUAGE sql STABLE AS $$ SELECT nullif(current_setting('request.jwt.claim.role',true),'') $$; CREATE FUNCTION auth.email() RETURNS text LANGUAGE sql STABLE AS $$ SELECT nullif(current_setting('request.jwt.claim.email',true),'') $$; GRANT USAGE ON SCHEMA auth,public TO anon,authenticated,service_role; GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA auth TO anon,authenticated,service_role;CREATE TYPE "activation_status_enum" AS ENUM ('inactive','profile_pending','active','suspended');CREATE TYPE "assignment_status_enum" AS ENUM ('sent','viewed','accepted','rejected','timed_out','expired','cancelled');CREATE TYPE "cancelled_by_enum" AS ENUM ('user','rider','admin','system');CREATE TYPE "cashfree_beneficiary_status_enum" AS ENUM ('pending','active','failed','disabled');CREATE TYPE "dispute_status_enum" AS ENUM ('open','investigating','resolved_paid','resolved_unpaid');CREATE TYPE "fare_payment_method_enum" AS ENUM ('personal_upi','cashfree','cash');CREATE TYPE "intercity_assignment_status_enum" AS ENUM ('sent','viewed','accepted','rejected','timed_out','expired','cancelled','accepted_by_user');CREATE TYPE "kyc_status_enum" AS ENUM ('pending','under_review','approved','rejected','resubmitted');CREATE TYPE "order_status_enum" AS ENUM ('created','searching','accepted','rider_arrived','picked_up','ongoing','rider_at_drop','completed','delivered','cancelled','expired','payment_pending');CREATE TYPE "order_type_enum" AS ENUM ('ride','intercity_ride','ride_sharing','local_parcel','intercity_parcel','batch_delivery','food_delivery','grocery_delivery');CREATE TYPE "parcel_type_enum" AS ENUM ('documents','electronics','food','clothes','fragile','others');CREATE TYPE "partner_service_mode_enum" AS ENUM ('local','intercity');CREATE TYPE "payment_for_enum" AS ENUM ('ride_order','parcel_order','wallet_topup','subscription','withdrawal','refund','cod_settlement','ride_boost','intercity_ride_boost','intercity_parcel_boost','intercity_ride_order','intercity_parcel_order','ride_sharing','tax_due');CREATE TYPE "payment_method_enum" AS ENUM ('upi','card','wallet','netbanking','cash','cod','cashfree');CREATE TYPE "payment_mode_enum" AS ENUM ('cash','online','wallet','upi');CREATE TYPE "payment_status_enum" AS ENUM ('pending','paid','failed','refunded','partial_refund','cash_collected','cash_pending_settlement');CREATE TYPE "payout_method_enum" AS ENUM ('bank_account','upi');CREATE TYPE "preferred_mode_enum" AS ENUM ('user','rider');CREATE TYPE "pricing_city_tier_enum" AS ENUM ('tier_1','tier_2');CREATE TYPE "pricing_service_type_enum" AS ENUM ('ride','local_parcel','intercity_parcel','intercity_ride','ride_sharing');CREATE TYPE "review_tag" AS ENUM ('clean_vehicle','polite_behavior','safe_driving','on_time','dirty_vehicle','rude_behavior','unsafe_driving','late_arrival','other','good_behaviour','respectful','easy_to_communicate','clear_instructions','cooperative','ready_at_pickup','late_at_pickup','rude_behaviour','poor_communication','uncooperative','changed_plans','no_show');CREATE TYPE "rider_account_status_enum" AS ENUM ('online','offline','busy','blocked');CREATE TYPE "rider_withdrawal_status_enum" AS ENUM ('pending','processing','success','failed');CREATE TYPE "subscription_status_enum" AS ENUM ('active','expired','cancelled','pending');CREATE TYPE "travel_plan_status_enum" AS ENUM ('active','completed','cancelled','fully_booked','expired');CREATE TYPE "vehicle_type_enum" AS ENUM ('bike','auto','cab');CREATE TYPE "weight_category_enum" AS ENUM ('0_5','6_15','16_25','26_50');CREATE EXTENSION IF NOT EXISTS pgcrypto; CREATE EXTENSION IF NOT EXISTS "uuid-ossp";CREATE TABLE users(id uuid PRIMARY KEY); CREATE TABLE admins(id uuid PRIMARY KEY,email text,is_active boolean); CREATE TABLE payments(id uuid PRIMARY KEY); CREATE TABLE user_devices(id uuid PRIMARY KEY); CREATE TABLE pricing_config(id uuid PRIMARY KEY); CREATE TABLE intercity_requests(parcel_id uuid,traveller_id uuid,status text); CREATE TABLE government_tax_config(threshold_amount numeric,is_active boolean,updated_at timestamptz);CREATE TABLE "dispatch_config" ("id" uuid DEFAULT gen_random_uuid() NOT NULL,"config_code" text NOT NULL,"round_1_radius_km" numeric DEFAULT 3 NOT NULL,"round_1_batch_size" integer DEFAULT 3 NOT NULL,"round_2_radius_km" numeric DEFAULT 6 NOT NULL,"round_2_batch_size" integer DEFAULT 5 NOT NULL,"round_3_radius_km" numeric DEFAULT 10 NOT NULL,"round_3_batch_size" integer DEFAULT 8 NOT NULL,"rider_response_timeout_sec" integer DEFAULT 25 NOT NULL,"max_search_duration_sec" integer DEFAULT 900 NOT NULL,"reject_cooldown_sec" integer DEFAULT 600 NOT NULL,"timeout_cooldown_sec" integer DEFAULT 120 NOT NULL,"rider_location_stale_sec" integer DEFAULT 30 NOT NULL,"max_active_orders_per_rider" integer DEFAULT 1 NOT NULL,"allow_round_3" boolean DEFAULT true,"allow_boosted_priority" boolean DEFAULT true,"is_active" boolean DEFAULT true,"updated_by_admin_id" uuid,"created_at" timestamp with time zone DEFAULT now(),"updated_at" timestamp with time zone DEFAULT now(),"round_2_trigger_if_no_riders_sec" integer DEFAULT 60,"round_2_trigger_after_sec" integer DEFAULT 300,"round_3_trigger_after_sec" integer DEFAULT 600);CREATE TABLE "order_assignment_logs" ("id" uuid DEFAULT gen_random_uuid() NOT NULL,"order_id" uuid NOT NULL,"rider_id" uuid NOT NULL,"assignment_status" intercity_assignment_status_enum DEFAULT 'sent'::intercity_assignment_status_enum NOT NULL,"assignment_round" integer DEFAULT 1,"rider_distance_km" numeric,"estimated_pickup_time_min" integer,"sent_at" timestamp with time zone DEFAULT now(),"viewed_at" timestamp with time zone,"responded_at" timestamp with time zone,"rejection_reason" text,"metadata" jsonb DEFAULT '{}'::jsonb,"created_at" timestamp with time zone DEFAULT now());CREATE TABLE "orders" ("id" uuid DEFAULT gen_random_uuid() NOT NULL,"order_code" text NOT NULL,"user_id" uuid NOT NULL,"rider_id" uuid,"order_type" order_type_enum NOT NULL,"vehicle_type" vehicle_type_enum,"order_status" order_status_enum DEFAULT 'created'::order_status_enum NOT NULL,"pricing_config_id" uuid,"distance_meters" integer NOT NULL,"distance_km" numeric NOT NULL,"estimated_duration_min" integer,"actual_duration_min" integer,"time_taken_seconds" integer,"pickup_address" text NOT NULL,"pickup_lat" double precision NOT NULL,"pickup_lng" double precision NOT NULL,"destination_address" text NOT NULL,"destination_lat" double precision NOT NULL,"destination_lng" double precision NOT NULL,"actual_fare" numeric NOT NULL,"current_fare" numeric NOT NULL,"final_fare" numeric,"base_fare" numeric DEFAULT 0,"distance_fare" numeric DEFAULT 0,"time_fare" numeric DEFAULT 0,"waiting_charge" numeric DEFAULT 0,"platform_fee" numeric DEFAULT 0,"gst_percentage" numeric DEFAULT 0,"gst_amount" numeric DEFAULT 0,"commission_percentage" numeric DEFAULT 0,"commission_amount" numeric DEFAULT 0,"rider_earning" numeric DEFAULT 0,"boost_amount" numeric DEFAULT 0,"subscription_commission_waived" boolean DEFAULT false,"pricing_snapshot" jsonb DEFAULT '{}'::jsonb NOT NULL,"payment_mode" payment_mode_enum NOT NULL,"payment_status" payment_status_enum DEFAULT 'pending'::payment_status_enum NOT NULL,"payment_id" uuid,"pickup_otp" text,"delivery_otp" text,"search_expires_at" timestamp with time zone,"cancelled_by" cancelled_by_enum,"cancel_reason" text,"parcel_type" parcel_type_enum,"receiver_name" text,"receiver_phone" text,"weight_category" text,"actual_weight_kg" numeric,"parcel_images" text[],"special_instructions" text,"created_at" timestamp with time zone DEFAULT now(),"updated_at" timestamp with time zone DEFAULT now(),"accepted_at" timestamp with time zone,"rider_arrived_at" timestamp with time zone,"picked_up_at" timestamp with time zone,"rider_at_drop_at" timestamp with time zone,"completed_at" timestamp with time zone,"cancelled_at" timestamp with time zone,"pickup_otp_attempts" integer DEFAULT 0,"delivery_otp_attempts" integer DEFAULT 0,"boost_company_earning" numeric DEFAULT 0,"boost_rider_earning" numeric DEFAULT 0,"boost_percentage" numeric DEFAULT 0,"dispatch_attempts" integer DEFAULT 0,"boost_round" integer DEFAULT 0,"current_search_radius_km" numeric DEFAULT 3,"last_dispatched_at" timestamp with time zone,"rider_rejections_count" integer DEFAULT 0,"redispatch_count" integer DEFAULT 0,"pickup_city" text,"destination_city" text,"travel_date" timestamp with time zone,"dispatch_state" jsonb DEFAULT '{}'::jsonb,"created_ip_address" inet,"created_lat" double precision,"created_lng" double precision,"sender_declaration_accepted" boolean DEFAULT false,"sender_declaration_accepted_at" timestamp with time zone,"pickup_verification_completed" boolean DEFAULT false,"pickup_verification_completed_at" timestamp with time zone,"compliance_flagged" boolean DEFAULT false,"compliance_notes" text,"created_device_ref" text,"created_device_record_id" uuid,"created_device_model" text,"created_device_brand" text,"created_os_version" text,"created_app_version" text,"compliance_status" text DEFAULT 'pending'::text,"compliance_score" integer DEFAULT 100,"compliance_retention_until" timestamp with time zone,"parcel_declared_value" numeric,"high_risk_parcel" boolean DEFAULT false,"dispatch_worker_running" boolean DEFAULT false,"dispatch_worker_started_at" timestamp with time zone,"seats_requested" integer DEFAULT 1 NOT NULL,"near_destination_notified" boolean DEFAULT false NOT NULL,"trip_started_at" timestamp with time zone,"upi_payment_prompted_at" timestamp with time zone,"fare_payment_method" fare_payment_method_enum,"fare_payment_attempted_at" timestamp with time zone,"fare_paid_at" timestamp with time zone,"fare_payment_reference" text,"fare_payment_screenshot_url" text,"idempotency_key" text,"pg_charge_amount" numeric DEFAULT 0 NOT NULL);CREATE TABLE "rider_assignments" ("id" uuid DEFAULT gen_random_uuid() NOT NULL,"order_id" uuid NOT NULL,"rider_id" uuid NOT NULL,"assignment_round" integer DEFAULT 1 NOT NULL,"assignment_status" intercity_assignment_status_enum DEFAULT 'sent'::intercity_assignment_status_enum NOT NULL,"distance_km" numeric,"estimated_earnings" numeric,"sent_at" timestamp with time zone DEFAULT now() NOT NULL,"viewed_at" timestamp with time zone,"responded_at" timestamp with time zone,"expires_at" timestamp with time zone NOT NULL,"created_at" timestamp with time zone DEFAULT now(),"updated_at" timestamp with time zone DEFAULT now(),"last_seen_at" timestamp with time zone,"last_response_at" timestamp with time zone,"response_type" text,"hidden_until" timestamp with time zone,"last_seen_fare" numeric,"accepted_at" timestamp with time zone,"rejected_at" timestamp with time zone);CREATE TABLE "rider_kyc" ("id" uuid DEFAULT gen_random_uuid() NOT NULL,"user_id" uuid NOT NULL,"full_name" text NOT NULL,"father_name" text NOT NULL,"vehicle_type" vehicle_type_enum NOT NULL,"aadhaar_number" text NOT NULL,"pan_number" text NOT NULL,"driving_license_number" text NOT NULL,"vehicle_number" text NOT NULL,"rider_image" text NOT NULL,"aadhaar_front_image" text NOT NULL,"aadhaar_back_image" text NOT NULL,"pan_front_image" text NOT NULL,"pan_back_image" text NOT NULL,"license_front_image" text NOT NULL,"license_back_image" text NOT NULL,"vehicle_image" text NOT NULL,"kyc_status" kyc_status_enum DEFAULT 'pending'::kyc_status_enum NOT NULL,"activation_status" activation_status_enum DEFAULT 'inactive'::activation_status_enum NOT NULL,"handled_by_admin_id" uuid,"approved_at" timestamp with time zone,"rejected_at" timestamp with time zone,"rejection_reason" text,"activated_at" timestamp with time zone,"created_at" timestamp with time zone DEFAULT now(),"updated_at" timestamp with time zone DEFAULT now(),"rejection_count" integer DEFAULT 0,"blocked_until" timestamp with time zone,"date_of_birth" date NOT NULL,"VECHILE_RC_front_image" text,"VECHILE_RC_back_image" text);CREATE TABLE "rider_locations" ("rider_id" uuid NOT NULL,"current_lat" double precision,"current_lng" double precision,"current_heading" double precision,"last_location_updated_at" timestamp with time zone,"last_active_at" timestamp with time zone,"created_at" timestamp with time zone DEFAULT now(),"updated_at" timestamp with time zone DEFAULT now());CREATE TABLE "riders" ("id" uuid DEFAULT gen_random_uuid() NOT NULL,"kyc_id" uuid NOT NULL,"user_id" uuid NOT NULL,"rating" numeric DEFAULT 5,"total_orders" integer DEFAULT 0,"total_completed_orders" integer DEFAULT 0,"total_cancelled_orders" integer DEFAULT 0,"total_earnings" numeric DEFAULT 0,"today_earnings" numeric DEFAULT 0,"wallet_balance" numeric DEFAULT 0,"cod_pending_amount" numeric DEFAULT 0,"cod_limit" numeric DEFAULT '500'::numeric,"account_status" rider_account_status_enum DEFAULT 'offline'::rider_account_status_enum NOT NULL,"current_lat" double precision,"current_lng" double precision,"current_heading" double precision,"last_location_updated_at" timestamp with time zone,"last_active_at" timestamp with time zone,"subscription_active" boolean DEFAULT false,"subscription_expires_at" timestamp with time zone,"commission_waiver_active" boolean DEFAULT false,"is_verified" boolean DEFAULT true,"created_at" timestamp with time zone DEFAULT now(),"updated_at" timestamp with time zone DEFAULT now(),"last_dormant_notification_sent_at" timestamp with time zone,"last_sub_offline_notification_sent_at" timestamp with time zone,"service_mode" partner_service_mode_enum,"government_tax_due_balance" numeric DEFAULT 0 NOT NULL,"rating_sum" numeric DEFAULT 0 NOT NULL,"total_ratings" integer DEFAULT 0 NOT NULL,"free_trial_started_at" timestamp with time zone,"free_trial_expires_at" timestamp with time zone,"free_trial_used" boolean DEFAULT false NOT NULL);ALTER TABLE "dispatch_config" ADD CONSTRAINT "dispatch_config_config_code_key" UNIQUE (config_code);ALTER TABLE "dispatch_config" ADD CONSTRAINT "dispatch_config_pkey" PRIMARY KEY (id);ALTER TABLE "order_assignment_logs" ADD CONSTRAINT "order_assignment_logs_pkey" PRIMARY KEY (id);ALTER TABLE "order_assignment_logs" ADD CONSTRAINT "unique_order_rider_assignment" UNIQUE (order_id, rider_id, assignment_round);ALTER TABLE "orders" ADD CONSTRAINT "check_intercity_parcel_weight" CHECK (((order_type <> 'intercity_parcel'::order_type_enum) OR ((actual_weight_kg IS NOT NULL) AND (actual_weight_kg > (0)::numeric))));ALTER TABLE "orders" ADD CONSTRAINT "chk_actual_fare" CHECK ((actual_fare >= (0)::numeric));ALTER TABLE "orders" ADD CONSTRAINT "chk_commission_percentage" CHECK (((commission_percentage >= (0)::numeric) AND (commission_percentage <= (100)::numeric)));ALTER TABLE "orders" ADD CONSTRAINT "chk_current_fare" CHECK ((current_fare >= (0)::numeric));ALTER TABLE "orders" ADD CONSTRAINT "chk_distance_km" CHECK ((distance_km >= (0)::numeric));ALTER TABLE "orders" ADD CONSTRAINT "chk_distance_meters" CHECK ((distance_meters >= 0));ALTER TABLE "orders" ADD CONSTRAINT "chk_final_fare" CHECK (((final_fare IS NULL) OR (final_fare >= (0)::numeric)));ALTER TABLE "orders" ADD CONSTRAINT "chk_gst_percentage" CHECK (((gst_percentage >= (0)::numeric) AND (gst_percentage <= (100)::numeric)));ALTER TABLE "orders" ADD CONSTRAINT "orders_compliance_status_check" CHECK ((compliance_status = ANY (ARRAY['pending'::text, 'verified'::text, 'flagged'::text, 'investigating'::text])));ALTER TABLE "orders" ADD CONSTRAINT "orders_order_code_key" UNIQUE (order_code);ALTER TABLE "orders" ADD CONSTRAINT "orders_pkey" PRIMARY KEY (id);ALTER TABLE "rider_assignments" ADD CONSTRAINT "rider_assignments_order_id_rider_id_key" UNIQUE (order_id, rider_id);ALTER TABLE "rider_assignments" ADD CONSTRAINT "rider_assignments_pkey" PRIMARY KEY (id);ALTER TABLE "rider_kyc" ADD CONSTRAINT "aadhaar_length_check" CHECK ((length(aadhaar_number) = 12));ALTER TABLE "rider_kyc" ADD CONSTRAINT "pan_format_check" CHECK ((pan_number ~ '^[A-Z]{5}[0-9]{4}[A-Z]{1}$'::text));ALTER TABLE "rider_kyc" ADD CONSTRAINT "rider_kyc_pkey" PRIMARY KEY (id);ALTER TABLE "rider_kyc" ADD CONSTRAINT "rider_minimum_age_check" CHECK ((date_of_birth <= (CURRENT_DATE - '18 years'::interval)));ALTER TABLE "rider_locations" ADD CONSTRAINT "rider_locations_pkey" PRIMARY KEY (rider_id);ALTER TABLE "riders" ADD CONSTRAINT "riders_kyc_id_key" UNIQUE (kyc_id);ALTER TABLE "riders" ADD CONSTRAINT "riders_pkey" PRIMARY KEY (id);ALTER TABLE "riders" ADD CONSTRAINT "riders_user_id_key" UNIQUE (user_id);ALTER TABLE "dispatch_config" ADD CONSTRAINT "dispatch_config_updated_by_admin_id_fkey" FOREIGN KEY (updated_by_admin_id) REFERENCES admins(id) ON DELETE SET NULL;ALTER TABLE "order_assignment_logs" ADD CONSTRAINT "order_assignment_logs_order_id_fkey" FOREIGN KEY (order_id) REFERENCES orders(id) ON DELETE CASCADE;ALTER TABLE "order_assignment_logs" ADD CONSTRAINT "order_assignment_logs_rider_id_fkey" FOREIGN KEY (rider_id) REFERENCES riders(id) ON DELETE CASCADE;ALTER TABLE "orders" ADD CONSTRAINT "orders_created_device_record_id_fkey" FOREIGN KEY (created_device_record_id) REFERENCES user_devices(id) ON DELETE SET NULL;ALTER TABLE "orders" ADD CONSTRAINT "orders_payment_id_fkey" FOREIGN KEY (payment_id) REFERENCES payments(id) ON DELETE SET NULL;ALTER TABLE "orders" ADD CONSTRAINT "orders_pricing_config_id_fkey" FOREIGN KEY (pricing_config_id) REFERENCES pricing_config(id) ON DELETE SET NULL;ALTER TABLE "orders" ADD CONSTRAINT "orders_rider_id_fkey" FOREIGN KEY (rider_id) REFERENCES riders(id) ON DELETE SET NULL;ALTER TABLE "orders" ADD CONSTRAINT "orders_user_id_fkey" FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE RESTRICT;ALTER TABLE "rider_assignments" ADD CONSTRAINT "rider_assignments_order_id_fkey" FOREIGN KEY (order_id) REFERENCES orders(id) ON DELETE CASCADE;ALTER TABLE "rider_assignments" ADD CONSTRAINT "rider_assignments_rider_id_fkey" FOREIGN KEY (rider_id) REFERENCES riders(id) ON DELETE CASCADE;ALTER TABLE "rider_kyc" ADD CONSTRAINT "rider_kyc_handled_by_admin_id_fkey" FOREIGN KEY (handled_by_admin_id) REFERENCES admins(id);ALTER TABLE "rider_kyc" ADD CONSTRAINT "rider_kyc_user_id_fkey" FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE;ALTER TABLE "rider_locations" ADD CONSTRAINT "rider_locations_rider_id_fkey" FOREIGN KEY (rider_id) REFERENCES riders(id) ON DELETE CASCADE;ALTER TABLE "riders" ADD CONSTRAINT "riders_kyc_id_fkey" FOREIGN KEY (kyc_id) REFERENCES rider_kyc(id) ON DELETE CASCADE;ALTER TABLE "riders" ADD CONSTRAINT "riders_user_id_fkey" FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE;CREATE TABLE local_push_capture(id bigserial PRIMARY KEY,user_id uuid,title text,body text,data jsonb); CREATE FUNCTION send_push_notification_fnc(uuid,text,text,jsonb) RETURNS void LANGUAGE sql AS $$ INSERT INTO local_push_capture(user_id,title,body,data) VALUES($1,$2,$3,$4) $$;CREATE OR REPLACE FUNCTION public.assign_nearby_searching_orders_to_rider()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
    IF NEW.current_lat IS NULL OR NEW.current_lng IS NULL THEN
        RETURN NEW;
    END IF;

    PERFORM public.assign_nearby_searching_orders_core(
        NEW.id,
        NEW.user_id,
        NEW.current_lat,
        NEW.current_lng,
        NEW.service_mode
    );

    RETURN NEW;
END;
$function$
;CREATE OR REPLACE FUNCTION public.check_rider_near_destination_from_rider_locations()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_order RECORD;
    v_dist_km double precision;
BEGIN
    IF NEW.current_lat IS NULL OR NEW.current_lng IS NULL THEN
        RETURN NEW;
    END IF;

    SELECT id, user_id, destination_lat, destination_lng
    INTO v_order
    FROM public.orders
    WHERE rider_id = NEW.rider_id
      AND order_status = 'ongoing'
      AND near_destination_notified = false
      AND order_type::text LIKE 'intercity%'
      AND destination_lat IS NOT NULL
      AND destination_lng IS NOT NULL
    LIMIT 1;

    IF v_order.id IS NULL THEN
        RETURN NEW;
    END IF;

    v_dist_km := 6371 * acos(
        LEAST(GREATEST(
            cos(radians(v_order.destination_lat))
            * cos(radians(NEW.current_lat))
            * cos(radians(NEW.current_lng) - radians(v_order.destination_lng))
            + sin(radians(v_order.destination_lat))
            * sin(radians(NEW.current_lat))
        , -1.0), 1.0)
    );

    IF v_dist_km <= 3.0 THEN
        UPDATE public.orders
        SET near_destination_notified = true
        WHERE id = v_order.id;

        PERFORM public.send_push_notification_fnc(
            v_order.user_id,
            'Almost There',
            'You are about 10 minutes away from your destination.',
            jsonb_build_object('type', 'trip_near_destination', 'order_id', v_order.id)
        );
    END IF;

    RETURN NEW;
END;
$function$
;CREATE OR REPLACE FUNCTION public.enforce_rider_assignment_service_mode()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_order_type text;
    v_distance_meters integer;
    v_required_mode public.partner_service_mode_enum;
    v_rider_mode public.partner_service_mode_enum;
BEGIN
    SELECT o.order_type::text, o.distance_meters
    INTO v_order_type, v_distance_meters
    FROM public.orders o
    WHERE o.id = NEW.order_id;

    SELECT r.service_mode INTO v_rider_mode
    FROM public.riders r
    WHERE r.id = NEW.rider_id;

    v_required_mode := public.get_required_service_mode(v_order_type, v_distance_meters);

    IF v_rider_mode IS NULL THEN
        RAISE EXCEPTION 'Rider % has not selected a Service Mode yet and cannot be assigned any orders', NEW.rider_id
            USING ERRCODE = 'check_violation';
    END IF;

    IF v_rider_mode != v_required_mode THEN
        RAISE EXCEPTION 'Rider % service_mode (%) does not match the service mode required (%) for order %', NEW.rider_id, v_rider_mode, v_required_mode, NEW.order_id
            USING ERRCODE = 'check_violation';
    END IF;

    RETURN NEW;
END;
$function$
;CREATE OR REPLACE FUNCTION public.get_active_tax_due_threshold()
 RETURNS numeric
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
    SELECT COALESCE(
        (SELECT threshold_amount FROM public.government_tax_config WHERE is_active = true ORDER BY updated_at DESC LIMIT 1),
        100.0
    );
$function$
;CREATE OR REPLACE FUNCTION public.get_required_service_mode(p_order_type text, p_distance_meters integer)
 RETURNS partner_service_mode_enum
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
    SELECT CASE
        WHEN p_order_type IN ('intercity_ride', 'intercity_parcel') THEN 'intercity'::public.partner_service_mode_enum
        WHEN p_order_type = 'ride' AND COALESCE(p_distance_meters, 0) > 20000 THEN 'intercity'::public.partner_service_mode_enum
        ELSE 'local'::public.partner_service_mode_enum
    END;
$function$
;CREATE OR REPLACE FUNCTION public.is_rider_blocked_by_cod_limit(p_rider_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
    SELECT COALESCE(
        (SELECT cod_pending_amount FROM public.riders WHERE id = p_rider_id),
        0
    ) >= COALESCE(
        (SELECT cod_limit FROM public.riders WHERE id = p_rider_id),
        500
    );
$function$
;CREATE OR REPLACE FUNCTION public.is_rider_blocked_by_tax_due(p_rider_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
    SELECT COALESCE(
        (SELECT government_tax_due_balance FROM public.riders WHERE id = p_rider_id),
        0
    ) >= public.get_active_tax_due_threshold();
$function$
;CREATE OR REPLACE FUNCTION public.rider_is_on_active_trip(p_rider_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
    SELECT EXISTS (
        SELECT 1
        FROM public.orders o
        WHERE o.rider_id = p_rider_id
          AND (
                o.order_status::text IN ('rider_arrived', 'picked_up', 'rider_at_drop', 'ongoing', 'payment_pending')
                OR (
                    o.order_status::text = 'accepted'
                    AND (
                        public.get_required_service_mode(o.order_type::text, o.distance_meters) = 'local'
                        OR o.trip_started_at IS NOT NULL
                    )
                )
              )
    );
$function$
;CREATE OR REPLACE FUNCTION public.sync_riders_gps_to_rider_locations()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
    INSERT INTO public.rider_locations AS rl
        (rider_id, current_lat, current_lng, current_heading,
         last_location_updated_at, last_active_at, updated_at)
    VALUES
        (NEW.id, NEW.current_lat, NEW.current_lng, NEW.current_heading,
         NEW.last_location_updated_at, NEW.last_active_at, now())
    ON CONFLICT (rider_id) DO UPDATE SET
        current_lat              = EXCLUDED.current_lat,
        current_lng              = EXCLUDED.current_lng,
        current_heading          = EXCLUDED.current_heading,
        last_location_updated_at = EXCLUDED.last_location_updated_at,
        last_active_at           = EXCLUDED.last_active_at,
        updated_at               = now();

    RETURN NULL;  -- AFTER trigger; return value is ignored
END;
$function$
;CREATE OR REPLACE FUNCTION public.is_admin()
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  SELECT EXISTS (
    SELECT 1 FROM public.admins
    WHERE email = auth.email() AND is_active = true
  );
$function$
;CREATE OR REPLACE FUNCTION public.prevent_local_ride_assignment_to_busy_rider()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_new_order_type text;
    v_new_distance integer;
BEGIN
    IF NEW.assignment_status IS DISTINCT FROM 'sent' THEN
        RETURN NEW;
    END IF;

    SELECT o.order_type::text, o.distance_meters
    INTO v_new_order_type, v_new_distance
    FROM public.orders o
    WHERE o.id = NEW.order_id;

    -- Only local rides are in scope for this guard.
    IF v_new_order_type IS DISTINCT FROM 'ride' OR COALESCE(v_new_distance, 0) > 20000 THEN
        RETURN NEW;
    END IF;

    IF EXISTS (
        SELECT 1
        FROM public.orders bo
        WHERE bo.rider_id = NEW.rider_id
          AND bo.id != NEW.order_id
          AND bo.order_type = 'ride'
          AND COALESCE(bo.distance_meters, 0) <= 20000
          AND bo.order_status IN ('accepted', 'rider_arrived', 'picked_up', 'ongoing', 'payment_pending')
    ) THEN
        RETURN NULL;
    END IF;

    RETURN NEW;
END;
$function$
;CREATE OR REPLACE FUNCTION public.on_rider_assignment_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_rider_user_id uuid := NULL;
    v_order_type text := NULL;
    v_notification_type text := 'order_assignment';
BEGIN
    -- Notify when status is set or updated to 'sent'
    IF NEW.assignment_status = 'sent' AND (TG_OP = 'INSERT' OR OLD.assignment_status IS DISTINCT FROM 'sent') THEN
        SELECT user_id INTO v_rider_user_id FROM public.riders WHERE id = NEW.rider_id;

        IF v_rider_user_id IS NOT NULL THEN
            SELECT order_type::text INTO v_order_type FROM public.orders WHERE id = NEW.order_id;

            IF v_order_type IN ('intercity_ride', 'intercity_parcel') THEN
                v_notification_type := 'intercity_order_assignment';
            END IF;

            PERFORM public.send_push_notification_fnc(
                v_rider_user_id,
                'New Order Request',
                'You have a new order request nearby!',
                jsonb_build_object(
                    'type', v_notification_type,
                    'order_id', NEW.order_id,
                    'assignment_id', NEW.id
                )
            );
        END IF;
    END IF;

    RETURN NEW;
END;
$function$
;CREATE OR REPLACE FUNCTION public.prevent_service_mode_switch_during_active_order()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
    IF NEW.service_mode IS NOT DISTINCT FROM OLD.service_mode THEN
        RETURN NEW;
    END IF;

    IF public.rider_is_on_active_trip(NEW.id) THEN
        RAISE EXCEPTION 'Cannot switch Service Mode while a trip is active. Complete or cancel your current trip first.'
            USING ERRCODE = 'check_violation';
    END IF;

    RETURN NEW;
END;
$function$
;CREATE OR REPLACE FUNCTION public.protect_rider_financial_columns()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
    IF auth.role() <> 'service_role'
       AND current_setting('app.bypass_rider_financial_guard', true) IS DISTINCT FROM 'true'
    THEN
        IF NEW.wallet_balance IS DISTINCT FROM OLD.wallet_balance
           OR NEW.cod_pending_amount IS DISTINCT FROM OLD.cod_pending_amount
           OR NEW.cod_limit IS DISTINCT FROM OLD.cod_limit
           OR NEW.subscription_active IS DISTINCT FROM OLD.subscription_active
           OR NEW.subscription_expires_at IS DISTINCT FROM OLD.subscription_expires_at
           OR NEW.commission_waiver_active IS DISTINCT FROM OLD.commission_waiver_active
           OR NEW.government_tax_due_balance IS DISTINCT FROM OLD.government_tax_due_balance
           OR NEW.is_verified IS DISTINCT FROM OLD.is_verified
           OR NEW.free_trial_started_at IS DISTINCT FROM OLD.free_trial_started_at
           OR NEW.free_trial_expires_at IS DISTINCT FROM OLD.free_trial_expires_at
           OR NEW.free_trial_used IS DISTINCT FROM OLD.free_trial_used
        THEN
            RAISE EXCEPTION 'Direct modification of rider financial/subscription columns is not permitted. Use the appropriate server-side function.';
        END IF;
    END IF;
    RETURN NEW;
END;
$function$
;CREATE OR REPLACE FUNCTION public.check_is_order_candidate_rider(p_order_id uuid, p_user_id uuid)
 RETURNS boolean
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
    SELECT EXISTS (
        SELECT 1 FROM public.rider_assignments ra
        INNER JOIN public.riders r ON r.id = ra.rider_id
        WHERE ra.order_id = p_order_id AND r.user_id = p_user_id
    );
$function$
;CREATE OR REPLACE FUNCTION public.check_is_order_passenger(p_order_id uuid, p_user_id uuid)
 RETURNS boolean
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
    SELECT EXISTS (
        SELECT 1 FROM public.orders
        WHERE id = p_order_id AND user_id = p_user_id
    );
$function$
;CREATE OR REPLACE FUNCTION public.check_is_order_passenger_for_intercity(p_order_id uuid, p_user_id uuid)
 RETURNS boolean
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
    SELECT EXISTS (
        SELECT 1 FROM public.orders
        WHERE id = p_order_id
          AND user_id = p_user_id
          AND order_type IN ('intercity_ride', 'intercity_parcel')
    );
$function$
;CREATE OR REPLACE FUNCTION public.can_read_rider_location(p_rider_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
    SELECT
        -- (A) the rider themselves
        EXISTS (
            SELECT 1 FROM public.riders r
            WHERE r.id = p_rider_id
              AND r.user_id = (SELECT auth.uid())
        )
        OR
        -- (B) a passenger with an ACTIVE order assigned to this rider
        EXISTS (
            SELECT 1 FROM public.orders o
            WHERE o.rider_id = p_rider_id
              AND o.user_id  = (SELECT auth.uid())
              AND o.order_status IN (
                    'accepted', 'rider_arrived', 'picked_up',
                    'rider_at_drop', 'ongoing', 'payment_pending'
                  )
        );
$function$
;CREATE OR REPLACE FUNCTION public.find_nearby_riders(p_order_id uuid, p_pickup_lat double precision, p_pickup_lng double precision, p_radius_km double precision, p_limit integer, p_excluded_rider_ids uuid[] DEFAULT '{}'::uuid[])
 RETURNS TABLE(rider_id uuid, user_id uuid, full_name text, vehicle_type text, vehicle_number text, current_lat double precision, current_lng double precision, distance_km numeric)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_order_type text;
    v_vehicle_type text;
    v_stale_sec integer;
    v_creator_user_id uuid;
    v_weight_kg double precision;
    v_distance_meters integer;
    v_required_mode public.partner_service_mode_enum;
    v_tax_due_threshold numeric;
BEGIN
    SELECT
        o.order_type,
        o.vehicle_type,
        o.user_id,
        COALESCE(
            o.actual_weight_kg,
            COALESCE(NULLIF(regexp_replace(o.weight_category::text, '[^0-9.]', '', 'g'), ''), '0')::double precision
        )::double precision,
        o.distance_meters
    INTO
        v_order_type,
        v_vehicle_type,
        v_creator_user_id,
        v_weight_kg,
        v_distance_meters
    FROM orders o
    WHERE o.id = p_order_id;

    IF auth.uid() IS NOT NULL AND (v_creator_user_id IS NULL OR auth.uid() != v_creator_user_id) THEN
        RETURN;
    END IF;

    v_required_mode := public.get_required_service_mode(v_order_type, v_distance_meters);

    SELECT COALESCE(rider_location_stale_sec, 60)
    INTO v_stale_sec
    FROM dispatch_config
    WHERE is_active = true
    LIMIT 1;

    SELECT public.get_active_tax_due_threshold()
    INTO v_tax_due_threshold;

    RETURN QUERY
    WITH candidates AS (
        SELECT
            r.id AS rider_id,
            r.user_id,
            rk.full_name,
            rk.vehicle_type::text AS vehicle_type,
            rk.vehicle_number,
            r.current_lat,
            r.current_lng,
            (
                6371 * acos(
                    LEAST(GREATEST(
                        cos(radians(p_pickup_lat))
                        * cos(radians(r.current_lat))
                        * cos(
                            radians(r.current_lng)
                            - radians(p_pickup_lng)
                        )
                        + sin(radians(p_pickup_lat))
                        * sin(radians(r.current_lat))
                    , -1.0), 1.0)
                )
            ) AS raw_distance_km
        FROM riders r
        INNER JOIN rider_kyc rk
            ON rk.user_id = r.user_id
        WHERE
            r.account_status = 'online'
            AND r.service_mode = v_required_mode
            AND r.current_lat IS NOT NULL
            AND r.current_lng IS NOT NULL
            AND r.user_id != v_creator_user_id
            AND NOT (r.id = ANY(p_excluded_rider_ids))
            AND r.government_tax_due_balance < v_tax_due_threshold
            AND COALESCE(r.cod_pending_amount, 0) < COALESCE(r.cod_limit, 500)
            AND (rk.kyc_status::text IN ('approved', 'pending', 'under_review', 'resubmitted') OR rk.kyc_status IS NULL)
            AND (rk.activation_status::text IN ('active', 'pending', 'inactive') OR rk.activation_status IS NULL)
            AND (
                r.last_location_updated_at >= (NOW() - (v_stale_sec || ' seconds')::interval)
                OR
                r.last_location_updated_at >= (NOW() - INTERVAL '24 hours')
                OR
                r.last_location_updated_at IS NULL
            )
            AND (
                ((v_order_type = 'ride' OR v_order_type = 'intercity_ride' OR v_order_type = 'intercity') AND
                 rk.vehicle_type::text = v_vehicle_type)
                OR
                (v_order_type = 'ride_sharing' AND rk.vehicle_type::text IN ('auto', 'cab'))
                OR
                (
                    (v_order_type = 'local_parcel' OR v_order_type LIKE '%parcel%' OR v_order_type LIKE '%delivery%')
                    AND v_order_type != 'intercity_parcel'
                    AND
                    (
                        (v_weight_kg < 10.0 AND rk.vehicle_type::text = 'bike')
                        OR
                        (v_weight_kg >= 10.0 AND rk.vehicle_type::text = 'auto')
                    )
                )
                OR
                (
                    v_order_type = 'intercity_parcel'
                    AND
                    (
                        (v_weight_kg < 10.0 AND rk.vehicle_type::text = 'bike')
                        OR
                        (v_weight_kg >= 10.0 AND rk.vehicle_type::text IN ('auto', 'cab'))
                    )
                )
                OR
                (v_order_type NOT IN ('ride', 'intercity_ride', 'intercity', 'ride_sharing', 'local_parcel', 'intercity_parcel') AND v_order_type NOT LIKE '%parcel%' AND v_order_type NOT LIKE '%delivery%')
            )
            AND NOT public.rider_is_on_active_trip(r.id)
    )
    SELECT
        candidates.rider_id,
        candidates.user_id,
        candidates.full_name,
        candidates.vehicle_type,
        candidates.vehicle_number,
        candidates.current_lat,
        candidates.current_lng,
        ROUND(candidates.raw_distance_km::numeric, 2) AS distance_km
    FROM candidates
    WHERE candidates.raw_distance_km <= p_radius_km
    ORDER BY distance_km ASC
    LIMIT p_limit;
END;
$function$
;
CREATE OR REPLACE FUNCTION public.assign_nearby_searching_orders_core(p_rider_id uuid, p_rider_user_id uuid, p_current_lat double precision, p_current_lng double precision, p_service_mode partner_service_mode_enum)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_order RECORD;
    v_radius_km double precision;
    v_stale_sec integer;
    v_dist_km double precision;
    v_timeout_sec integer;
    v_max_search_duration_sec integer;
    v_existing_id uuid;
    v_existing_status text;
    v_rider_vehicle text;
BEGIN
    IF p_current_lat IS NULL OR p_current_lng IS NULL THEN
        RETURN;
    END IF;

    -- GOVERNMENT TAX DUE: a blocked rider receives no new assignments through this path either.
    IF public.is_rider_blocked_by_tax_due(p_rider_id) THEN
        RETURN;
    END IF;

    -- COD LIMIT: a rider whose cash-on-delivery pending amount has reached their configured limit
    -- receives no new assignments through this path either, until they settle.
    IF public.is_rider_blocked_by_cod_limit(p_rider_id) THEN
        RETURN;
    END IF;

    SELECT
        COALESCE(round_2_radius_km, 5.0),
        COALESCE(rider_location_stale_sec, 60),
        COALESCE(rider_response_timeout_sec, 120),
        COALESCE(max_search_duration_sec, 900)
    INTO
        v_radius_km,
        v_stale_sec,
        v_timeout_sec,
        v_max_search_duration_sec
    FROM public.dispatch_config
    WHERE is_active = true
    LIMIT 1;

    v_radius_km := COALESCE(v_radius_km, 5.0);
    v_stale_sec := COALESCE(v_stale_sec, 60);
    v_timeout_sec := COALESCE(v_timeout_sec, 120);
    v_max_search_duration_sec := COALESCE(v_max_search_duration_sec, 900);

    SELECT COALESCE(rk.vehicle_type::text, '') INTO v_rider_vehicle
    FROM public.rider_kyc rk
    WHERE rk.user_id = p_rider_user_id
    LIMIT 1;

    FOR v_order IN (
        SELECT
            o.id,
            o.pickup_lat,
            o.pickup_lng,
            o.vehicle_type::text AS vehicle_type,
            o.order_type::text AS order_type,
            o.rider_earning,
            o.distance_meters,
            COALESCE(
                o.actual_weight_kg,
                COALESCE(NULLIF(regexp_replace(o.weight_category::text, '[^0-9.]', '', 'g'), ''), '0')::double precision
            )::double precision AS weight_kg
        FROM public.orders o
        WHERE o.order_status = 'searching'
          AND o.user_id != p_rider_user_id
          -- STALENESS GUARD: never a candidate for (re-)offering once the order has been searching
          -- longer than the platform's configured search lifetime.
          AND o.created_at >= (NOW() - (v_max_search_duration_sec || ' seconds')::interval)
    ) LOOP
        v_dist_km := 6371 * acos(
            LEAST(GREATEST(
                cos(radians(v_order.pickup_lat))
                * cos(radians(p_current_lat))
                * cos(
                    radians(p_current_lng)
                    - radians(v_order.pickup_lng)
                )
                + sin(radians(v_order.pickup_lat))
                * sin(radians(p_current_lat))
            , -1.0), 1.0)
        );

        IF v_dist_km <= v_radius_km
           AND public.get_required_service_mode(v_order.order_type, v_order.distance_meters) = p_service_mode
           AND (
            ((v_order.order_type = 'ride' OR v_order.order_type = 'intercity_ride' OR v_order.order_type = 'intercity') AND
             v_rider_vehicle = v_order.vehicle_type)
            OR
            (v_order.order_type = 'ride_sharing' AND v_rider_vehicle IN ('auto', 'cab'))
            OR
            (
                (v_order.order_type = 'local_parcel' OR v_order.order_type LIKE '%parcel%' OR v_order.order_type LIKE '%delivery%')
                AND v_order.order_type != 'intercity_parcel'
                AND
                (
                    (v_order.weight_kg < 10.0 AND v_rider_vehicle = 'bike')
                    OR
                    (v_order.weight_kg >= 10.0 AND v_rider_vehicle = 'auto')
                )
            )
            OR
            (
                v_order.order_type = 'intercity_parcel'
                AND
                (
                    (v_order.weight_kg < 10.0 AND v_rider_vehicle = 'bike')
                    OR
                    (v_order.weight_kg >= 10.0 AND v_rider_vehicle IN ('auto', 'cab'))
                )
            )
            OR
            (v_order.order_type NOT IN ('ride', 'intercity_ride', 'intercity', 'ride_sharing', 'local_parcel', 'intercity_parcel') AND v_order.order_type NOT LIKE '%parcel%' AND v_order.order_type NOT LIKE '%delivery%')
        ) THEN
            v_existing_id := NULL;
            v_existing_status := NULL;

            SELECT id, assignment_status INTO v_existing_id, v_existing_status
            FROM public.rider_assignments
            WHERE order_id = v_order.id
              AND rider_id = p_rider_id
            LIMIT 1;

            BEGIN
                IF v_existing_id IS NULL THEN
                    INSERT INTO public.rider_assignments (
                        order_id,
                        rider_id,
                        assignment_round,
                        assignment_status,
                        distance_km,
                        estimated_earnings,
                        sent_at,
                        expires_at,
                        last_seen_at,
                        last_seen_fare
                    ) VALUES (
                        v_order.id,
                        p_rider_id,
                        1,
                        'sent',
                        v_dist_km,
                        v_order.rider_earning,
                        NOW(),
                        NOW() + (v_timeout_sec || ' seconds')::interval,
                        NOW(),
                        v_order.rider_earning
                    );

                    -- FIX: audit-log write isolated into its own sub-transaction -- a duplicate
                    -- (order_id, rider_id, assignment_round) row here (assignment_round is always 1
                    -- for this dispatch path) must never undo the rider_assignments INSERT above,
                    -- which is the actual source of truth for what the rider sees.
                    BEGIN
                        INSERT INTO public.order_assignment_logs (
                            order_id,
                            rider_id,
                            assignment_round,
                            assignment_status,
                            rider_distance_km,
                            estimated_pickup_time_min,
                            sent_at
                        ) VALUES (
                            v_order.id,
                            p_rider_id,
                            1,
                            'sent',
                            v_dist_km,
                            -- Reproduced verbatim from the live production definition (confirmed via
                            -- a read-only pg_dump audit against the linked project): the fresh-
                            -- insert branch has always written v_order.rider_earning into this
                            -- column here, not CEIL(v_dist_km * 3) like the two re-offer branches
                            -- below. Almost certainly a pre-existing, unrelated copy/paste quirk in
                            -- an inert, write-only audit-log column (order_assignment_logs.
                            -- estimated_pickup_time_min is never selected/read anywhere in the
                            -- Flutter client -- rider_orders_screen.dart only ever selects this
                            -- column from rider_assignments, which doesn't have it, and always
                            -- falls back to its own (distKm * 3).ceil() computation instead) -- but
                            -- correcting it is out of scope for this fix, so it is left exactly as
                            -- production already has it rather than silently changing it here.
                            v_order.rider_earning,
                            NOW()
                        );
                    EXCEPTION WHEN OTHERS THEN
                        NULL;
                    END;
                ELSIF v_existing_status = 'expired' THEN
                    IF EXISTS (
                        SELECT 1 FROM public.rider_assignments
                        WHERE id = v_existing_id
                          AND v_order.rider_earning > COALESCE(last_seen_fare, estimated_earnings, 0)
                    ) THEN
                        UPDATE public.rider_assignments
                        SET
                            assignment_status = 'sent',
                            distance_km = v_dist_km,
                            sent_at = NOW(),
                            expires_at = NOW() + (v_timeout_sec || ' seconds')::interval,
                            updated_at = NOW(),
                            responded_at = NULL,
                            response_type = NULL,
                            hidden_until = NULL,
                            last_seen_at = NOW(),
                            last_seen_fare = v_order.rider_earning
                        WHERE id = v_existing_id;

                        -- FIX: see above -- isolated so a duplicate-round audit row can never roll
                        -- back the UPDATE that just re-sent this assignment to the rider.
                        BEGIN
                            INSERT INTO public.order_assignment_logs (
                                order_id,
                                rider_id,
                                assignment_round,
                                assignment_status,
                                rider_distance_km,
                                estimated_pickup_time_min,
                                sent_at
                            ) VALUES (
                                v_order.id,
                                p_rider_id,
                                1,
                                'sent',
                                v_dist_km,
                                CEIL(v_dist_km * 3),
                                NOW()
                            );
                        EXCEPTION WHEN OTHERS THEN
                            NULL;
                        END;
                    END IF;
                ELSIF v_existing_status = 'rejected' THEN
                    IF EXISTS (
                        SELECT 1 FROM public.rider_assignments
                        WHERE id = v_existing_id
                          AND NOW() >= COALESCE(hidden_until, NOW())
                          AND v_order.rider_earning > COALESCE(last_seen_fare, estimated_earnings, 0)
                    ) THEN
                        UPDATE public.rider_assignments
                        SET
                            assignment_status = 'sent',
                            distance_km = v_dist_km,
                            sent_at = NOW(),
                            expires_at = NOW() + (v_timeout_sec || ' seconds')::interval,
                            updated_at = NOW(),
                            responded_at = NULL,
                            response_type = NULL,
                            hidden_until = NULL,
                            last_seen_at = NOW(),
                            last_seen_fare = v_order.rider_earning
                        WHERE id = v_existing_id;

                        -- FIX: see above -- isolated so a duplicate-round audit row can never roll
                        -- back the UPDATE that just re-sent this assignment to the rider.
                        BEGIN
                            INSERT INTO public.order_assignment_logs (
                                order_id,
                                rider_id,
                                assignment_round,
                                assignment_status,
                                rider_distance_km,
                                estimated_pickup_time_min,
                                sent_at
                            ) VALUES (
                                v_order.id,
                                p_rider_id,
                                1,
                                'sent',
                                v_dist_km,
                                CEIL(v_dist_km * 3),
                                NOW()
                            );
                        EXCEPTION WHEN OTHERS THEN
                            NULL;
                        END;
                    END IF;
                END IF;
            EXCEPTION WHEN unique_violation THEN
                -- Retained: still catches a genuine concurrent-INSERT race on rider_assignments'
                -- own (order_id, rider_id) unique key (two rematch mechanisms firing at once for a
                -- pair that has never been offered before). The order_assignment_logs unique key can
                -- no longer reach this handler at all -- it is caught by its own inner block above.
                NULL;
            END;
        END IF;
    END LOOP;
END;
$function$
;
REVOKE ALL ON FUNCTION assign_nearby_searching_orders_core(uuid,uuid,float8,float8,partner_service_mode_enum) FROM PUBLIC; GRANT EXECUTE ON FUNCTION assign_nearby_searching_orders_core(uuid,uuid,float8,float8,partner_service_mode_enum) TO service_role;CREATE TRIGGER trigger_enforce_rider_assignment_service_mode BEFORE INSERT ON public.rider_assignments FOR EACH ROW EXECUTE FUNCTION enforce_rider_assignment_service_mode();CREATE TRIGGER trigger_prevent_local_ride_assignment_to_busy_rider BEFORE INSERT OR UPDATE ON public.rider_assignments FOR EACH ROW EXECUTE FUNCTION prevent_local_ride_assignment_to_busy_rider();CREATE TRIGGER trigger_rider_assignment_change AFTER INSERT OR UPDATE OF assignment_status ON public.rider_assignments FOR EACH ROW EXECUTE FUNCTION on_rider_assignment_change();CREATE TRIGGER trg_rider_locations_near_destination_check AFTER UPDATE OF current_lat, current_lng ON public.rider_locations FOR EACH ROW EXECUTE FUNCTION check_rider_near_destination_from_rider_locations();CREATE TRIGGER protect_rider_financial_columns_trigger BEFORE UPDATE ON public.riders FOR EACH ROW EXECUTE FUNCTION protect_rider_financial_columns();CREATE TRIGGER trg_riders_gps_bridge_to_rider_locations AFTER UPDATE OF current_lat, current_lng ON public.riders FOR EACH ROW WHEN (((old.current_lat IS DISTINCT FROM new.current_lat) OR (old.current_lng IS DISTINCT FROM new.current_lng) OR (old.current_heading IS DISTINCT FROM new.current_heading) OR (old.last_location_updated_at IS DISTINCT FROM new.last_location_updated_at) OR (old.last_active_at IS DISTINCT FROM new.last_active_at))) EXECUTE FUNCTION sync_riders_gps_to_rider_locations();CREATE TRIGGER trigger_assign_nearby_orders AFTER UPDATE OF account_status ON public.riders FOR EACH ROW WHEN (((new.account_status = 'online'::rider_account_status_enum) AND (old.account_status IS DISTINCT FROM 'online'::rider_account_status_enum))) EXECUTE FUNCTION assign_nearby_searching_orders_to_rider();CREATE TRIGGER trigger_prevent_service_mode_switch_during_active_order BEFORE UPDATE OF service_mode ON public.riders FOR EACH ROW EXECUTE FUNCTION prevent_service_mode_switch_during_active_order();ALTER TABLE riders ENABLE ROW LEVEL SECURITY;ALTER TABLE rider_assignments ENABLE ROW LEVEL SECURITY;ALTER TABLE rider_locations ENABLE ROW LEVEL SECURITY;ALTER TABLE orders ENABLE ROW LEVEL SECURITY;CREATE POLICY "Allow passengers and assigned riders to update orders" ON "orders" AS PERMISSIVE FOR UPDATE TO "authenticated" USING (((( SELECT auth.uid() AS uid) = user_id) OR (EXISTS ( SELECT 1
   FROM riders r
  WHERE ((r.id = orders.rider_id) AND (r.user_id = ( SELECT auth.uid() AS uid)))))));CREATE POLICY "Allow travellers to browse searching intercity orders" ON "orders" AS PERMISSIVE FOR SELECT TO "authenticated" USING (((order_status = 'searching'::order_status_enum) AND ((order_type)::text ~~ 'intercity%'::text)));CREATE POLICY "Allow travellers to view orders tied to active intercity reques" ON "orders" AS PERMISSIVE FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM (intercity_requests ir
     JOIN riders r ON ((r.id = ir.traveller_id)))
  WHERE ((ir.parcel_id = orders.id) AND (r.user_id = ( SELECT auth.uid() AS uid)) AND (ir.status <> ALL (ARRAY['cancelled'::text, 'rejected'::text, 'expired'::text]))))));CREATE POLICY "Allow users to view their own or assigned orders" ON "orders" AS PERMISSIVE FOR SELECT TO "authenticated" USING (((( SELECT auth.uid() AS uid) = user_id) OR (EXISTS ( SELECT 1
   FROM riders r
  WHERE ((r.id = orders.rider_id) AND (r.user_id = ( SELECT auth.uid() AS uid))))) OR check_is_order_candidate_rider(id, ( SELECT auth.uid() AS uid))));CREATE POLICY "Deny direct client orders insert (service-role only)" ON "orders" AS PERMISSIVE FOR INSERT TO "authenticated" WITH CHECK (false);CREATE POLICY "admin_can_select_orders" ON "orders" AS PERMISSIVE FOR SELECT TO "authenticated" USING (is_admin());CREATE POLICY "user_can_update_own_order" ON "orders" AS PERMISSIVE FOR UPDATE TO "authenticated" USING (((( SELECT auth.uid() AS uid) = user_id) AND (order_status = 'searching'::order_status_enum))) WITH CHECK ((( SELECT auth.uid() AS uid) = user_id));CREATE POLICY "Allow passengers to insert assignments for their own orders" ON "rider_assignments" AS PERMISSIVE FOR INSERT TO "authenticated" WITH CHECK ((check_is_order_passenger_for_intercity(order_id, ( SELECT auth.uid() AS uid)) AND (assignment_status = ANY (ARRAY['accepted_by_user'::intercity_assignment_status_enum, 'rejected'::intercity_assignment_status_enum]))));CREATE POLICY "Allow passengers to update assignments for their own orders" ON "rider_assignments" AS PERMISSIVE FOR UPDATE TO "authenticated" USING (check_is_order_passenger_for_intercity(order_id, ( SELECT auth.uid() AS uid))) WITH CHECK ((check_is_order_passenger_for_intercity(order_id, ( SELECT auth.uid() AS uid)) AND (assignment_status = ANY (ARRAY['accepted_by_user'::intercity_assignment_status_enum, 'rejected'::intercity_assignment_status_enum]))));CREATE POLICY "Allow passengers to view assignments for their own orders" ON "rider_assignments" AS PERMISSIVE FOR SELECT TO "authenticated" USING (check_is_order_passenger(order_id, ( SELECT auth.uid() AS uid)));CREATE POLICY "Allow riders to insert their own assignments" ON "rider_assignments" AS PERMISSIVE FOR INSERT TO "authenticated" WITH CHECK (((EXISTS ( SELECT 1
   FROM riders r
  WHERE ((r.id = rider_assignments.rider_id) AND (r.user_id = ( SELECT auth.uid() AS uid))))) AND (assignment_status = ANY (ARRAY['sent'::intercity_assignment_status_enum, 'expired'::intercity_assignment_status_enum]))));CREATE POLICY "Allow riders to update their own assignments" ON "rider_assignments" AS PERMISSIVE FOR UPDATE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM riders r
  WHERE ((r.id = rider_assignments.rider_id) AND (r.user_id = ( SELECT auth.uid() AS uid)))))) WITH CHECK (((EXISTS ( SELECT 1
   FROM riders r
  WHERE ((r.id = rider_assignments.rider_id) AND (r.user_id = ( SELECT auth.uid() AS uid))))) AND (assignment_status = ANY (ARRAY['sent'::intercity_assignment_status_enum, 'expired'::intercity_assignment_status_enum]))));CREATE POLICY "Allow riders to view their own assignments" ON "rider_assignments" AS PERMISSIVE FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM riders r
  WHERE ((r.id = rider_assignments.rider_id) AND (r.user_id = ( SELECT auth.uid() AS uid))))));CREATE POLICY "Riders can view own assignments" ON "rider_assignments" AS PERMISSIVE FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM riders r
  WHERE ((r.id = rider_assignments.rider_id) AND (r.user_id = ( SELECT auth.uid() AS uid))))));CREATE POLICY "Allow owner rider or active-order passenger to view rider locat" ON "rider_locations" AS PERMISSIVE FOR SELECT TO "authenticated" USING (can_read_rider_location(rider_id));CREATE POLICY "Allow authenticated users to view online riders" ON "riders" AS PERMISSIVE FOR SELECT TO "authenticated" USING (((account_status = 'online'::rider_account_status_enum) OR (( SELECT auth.uid() AS uid) = user_id)));CREATE POLICY "Allow riders to update their own profile" ON "riders" AS PERMISSIVE FOR UPDATE TO "authenticated" USING ((( SELECT auth.uid() AS uid) = user_id)) WITH CHECK ((( SELECT auth.uid() AS uid) = user_id));CREATE POLICY "Riders can update own rider profile" ON "riders" AS PERMISSIVE FOR UPDATE TO PUBLIC USING ((( SELECT auth.uid() AS uid) = user_id));CREATE POLICY "Riders can view own rider profile" ON "riders" AS PERMISSIVE FOR SELECT TO PUBLIC USING ((( SELECT auth.uid() AS uid) = user_id));CREATE POLICY "Users can view own rider profile" ON "riders" AS PERMISSIVE FOR SELECT TO "authenticated" USING ((( SELECT auth.uid() AS uid) = user_id));CREATE POLICY "admin_can_select_riders" ON "riders" AS PERMISSIVE FOR SELECT TO "authenticated" USING (is_admin());CREATE POLICY "admin_can_update_riders" ON "riders" AS PERMISSIVE FOR UPDATE TO "authenticated" USING (is_admin()) WITH CHECK (is_admin());GRANT SELECT,INSERT,UPDATE,DELETE ON ALL TABLES IN SCHEMA public TO authenticated,service_role; GRANT SELECT ON ALL TABLES IN SCHEMA public TO anon; CREATE INDEX idx_riders_user_id ON riders(user_id); CREATE INDEX idx_riders_kyc_id ON riders(kyc_id);