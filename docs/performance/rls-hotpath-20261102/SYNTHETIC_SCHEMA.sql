DO $$BEGIN IF current_database()<>'waydrop_rls_hotpath_test' OR inet_server_addr()<>inet '127.0.0.1' OR inet_server_port()<>54329 THEN RAISE EXCEPTION 'Wrong fixture'; END IF; END$$;
CREATE SCHEMA auth;
CREATE TYPE public."payout_method_enum" AS ENUM ('bank_account','upi');
CREATE TYPE public."rider_withdrawal_status_enum" AS ENUM ('pending','processing','success','failed');
CREATE TYPE public."vehicle_type_enum" AS ENUM ('bike','auto','cab');
CREATE TYPE public."order_status_enum" AS ENUM ('created','searching','accepted','rider_arrived','picked_up','ongoing','rider_at_drop','completed','delivered','cancelled','expired','payment_pending');
CREATE TYPE public."payment_mode_enum" AS ENUM ('cash','online','wallet','upi');
CREATE TYPE public."payment_status_enum" AS ENUM ('pending','paid','failed','refunded','partial_refund','cash_collected','cash_pending_settlement');
CREATE TYPE public."assignment_status_enum" AS ENUM ('sent','viewed','accepted','rejected','timed_out','expired','cancelled');
CREATE TYPE public."rider_account_status_enum" AS ENUM ('online','offline','busy','blocked');
CREATE TYPE public."kyc_status_enum" AS ENUM ('pending','under_review','approved','rejected','resubmitted');
CREATE TYPE public."cancelled_by_enum" AS ENUM ('user','rider','admin','system');
CREATE TYPE public."parcel_type_enum" AS ENUM ('documents','electronics','food','clothes','fragile','others');
CREATE TYPE public."subscription_status_enum" AS ENUM ('active','expired','cancelled','pending');
CREATE TYPE public."pricing_city_tier_enum" AS ENUM ('tier_1','tier_2');
CREATE TYPE public."pricing_service_type_enum" AS ENUM ('ride','local_parcel','intercity_parcel','intercity_ride','ride_sharing');
CREATE TYPE public."travel_plan_status_enum" AS ENUM ('active','completed','cancelled','fully_booked','expired');
CREATE TYPE public."preferred_mode_enum" AS ENUM ('user','rider');
CREATE TYPE public."activation_status_enum" AS ENUM ('inactive','profile_pending','active','suspended');
CREATE TYPE public."cashfree_beneficiary_status_enum" AS ENUM ('pending','active','failed','disabled');
CREATE TYPE public."payment_method_enum" AS ENUM ('upi','card','wallet','netbanking','cash','cod','cashfree');
CREATE TYPE public."weight_category_enum" AS ENUM ('0_5','6_15','16_25','26_50');
CREATE TYPE public."fare_payment_method_enum" AS ENUM ('personal_upi','cashfree','cash');
CREATE TYPE public."dispute_status_enum" AS ENUM ('open','investigating','resolved_paid','resolved_unpaid');
CREATE TYPE public."review_tag" AS ENUM ('clean_vehicle','polite_behavior','safe_driving','on_time','dirty_vehicle','rude_behavior','unsafe_driving','late_arrival','other','good_behaviour','respectful','easy_to_communicate','clear_instructions','cooperative','ready_at_pickup','late_at_pickup','rude_behaviour','poor_communication','uncooperative','changed_plans','no_show');
CREATE TYPE public."partner_service_mode_enum" AS ENUM ('local','intercity');
CREATE TYPE public."intercity_assignment_status_enum" AS ENUM ('sent','viewed','accepted','rejected','timed_out','expired','cancelled','accepted_by_user');
CREATE TYPE public."order_type_enum" AS ENUM ('ride','intercity_ride','ride_sharing','local_parcel','intercity_parcel','batch_delivery','food_delivery','grocery_delivery');
CREATE TYPE public."payment_for_enum" AS ENUM ('ride_order','parcel_order','wallet_topup','subscription','withdrawal','refund','cod_settlement','ride_boost','intercity_ride_boost','intercity_parcel_boost','intercity_ride_order','intercity_parcel_order','ride_sharing','tax_due');
CREATE TABLE public."admins" ("id" uuid NOT NULL,"admin_code" text NOT NULL,"name" text NOT NULL,"phone" text NOT NULL,"email" text NOT NULL,"password_hash" text NOT NULL,"role" text NOT NULL,"permissions" jsonb NOT NULL,"is_active" boolean,"is_account_locked" boolean,"last_login_at" timestamp with time zone,"created_at" timestamp with time zone);
CREATE TABLE public."intercity_requests" ("id" uuid NOT NULL,"parcel_id" uuid NOT NULL,"route_id" uuid,"traveller_id" uuid NOT NULL,"sender_id" uuid NOT NULL,"initiated_by" text NOT NULL,"status" text NOT NULL,"proposed_fare" numeric NOT NULL,"sender_confirmed" boolean NOT NULL,"traveller_confirmed" boolean NOT NULL,"created_at" timestamp with time zone NOT NULL,"updated_at" timestamp with time zone NOT NULL,"booking_type" text,"expires_at" timestamp with time zone,"metadata" jsonb NOT NULL,"expiry_reason" text,"cancelled_reason" text,"cancelled_by_actor" text);
CREATE TABLE public."orders" ("id" uuid NOT NULL,"order_code" text NOT NULL,"user_id" uuid NOT NULL,"rider_id" uuid,"order_type" order_type_enum NOT NULL,"vehicle_type" vehicle_type_enum,"order_status" order_status_enum NOT NULL,"pricing_config_id" uuid,"distance_meters" integer NOT NULL,"distance_km" numeric NOT NULL,"estimated_duration_min" integer,"actual_duration_min" integer,"time_taken_seconds" integer,"pickup_address" text NOT NULL,"pickup_lat" double precision NOT NULL,"pickup_lng" double precision NOT NULL,"destination_address" text NOT NULL,"destination_lat" double precision NOT NULL,"destination_lng" double precision NOT NULL,"actual_fare" numeric NOT NULL,"current_fare" numeric NOT NULL,"final_fare" numeric,"base_fare" numeric,"distance_fare" numeric,"time_fare" numeric,"waiting_charge" numeric,"platform_fee" numeric,"gst_percentage" numeric,"gst_amount" numeric,"commission_percentage" numeric,"commission_amount" numeric,"rider_earning" numeric,"boost_amount" numeric,"subscription_commission_waived" boolean,"pricing_snapshot" jsonb NOT NULL,"payment_mode" payment_mode_enum NOT NULL,"payment_status" payment_status_enum NOT NULL,"payment_id" uuid,"pickup_otp" text,"delivery_otp" text,"search_expires_at" timestamp with time zone,"cancelled_by" cancelled_by_enum,"cancel_reason" text,"parcel_type" parcel_type_enum,"receiver_name" text,"receiver_phone" text,"weight_category" text,"actual_weight_kg" numeric,"parcel_images" text[],"special_instructions" text,"created_at" timestamp with time zone,"updated_at" timestamp with time zone,"accepted_at" timestamp with time zone,"rider_arrived_at" timestamp with time zone,"picked_up_at" timestamp with time zone,"rider_at_drop_at" timestamp with time zone,"completed_at" timestamp with time zone,"cancelled_at" timestamp with time zone,"pickup_otp_attempts" integer,"delivery_otp_attempts" integer,"boost_company_earning" numeric,"boost_rider_earning" numeric,"boost_percentage" numeric,"dispatch_attempts" integer,"boost_round" integer,"current_search_radius_km" numeric,"last_dispatched_at" timestamp with time zone,"rider_rejections_count" integer,"redispatch_count" integer,"pickup_city" text,"destination_city" text,"travel_date" timestamp with time zone,"dispatch_state" jsonb,"created_ip_address" inet,"created_lat" double precision,"created_lng" double precision,"sender_declaration_accepted" boolean,"sender_declaration_accepted_at" timestamp with time zone,"pickup_verification_completed" boolean,"pickup_verification_completed_at" timestamp with time zone,"compliance_flagged" boolean,"compliance_notes" text,"created_device_ref" text,"created_device_record_id" uuid,"created_device_model" text,"created_device_brand" text,"created_os_version" text,"created_app_version" text,"compliance_status" text,"compliance_score" integer,"compliance_retention_until" timestamp with time zone,"parcel_declared_value" numeric,"high_risk_parcel" boolean,"dispatch_worker_running" boolean,"dispatch_worker_started_at" timestamp with time zone,"seats_requested" integer NOT NULL,"near_destination_notified" boolean NOT NULL,"trip_started_at" timestamp with time zone,"upi_payment_prompted_at" timestamp with time zone,"fare_payment_method" fare_payment_method_enum,"fare_payment_attempted_at" timestamp with time zone,"fare_paid_at" timestamp with time zone,"fare_payment_reference" text,"fare_payment_screenshot_url" text,"idempotency_key" text,"pg_charge_amount" numeric NOT NULL);
CREATE TABLE public."rider_assignments" ("id" uuid NOT NULL,"order_id" uuid NOT NULL,"rider_id" uuid NOT NULL,"assignment_round" integer NOT NULL,"assignment_status" intercity_assignment_status_enum NOT NULL,"distance_km" numeric,"estimated_earnings" numeric,"sent_at" timestamp with time zone NOT NULL,"viewed_at" timestamp with time zone,"responded_at" timestamp with time zone,"expires_at" timestamp with time zone NOT NULL,"created_at" timestamp with time zone,"updated_at" timestamp with time zone,"last_seen_at" timestamp with time zone,"last_response_at" timestamp with time zone,"response_type" text,"hidden_until" timestamp with time zone,"last_seen_fare" numeric,"accepted_at" timestamp with time zone,"rejected_at" timestamp with time zone);
CREATE TABLE public."rider_kyc" ("id" uuid NOT NULL,"user_id" uuid NOT NULL,"full_name" text NOT NULL,"father_name" text NOT NULL,"vehicle_type" vehicle_type_enum NOT NULL,"aadhaar_number" text NOT NULL,"pan_number" text NOT NULL,"driving_license_number" text NOT NULL,"vehicle_number" text NOT NULL,"rider_image" text NOT NULL,"aadhaar_front_image" text NOT NULL,"aadhaar_back_image" text NOT NULL,"pan_front_image" text NOT NULL,"pan_back_image" text NOT NULL,"license_front_image" text NOT NULL,"license_back_image" text NOT NULL,"vehicle_image" text NOT NULL,"kyc_status" kyc_status_enum NOT NULL,"activation_status" activation_status_enum NOT NULL,"handled_by_admin_id" uuid,"approved_at" timestamp with time zone,"rejected_at" timestamp with time zone,"rejection_reason" text,"activated_at" timestamp with time zone,"created_at" timestamp with time zone,"updated_at" timestamp with time zone,"rejection_count" integer,"blocked_until" timestamp with time zone,"date_of_birth" date NOT NULL,"VECHILE_RC_front_image" text,"VECHILE_RC_back_image" text);
CREATE TABLE public."riders" ("id" uuid NOT NULL,"kyc_id" uuid NOT NULL,"user_id" uuid NOT NULL,"rating" numeric,"total_orders" integer,"total_completed_orders" integer,"total_cancelled_orders" integer,"total_earnings" numeric,"today_earnings" numeric,"wallet_balance" numeric,"cod_pending_amount" numeric,"cod_limit" numeric,"account_status" rider_account_status_enum NOT NULL,"current_lat" double precision,"current_lng" double precision,"current_heading" double precision,"last_location_updated_at" timestamp with time zone,"last_active_at" timestamp with time zone,"subscription_active" boolean,"subscription_expires_at" timestamp with time zone,"commission_waiver_active" boolean,"is_verified" boolean,"created_at" timestamp with time zone,"updated_at" timestamp with time zone,"last_dormant_notification_sent_at" timestamp with time zone,"last_sub_offline_notification_sent_at" timestamp with time zone,"service_mode" partner_service_mode_enum,"government_tax_due_balance" numeric NOT NULL,"rating_sum" numeric NOT NULL,"total_ratings" integer NOT NULL,"free_trial_started_at" timestamp with time zone,"free_trial_expires_at" timestamp with time zone,"free_trial_used" boolean NOT NULL);
CREATE TABLE public."users" ("id" uuid NOT NULL,"phone" text,"created_at" timestamp with time zone,"full_name" text,"email" text,"profile_completed" boolean,"onboarding_completed" boolean,"preferred_mode" preferred_mode_enum,"last_active_mode" preferred_mode_enum,"role" text,"pref_order_notifications" boolean NOT NULL,"pref_chat_notifications" boolean NOT NULL,"pref_rating_notifications" boolean NOT NULL,"pref_admin_notifications" boolean NOT NULL,"user_code" text,"order_notification_mode" text NOT NULL,"rating" numeric,"total_ratings" integer,"gender" text,"profile_photo_url" text,"is_developer" boolean NOT NULL,"rating_sum" numeric NOT NULL,"deleted_at" timestamp with time zone);
CREATE UNIQUE INDEX admins_pkey ON public.admins USING btree (id);
CREATE UNIQUE INDEX admins_admin_code_key ON public.admins USING btree (admin_code);
CREATE UNIQUE INDEX admins_phone_key ON public.admins USING btree (phone);
CREATE UNIQUE INDEX admins_email_key ON public.admins USING btree (email);
CREATE UNIQUE INDEX intercity_requests_pkey ON public.intercity_requests USING btree (id);
CREATE UNIQUE INDEX idx_intercity_requests_one_active_per_order_traveller_plan ON public.intercity_requests USING btree (parcel_id, traveller_id, route_id) WHERE (status <> ALL (ARRAY['cancelled'::text, 'rejected'::text, 'expired'::text, 'completed'::text]));
CREATE INDEX idx_intercity_requests_route_id ON public.intercity_requests USING btree (route_id);
CREATE INDEX idx_intercity_requests_sender_id ON public.intercity_requests USING btree (sender_id);
CREATE INDEX idx_intercity_requests_traveller_id ON public.intercity_requests USING btree (traveller_id);
CREATE UNIQUE INDEX orders_pkey ON public.orders USING btree (id);
CREATE INDEX idx_orders_user_id ON public.orders USING btree (user_id);
CREATE INDEX idx_orders_rider_id ON public.orders USING btree (rider_id);
CREATE INDEX idx_orders_order_type ON public.orders USING btree (order_type);
CREATE INDEX idx_orders_order_code ON public.orders USING btree (order_code);
CREATE INDEX idx_orders_payment_id ON public.orders USING btree (payment_id);
CREATE INDEX idx_orders_pricing_config_id ON public.orders USING btree (pricing_config_id);
CREATE INDEX idx_orders_pickup_location ON public.orders USING btree (pickup_lat, pickup_lng);
CREATE INDEX idx_orders_destination_location ON public.orders USING btree (destination_lat, destination_lng);
CREATE INDEX idx_orders_vehicle_type ON public.orders USING btree (vehicle_type);
CREATE INDEX idx_orders_order_status ON public.orders USING btree (order_status);
CREATE INDEX idx_orders_payment_status ON public.orders USING btree (payment_status);
CREATE INDEX idx_orders_searching_created_at ON public.orders USING btree (created_at) WHERE (order_status = 'searching'::order_status_enum);
CREATE UNIQUE INDEX orders_order_code_key ON public.orders USING btree (order_code);
CREATE UNIQUE INDEX idx_orders_user_idempotency_key ON public.orders USING btree (user_id, idempotency_key) WHERE (idempotency_key IS NOT NULL);
CREATE INDEX idx_orders_search_expires_at ON public.orders USING btree (search_expires_at);
CREATE INDEX idx_orders_created_at ON public.orders USING btree (created_at DESC);
CREATE INDEX idx_orders_created_device_record_id ON public.orders USING btree (created_device_record_id);
CREATE INDEX idx_orders_user_created_id ON public.orders USING btree (user_id, created_at DESC, id DESC);
CREATE INDEX idx_rider_assignments_status ON public.rider_assignments USING btree (assignment_status);
CREATE INDEX idx_rider_assignments_sent_expires_at ON public.rider_assignments USING btree (expires_at) WHERE (assignment_status = 'sent'::intercity_assignment_status_enum);
CREATE UNIQUE INDEX rider_assignments_pkey ON public.rider_assignments USING btree (id);
CREATE INDEX idx_rider_assignments_order_id ON public.rider_assignments USING btree (order_id);
CREATE INDEX idx_rider_assignments_rider_id ON public.rider_assignments USING btree (rider_id);
CREATE INDEX idx_rider_assignments_round ON public.rider_assignments USING btree (assignment_round);
CREATE INDEX idx_rider_assignments_expires_at ON public.rider_assignments USING btree (expires_at DESC);
CREATE UNIQUE INDEX rider_assignments_order_id_rider_id_key ON public.rider_assignments USING btree (order_id, rider_id);
CREATE UNIQUE INDEX rider_kyc_pkey ON public.rider_kyc USING btree (id);
CREATE INDEX idx_rider_kyc_user_id ON public.rider_kyc USING btree (user_id);
CREATE INDEX idx_rider_kyc_handled_by_admin_id ON public.rider_kyc USING btree (handled_by_admin_id);
CREATE INDEX idx_rider_kyc_kyc_status ON public.rider_kyc USING btree (kyc_status);
CREATE INDEX idx_rider_kyc_activation_status ON public.rider_kyc USING btree (activation_status);
CREATE INDEX idx_rider_kyc_created_at ON public.rider_kyc USING btree (created_at DESC);
CREATE INDEX idx_riders_account_status_service_mode ON public.riders USING btree (account_status, service_mode) INCLUDE (current_lat, current_lng, user_id, last_location_updated_at);
CREATE UNIQUE INDEX riders_pkey ON public.riders USING btree (id);
CREATE UNIQUE INDEX riders_kyc_id_key ON public.riders USING btree (kyc_id);
CREATE UNIQUE INDEX riders_user_id_key ON public.riders USING btree (user_id);
CREATE INDEX idx_riders_user_id ON public.riders USING btree (user_id);
CREATE INDEX idx_riders_kyc_id ON public.riders USING btree (kyc_id);
CREATE INDEX idx_riders_subscription_active ON public.riders USING btree (subscription_active);
CREATE INDEX idx_riders_account_status ON public.riders USING btree (account_status);
CREATE INDEX idx_riders_government_tax_due_balance ON public.riders USING btree (government_tax_due_balance);
CREATE INDEX idx_riders_service_mode ON public.riders USING btree (service_mode) WHERE (account_status = 'online'::rider_account_status_enum);
CREATE INDEX idx_riders_location_updated ON public.riders USING btree (last_location_updated_at DESC);
CREATE INDEX idx_riders_created_at ON public.riders USING btree (created_at DESC);
CREATE INDEX idx_riders_online_coords ON public.riders USING btree (current_lat, current_lng) WHERE (account_status = 'online'::rider_account_status_enum);
CREATE UNIQUE INDEX users_pkey ON public.users USING btree (id);
CREATE UNIQUE INDEX users_phone_key ON public.users USING btree (phone);
CREATE UNIQUE INDEX users_user_code_key ON public.users USING btree (user_code);
CREATE OR REPLACE FUNCTION auth.uid()
 RETURNS uuid
 LANGUAGE sql
 STABLE
AS $function$
  select 
  coalesce(
    nullif(current_setting('request.jwt.claim.sub', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
  )::uuid
$function$
;
CREATE OR REPLACE FUNCTION auth.role()
 RETURNS text
 LANGUAGE sql
 STABLE
AS $function$
  select 
  coalesce(
    nullif(current_setting('request.jwt.claim.role', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role')
  )::text
$function$
;
CREATE OR REPLACE FUNCTION auth.email()
 RETURNS text
 LANGUAGE sql
 STABLE
AS $function$
  select 
  coalesce(
    nullif(current_setting('request.jwt.claim.email', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'email')
  )::text
$function$
;
CREATE OR REPLACE FUNCTION public.check_is_order_candidate_rider(p_order_id uuid, p_user_id uuid)
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
;
CREATE OR REPLACE FUNCTION public.is_admin()
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
;
CREATE OR REPLACE FUNCTION public.check_is_order_passenger(p_order_id uuid, p_user_id uuid)
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
;
CREATE OR REPLACE FUNCTION public.check_is_order_passenger_for_intercity(p_order_id uuid, p_user_id uuid)
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
;
GRANT USAGE ON SCHEMA auth,public TO anon,authenticated,service_role;
ALTER TABLE public."admins" ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON public."admins" TO authenticated;
GRANT SELECT,INSERT,UPDATE ON public."admins" TO service_role;
ALTER TABLE public."intercity_requests" ENABLE ROW LEVEL SECURITY;
GRANT SELECT,INSERT,UPDATE,DELETE ON public."intercity_requests" TO authenticated;
GRANT SELECT,INSERT,UPDATE,DELETE ON public."intercity_requests" TO service_role;
ALTER TABLE public."orders" ENABLE ROW LEVEL SECURITY;
GRANT SELECT,INSERT,UPDATE ON public."orders" TO authenticated;
GRANT SELECT,INSERT,UPDATE,DELETE ON public."orders" TO service_role;
ALTER TABLE public."rider_assignments" ENABLE ROW LEVEL SECURITY;
GRANT SELECT,INSERT,UPDATE ON public."rider_assignments" TO authenticated;
GRANT SELECT,INSERT,UPDATE,DELETE ON public."rider_assignments" TO service_role;
ALTER TABLE public."rider_kyc" ENABLE ROW LEVEL SECURITY;
GRANT SELECT,UPDATE ON public."rider_kyc" TO authenticated;
GRANT SELECT,INSERT,UPDATE,DELETE ON public."rider_kyc" TO service_role;
ALTER TABLE public."riders" ENABLE ROW LEVEL SECURITY;
GRANT SELECT,UPDATE ON public."riders" TO authenticated;
GRANT SELECT,INSERT,UPDATE,DELETE ON public."riders" TO service_role;
ALTER TABLE public."users" ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON public."users" TO anon;
GRANT SELECT,INSERT,UPDATE ON public."users" TO authenticated;
GRANT SELECT ON public."users" TO service_role;
CREATE POLICY "admins_self_select" ON public."admins" AS PERMISSIVE FOR SELECT TO "authenticated" USING ((email = ( SELECT auth.email() AS email)));
CREATE POLICY "Allow request participants to create requests" ON public."intercity_requests" AS PERMISSIVE FOR INSERT TO "authenticated" WITH CHECK ((((sender_id = ( SELECT auth.uid() AS uid)) OR (EXISTS ( SELECT 1
   FROM riders r
  WHERE ((r.id = intercity_requests.traveller_id) AND (r.user_id = ( SELECT auth.uid() AS uid)) AND (r.service_mode = 'intercity'::partner_service_mode_enum))))) AND (status = ANY (ARRAY['request_sent'::text, 'discussion_started'::text])) AND (sender_confirmed = false) AND (traveller_confirmed = false)));
CREATE POLICY "Allow request participants to update safe fields" ON public."intercity_requests" AS PERMISSIVE FOR UPDATE TO "authenticated" USING (((sender_id = ( SELECT auth.uid() AS uid)) OR (EXISTS ( SELECT 1
   FROM riders r
  WHERE ((r.id = intercity_requests.traveller_id) AND (r.user_id = ( SELECT auth.uid() AS uid)) AND (r.service_mode = 'intercity'::partner_service_mode_enum)))))) WITH CHECK ((((sender_id = ( SELECT auth.uid() AS uid)) OR (EXISTS ( SELECT 1
   FROM riders r
  WHERE ((r.id = intercity_requests.traveller_id) AND (r.user_id = ( SELECT auth.uid() AS uid)) AND (r.service_mode = 'intercity'::partner_service_mode_enum))))) AND (status = ANY (ARRAY['request_sent'::text, 'discussion_started'::text, 'in_progress'::text, 'paid'::text])) AND (sender_confirmed = false) AND (traveller_confirmed = false)));
CREATE POLICY "Allow request participants to view requests" ON public."intercity_requests" AS PERMISSIVE FOR SELECT TO "authenticated" USING (((sender_id = ( SELECT auth.uid() AS uid)) OR (EXISTS ( SELECT 1
   FROM riders r
  WHERE ((r.id = intercity_requests.traveller_id) AND (r.user_id = ( SELECT auth.uid() AS uid)))))));
CREATE POLICY "admin_can_select_intercity_requests" ON public."intercity_requests" AS PERMISSIVE FOR SELECT TO "authenticated" USING (is_admin());
CREATE POLICY "Allow passengers and assigned riders to update orders" ON public."orders" AS PERMISSIVE FOR UPDATE TO "authenticated" USING (((( SELECT auth.uid() AS uid) = user_id) OR (EXISTS ( SELECT 1
   FROM riders r
  WHERE ((r.id = orders.rider_id) AND (r.user_id = ( SELECT auth.uid() AS uid)))))));
CREATE POLICY "Allow travellers to browse searching intercity orders" ON public."orders" AS PERMISSIVE FOR SELECT TO "authenticated" USING (((order_status = 'searching'::order_status_enum) AND ((order_type)::text ~~ 'intercity%'::text)));
CREATE POLICY "Allow travellers to view orders tied to active intercity reques" ON public."orders" AS PERMISSIVE FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM (intercity_requests ir
     JOIN riders r ON ((r.id = ir.traveller_id)))
  WHERE ((ir.parcel_id = orders.id) AND (r.user_id = ( SELECT auth.uid() AS uid)) AND (ir.status <> ALL (ARRAY['cancelled'::text, 'rejected'::text, 'expired'::text]))))));
CREATE POLICY "Allow users to view their own or assigned orders" ON public."orders" AS PERMISSIVE FOR SELECT TO "authenticated" USING (((( SELECT auth.uid() AS uid) = user_id) OR (EXISTS ( SELECT 1
   FROM riders r
  WHERE ((r.id = orders.rider_id) AND (r.user_id = ( SELECT auth.uid() AS uid))))) OR check_is_order_candidate_rider(id, ( SELECT auth.uid() AS uid))));
CREATE POLICY "Deny direct client orders insert (service-role only)" ON public."orders" AS PERMISSIVE FOR INSERT TO "authenticated" WITH CHECK (false);
CREATE POLICY "admin_can_select_orders" ON public."orders" AS PERMISSIVE FOR SELECT TO "authenticated" USING (is_admin());
CREATE POLICY "user_can_update_own_order" ON public."orders" AS PERMISSIVE FOR UPDATE TO "authenticated" USING (((( SELECT auth.uid() AS uid) = user_id) AND (order_status = 'searching'::order_status_enum))) WITH CHECK ((( SELECT auth.uid() AS uid) = user_id));
CREATE POLICY "Allow passengers to insert assignments for their own orders" ON public."rider_assignments" AS PERMISSIVE FOR INSERT TO "authenticated" WITH CHECK ((check_is_order_passenger_for_intercity(order_id, ( SELECT auth.uid() AS uid)) AND (assignment_status = ANY (ARRAY['accepted_by_user'::intercity_assignment_status_enum, 'rejected'::intercity_assignment_status_enum]))));
CREATE POLICY "Allow passengers to update assignments for their own orders" ON public."rider_assignments" AS PERMISSIVE FOR UPDATE TO "authenticated" USING (check_is_order_passenger_for_intercity(order_id, ( SELECT auth.uid() AS uid))) WITH CHECK ((check_is_order_passenger_for_intercity(order_id, ( SELECT auth.uid() AS uid)) AND (assignment_status = ANY (ARRAY['accepted_by_user'::intercity_assignment_status_enum, 'rejected'::intercity_assignment_status_enum]))));
CREATE POLICY "Allow passengers to view assignments for their own orders" ON public."rider_assignments" AS PERMISSIVE FOR SELECT TO "authenticated" USING (check_is_order_passenger(order_id, ( SELECT auth.uid() AS uid)));
CREATE POLICY "Allow riders to insert their own assignments" ON public."rider_assignments" AS PERMISSIVE FOR INSERT TO "authenticated" WITH CHECK (((EXISTS ( SELECT 1
   FROM riders r
  WHERE ((r.id = rider_assignments.rider_id) AND (r.user_id = ( SELECT auth.uid() AS uid))))) AND (assignment_status = ANY (ARRAY['sent'::intercity_assignment_status_enum, 'expired'::intercity_assignment_status_enum]))));
CREATE POLICY "Allow riders to update their own assignments" ON public."rider_assignments" AS PERMISSIVE FOR UPDATE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM riders r
  WHERE ((r.id = rider_assignments.rider_id) AND (r.user_id = ( SELECT auth.uid() AS uid)))))) WITH CHECK (((EXISTS ( SELECT 1
   FROM riders r
  WHERE ((r.id = rider_assignments.rider_id) AND (r.user_id = ( SELECT auth.uid() AS uid))))) AND (assignment_status = ANY (ARRAY['sent'::intercity_assignment_status_enum, 'expired'::intercity_assignment_status_enum]))));
CREATE POLICY "Allow riders to view their own assignments" ON public."rider_assignments" AS PERMISSIVE FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM riders r
  WHERE ((r.id = rider_assignments.rider_id) AND (r.user_id = ( SELECT auth.uid() AS uid))))));
CREATE POLICY "Riders can view own assignments" ON public."rider_assignments" AS PERMISSIVE FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM riders r
  WHERE ((r.id = rider_assignments.rider_id) AND (r.user_id = ( SELECT auth.uid() AS uid))))));
CREATE POLICY "Riders can insert own KYC" ON public."rider_kyc" AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK ((( SELECT auth.uid() AS uid) = user_id));
CREATE POLICY "Riders can view own KYC" ON public."rider_kyc" AS PERMISSIVE FOR SELECT TO PUBLIC USING ((( SELECT auth.uid() AS uid) = user_id));
CREATE POLICY "Riders view own KYC or admin support view any" ON public."rider_kyc" AS PERMISSIVE FOR SELECT TO "authenticated" USING (((( SELECT auth.uid() AS uid) = user_id) OR (EXISTS ( SELECT 1
   FROM users u
  WHERE ((u.id = ( SELECT auth.uid() AS uid)) AND ((u.role = 'admin'::text) OR (u.role = 'support'::text)))))));
CREATE POLICY "Users can create own kyc" ON public."rider_kyc" AS PERMISSIVE FOR INSERT TO "authenticated" WITH CHECK ((( SELECT auth.uid() AS uid) = user_id));
CREATE POLICY "Users can update own kyc" ON public."rider_kyc" AS PERMISSIVE FOR UPDATE TO "authenticated" USING ((( SELECT auth.uid() AS uid) = user_id));
CREATE POLICY "Users can view own kyc" ON public."rider_kyc" AS PERMISSIVE FOR SELECT TO "authenticated" USING ((( SELECT auth.uid() AS uid) = user_id));
CREATE POLICY "admin_can_select_rider_kyc" ON public."rider_kyc" AS PERMISSIVE FOR SELECT TO "authenticated" USING (is_admin());
CREATE POLICY "admin_can_update_rider_kyc" ON public."rider_kyc" AS PERMISSIVE FOR UPDATE TO "authenticated" USING (is_admin()) WITH CHECK (is_admin());
CREATE POLICY "Allow authenticated users to view online riders" ON public."riders" AS PERMISSIVE FOR SELECT TO "authenticated" USING (((account_status = 'online'::rider_account_status_enum) OR (( SELECT auth.uid() AS uid) = user_id)));
CREATE POLICY "Allow riders to update their own profile" ON public."riders" AS PERMISSIVE FOR UPDATE TO "authenticated" USING ((( SELECT auth.uid() AS uid) = user_id)) WITH CHECK ((( SELECT auth.uid() AS uid) = user_id));
CREATE POLICY "Riders can update own rider profile" ON public."riders" AS PERMISSIVE FOR UPDATE TO PUBLIC USING ((( SELECT auth.uid() AS uid) = user_id));
CREATE POLICY "Riders can view own rider profile" ON public."riders" AS PERMISSIVE FOR SELECT TO PUBLIC USING ((( SELECT auth.uid() AS uid) = user_id));
CREATE POLICY "Users can view own rider profile" ON public."riders" AS PERMISSIVE FOR SELECT TO "authenticated" USING ((( SELECT auth.uid() AS uid) = user_id));
CREATE POLICY "admin_can_select_riders" ON public."riders" AS PERMISSIVE FOR SELECT TO "authenticated" USING (is_admin());
CREATE POLICY "admin_can_update_riders" ON public."riders" AS PERMISSIVE FOR UPDATE TO "authenticated" USING (is_admin()) WITH CHECK (is_admin());
CREATE POLICY "Allow travellers to view profile of searching intercity passeng" ON public."users" AS PERMISSIVE FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM orders o
  WHERE ((o.user_id = users.id) AND (o.order_status = 'searching'::order_status_enum) AND ((o.order_type)::text ~~ 'intercity%'::text)))));
CREATE POLICY "Allow travellers to view sender profile for active intercity re" ON public."users" AS PERMISSIVE FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM (intercity_requests ir
     JOIN riders r ON ((r.id = ir.traveller_id)))
  WHERE ((ir.sender_id = users.id) AND (r.user_id = ( SELECT auth.uid() AS uid)) AND (ir.status <> ALL (ARRAY['cancelled'::text, 'rejected'::text, 'expired'::text]))))));
CREATE POLICY "Users can insert own profile" ON public."users" AS PERMISSIVE FOR INSERT TO "authenticated" WITH CHECK ((( SELECT auth.uid() AS uid) = id));
CREATE POLICY "Users can update own profile" ON public."users" AS PERMISSIVE FOR UPDATE TO "authenticated" USING ((( SELECT auth.uid() AS uid) = id));
CREATE POLICY "Users can view own profile" ON public."users" AS PERMISSIVE FOR SELECT TO "authenticated" USING ((( SELECT auth.uid() AS uid) = id));
CREATE POLICY "admin_can_select_users" ON public."users" AS PERMISSIVE FOR SELECT TO "authenticated" USING (is_admin());
CREATE TABLE public.rls_fixture_marker(value text); INSERT INTO public.rls_fixture_marker VALUES('waydrop_rls_hotpath_synthetic_v1');
