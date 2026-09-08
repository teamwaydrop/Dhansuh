-- WARNING: This schema is for context only and is not meant to be run.
-- Table order and constraints may not be valid for execution.

CREATE TABLE public.users (
  id uuid NOT NULL,
  phone text UNIQUE,
  created_at timestamp with time zone DEFAULT timezone('utc'::text, now()),
  full_name text,
  email text,
  profile_completed boolean DEFAULT false,
  onboarding_completed boolean DEFAULT false,
  preferred_mode USER-DEFINED DEFAULT 'user'::preferred_mode_enum,
  last_active_mode USER-DEFINED DEFAULT 'user'::preferred_mode_enum,
  role text DEFAULT 'user'::text,
  pref_order_notifications boolean NOT NULL DEFAULT true,
  pref_chat_notifications boolean NOT NULL DEFAULT true,
  pref_rating_notifications boolean NOT NULL DEFAULT true,
  pref_admin_notifications boolean NOT NULL DEFAULT true,
  user_code text UNIQUE,
  order_notification_mode text NOT NULL DEFAULT 'important_only'::text CHECK (order_notification_mode = ANY (ARRAY['all'::text, 'important_only'::text, 'tracking_silent'::text])),
  CONSTRAINT users_pkey PRIMARY KEY (id),
  CONSTRAINT users_id_fkey FOREIGN KEY (id) REFERENCES auth.users(id)
);
CREATE TABLE public.admins (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  admin_code text NOT NULL UNIQUE,
  name text NOT NULL,
  phone text NOT NULL UNIQUE,
  email text NOT NULL UNIQUE,
  password_hash text NOT NULL,
  role text NOT NULL,
  permissions jsonb NOT NULL DEFAULT '{}'::jsonb,
  is_active boolean DEFAULT true,
  is_account_locked boolean DEFAULT false,
  last_login_at timestamp with time zone,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT admins_pkey PRIMARY KEY (id)
);
CREATE TABLE public.admin_logs (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  admin_id uuid NOT NULL,
  action_type text NOT NULL,
  target_type text NOT NULL,
  target_id uuid NOT NULL,
  description text,
  metadata jsonb DEFAULT '{}'::jsonb,
  ip_address text,
  user_agent text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT admin_logs_pkey PRIMARY KEY (id),
  CONSTRAINT admin_logs_admin_id_fkey FOREIGN KEY (admin_id) REFERENCES public.admins(id)
);
CREATE TABLE public.rider_kyc (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  full_name text NOT NULL,
  father_name text NOT NULL,
  vehicle_type USER-DEFINED NOT NULL,
  aadhaar_number text NOT NULL CHECK (length(aadhaar_number) = 12),
  pan_number text NOT NULL CHECK (pan_number ~ '^[A-Z]{5}[0-9]{4}[A-Z]{1}$'::text),
  driving_license_number text NOT NULL,
  vehicle_number text NOT NULL,
  rider_image text NOT NULL,
  aadhaar_front_image text NOT NULL,
  aadhaar_back_image text NOT NULL,
  pan_front_image text NOT NULL,
  pan_back_image text NOT NULL,
  license_front_image text NOT NULL,
  license_back_image text NOT NULL,
  vehicle_image text NOT NULL,
  kyc_status USER-DEFINED NOT NULL DEFAULT 'pending'::kyc_status_enum,
  activation_status USER-DEFINED NOT NULL DEFAULT 'inactive'::activation_status_enum,
  handled_by_admin_id uuid,
  approved_at timestamp with time zone,
  rejected_at timestamp with time zone,
  rejection_reason text,
  activated_at timestamp with time zone,
  created_at timestamp with time zone DEFAULT now(),
  updated_at timestamp with time zone DEFAULT now(),
  rejection_count integer DEFAULT 0,
  blocked_until timestamp with time zone,
  date_of_birth date NOT NULL CHECK (date_of_birth <= (CURRENT_DATE - '18 years'::interval)),
  VECHILE_RC_front_image text,
  VECHILE_RC_back_image text,
  CONSTRAINT rider_kyc_pkey PRIMARY KEY (id),
  CONSTRAINT rider_kyc_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id),
  CONSTRAINT rider_kyc_handled_by_admin_id_fkey FOREIGN KEY (handled_by_admin_id) REFERENCES public.admins(id)
);
CREATE TABLE public.riders (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  kyc_id uuid NOT NULL UNIQUE,
  user_id uuid NOT NULL UNIQUE,
  rating numeric DEFAULT 5,
  total_orders integer DEFAULT 0,
  total_completed_orders integer DEFAULT 0,
  total_cancelled_orders integer DEFAULT 0,
  total_earnings numeric DEFAULT 0,
  today_earnings numeric DEFAULT 0,
  wallet_balance numeric DEFAULT 0,
  cod_pending_amount numeric DEFAULT 0,
  cod_limit numeric DEFAULT '500'::numeric,
  account_status USER-DEFINED NOT NULL DEFAULT 'offline'::rider_account_status_enum,
  current_lat double precision,
  current_lng double precision,
  current_heading double precision,
  last_location_updated_at timestamp with time zone,
  last_active_at timestamp with time zone,
  subscription_active boolean DEFAULT false,
  subscription_expires_at timestamp with time zone,
  commission_waiver_active boolean DEFAULT false,
  is_verified boolean DEFAULT true,
  created_at timestamp with time zone DEFAULT now(),
  updated_at timestamp with time zone DEFAULT now(),
  last_dormant_notification_sent_at timestamp with time zone,
  last_sub_offline_notification_sent_at timestamp with time zone,
  CONSTRAINT riders_pkey PRIMARY KEY (id),
  CONSTRAINT riders_kyc_id_fkey FOREIGN KEY (kyc_id) REFERENCES public.rider_kyc(id),
  CONSTRAINT riders_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id)
);
CREATE TABLE public.payments (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  payment_code text NOT NULL UNIQUE,
  user_id uuid,
  rider_id uuid,
  payment_for USER-DEFINED NOT NULL,
  reference_id uuid,
  amount numeric NOT NULL,
  gst_amount numeric DEFAULT 0,
  platform_fee numeric DEFAULT 0,
  discount_amount numeric DEFAULT 0,
  final_amount numeric NOT NULL,
  payment_method USER-DEFINED NOT NULL,
  payment_gateway text,
  gateway_transaction_id text,
  gateway_order_id text,
  payment_status USER-DEFINED NOT NULL DEFAULT 'pending'::payment_status_enum,
  paid_at timestamp with time zone,
  refunded_at timestamp with time zone,
  refund_reason text,
  metadata jsonb DEFAULT '{}'::jsonb,
  created_at timestamp with time zone DEFAULT now(),
  updated_at timestamp with time zone DEFAULT now(),
  rider_earning numeric DEFAULT 0,
  company_earning numeric DEFAULT 0,
  webhook_received boolean DEFAULT false,
  webhook_payload jsonb,
  failure_reason text,
  settlement_reference text,
  payment_source text,
  CONSTRAINT payments_pkey PRIMARY KEY (id),
  CONSTRAINT payments_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id),
  CONSTRAINT payments_rider_id_fkey FOREIGN KEY (rider_id) REFERENCES public.riders(id)
);
CREATE TABLE public.rider_subscription_history (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  rider_id uuid NOT NULL,
  amount numeric NOT NULL,
  payment_status text NOT NULL,
  payment_id uuid,
  starts_at timestamp with time zone NOT NULL,
  expires_at timestamp with time zone NOT NULL,
  is_active boolean DEFAULT true,
  created_at timestamp with time zone DEFAULT now(),
  expire_warning_sent boolean DEFAULT false,
  CONSTRAINT rider_subscription_history_pkey PRIMARY KEY (id),
  CONSTRAINT rider_subscription_history_rider_id_fkey FOREIGN KEY (rider_id) REFERENCES public.riders(id),
  CONSTRAINT rider_subscription_history_payment_id_fkey FOREIGN KEY (payment_id) REFERENCES public.payments(id)
);
CREATE TABLE public.pricing_zones (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  zone_code text NOT NULL UNIQUE,
  zone_name text NOT NULL,
  zone_type text NOT NULL,
  cities ARRAY NOT NULL,
  is_active boolean DEFAULT true,
  created_at timestamp with time zone DEFAULT now(),
  center_lat double precision CHECK (center_lat IS NULL OR center_lat >= '-90'::integer::double precision AND center_lat <= 90::double precision),
  center_lng double precision CHECK (center_lng IS NULL OR center_lng >= '-180'::integer::double precision AND center_lng <= 180::double precision),
  radius_km double precision CHECK (radius_km IS NULL OR radius_km > 0::double precision),
  zone_shape text NOT NULL DEFAULT 'radius'::text,
  CONSTRAINT pricing_zones_pkey PRIMARY KEY (id)
);
CREATE TABLE public.pricing_config (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  pricing_code text NOT NULL UNIQUE,
  service_type text NOT NULL,
  vehicle_type text,
  city_tier text,
  pricing_zone_id uuid,
  commission_percentage numeric NOT NULL CHECK (commission_percentage >= 0::numeric AND commission_percentage <= 100::numeric),
  gst_percentage numeric NOT NULL DEFAULT 5 CHECK (gst_percentage >= 0::numeric AND gst_percentage <= 100::numeric),
  cancellation_fee numeric DEFAULT 0,
  waiting_charge_per_min numeric DEFAULT 0,
  subscription_commission_waiver boolean DEFAULT true,
  max_boost_percentage numeric DEFAULT 50 CHECK (max_boost_percentage >= 0::numeric AND max_boost_percentage <= 500::numeric),
  pricing_rules jsonb NOT NULL,
  future_rules jsonb DEFAULT '{}'::jsonb,
  approval_status text NOT NULL DEFAULT 'approved'::text,
  approved_by_admin_id uuid,
  approved_at timestamp with time zone,
  rejection_reason text,
  is_active boolean DEFAULT true,
  effective_from timestamp with time zone DEFAULT now(),
  effective_until timestamp with time zone,
  created_by_admin_id uuid NOT NULL,
  created_at timestamp with time zone DEFAULT now(),
  updated_at timestamp with time zone DEFAULT now(),
  CONSTRAINT pricing_config_pkey PRIMARY KEY (id),
  CONSTRAINT pricing_config_pricing_zone_id_fkey FOREIGN KEY (pricing_zone_id) REFERENCES public.pricing_zones(id),
  CONSTRAINT pricing_config_approved_by_admin_id_fkey FOREIGN KEY (approved_by_admin_id) REFERENCES public.admins(id),
  CONSTRAINT pricing_config_created_by_admin_id_fkey FOREIGN KEY (created_by_admin_id) REFERENCES public.admins(id)
);
CREATE TABLE public.pricing_change_logs (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  pricing_config_id uuid NOT NULL,
  changed_by_admin_id uuid NOT NULL,
  old_data jsonb NOT NULL,
  new_data jsonb NOT NULL,
  change_reason text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT pricing_change_logs_pkey PRIMARY KEY (id),
  CONSTRAINT pricing_change_logs_pricing_config_id_fkey FOREIGN KEY (pricing_config_id) REFERENCES public.pricing_config(id),
  CONSTRAINT pricing_change_logs_changed_by_admin_id_fkey FOREIGN KEY (changed_by_admin_id) REFERENCES public.admins(id)
);
CREATE TABLE public.orders (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  order_code text NOT NULL UNIQUE,
  user_id uuid NOT NULL,
  rider_id uuid,
  order_type USER-DEFINED NOT NULL,
  vehicle_type USER-DEFINED,
  order_status USER-DEFINED NOT NULL DEFAULT 'created'::order_status_enum,
  pricing_config_id uuid,
  distance_meters integer NOT NULL CHECK (distance_meters >= 0),
  distance_km numeric NOT NULL CHECK (distance_km >= 0::numeric),
  estimated_duration_min integer,
  actual_duration_min integer,
  time_taken_seconds integer,
  pickup_address text NOT NULL,
  pickup_lat double precision NOT NULL,
  pickup_lng double precision NOT NULL,
  destination_address text NOT NULL,
  destination_lat double precision NOT NULL,
  destination_lng double precision NOT NULL,
  actual_fare numeric NOT NULL CHECK (actual_fare >= 0::numeric),
  current_fare numeric NOT NULL CHECK (current_fare >= 0::numeric),
  final_fare numeric CHECK (final_fare IS NULL OR final_fare >= 0::numeric),
  base_fare numeric DEFAULT 0,
  distance_fare numeric DEFAULT 0,
  time_fare numeric DEFAULT 0,
  waiting_charge numeric DEFAULT 0,
  platform_fee numeric DEFAULT 0,
  gst_percentage numeric DEFAULT 0 CHECK (gst_percentage >= 0::numeric AND gst_percentage <= 100::numeric),
  gst_amount numeric DEFAULT 0,
  commission_percentage numeric DEFAULT 0 CHECK (commission_percentage >= 0::numeric AND commission_percentage <= 100::numeric),
  commission_amount numeric DEFAULT 0,
  rider_earning numeric DEFAULT 0,
  boost_amount numeric DEFAULT 0,
  subscription_commission_waived boolean DEFAULT false,
  pricing_snapshot jsonb NOT NULL DEFAULT '{}'::jsonb,
  payment_mode USER-DEFINED NOT NULL,
  payment_status USER-DEFINED NOT NULL DEFAULT 'pending'::payment_status_enum,
  payment_id uuid,
  pickup_otp text,
  delivery_otp text,
  search_expires_at timestamp with time zone,
  cancelled_by USER-DEFINED,
  cancel_reason text,
  parcel_type USER-DEFINED,
  receiver_name text,
  receiver_phone text,
  weight_category text,
  actual_weight_kg numeric,
  parcel_images ARRAY,
  special_instructions text,
  created_at timestamp with time zone DEFAULT now(),
  updated_at timestamp with time zone DEFAULT now(),
  accepted_at timestamp with time zone,
  rider_arrived_at timestamp with time zone,
  picked_up_at timestamp with time zone,
  rider_at_drop_at timestamp with time zone,
  completed_at timestamp with time zone,
  cancelled_at timestamp with time zone,
  pickup_otp_attempts integer DEFAULT 0,
  delivery_otp_attempts integer DEFAULT 0,
  boost_company_earning numeric DEFAULT 0,
  boost_rider_earning numeric DEFAULT 0,
  boost_percentage numeric DEFAULT 0,
  dispatch_attempts integer DEFAULT 0,
  boost_round integer DEFAULT 0,
  current_search_radius_km numeric DEFAULT 3,
  last_dispatched_at timestamp with time zone,
  rider_rejections_count integer DEFAULT 0,
  redispatch_count integer DEFAULT 0,
  pickup_city text,
  destination_city text,
  travel_date timestamp with time zone,
  dispatch_state jsonb DEFAULT '{}'::jsonb,
  created_ip_address inet,
  created_lat double precision,
  created_lng double precision,
  sender_declaration_accepted boolean DEFAULT false,
  sender_declaration_accepted_at timestamp with time zone,
  pickup_verification_completed boolean DEFAULT false,
  pickup_verification_completed_at timestamp with time zone,
  compliance_flagged boolean DEFAULT false,
  compliance_notes text,
  created_device_ref text,
  created_device_record_id uuid,
  created_device_model text,
  created_device_brand text,
  created_os_version text,
  created_app_version text,
  compliance_status text DEFAULT 'pending'::text CHECK (compliance_status = ANY (ARRAY['pending'::text, 'verified'::text, 'flagged'::text, 'investigating'::text])),
  compliance_score integer DEFAULT 100,
  compliance_retention_until timestamp with time zone,
  parcel_declared_value numeric,
  high_risk_parcel boolean DEFAULT false,
  dispatch_worker_running boolean DEFAULT false,
  dispatch_worker_started_at timestamp with time zone,
  CONSTRAINT orders_pkey PRIMARY KEY (id),
  CONSTRAINT orders_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id),
  CONSTRAINT orders_rider_id_fkey FOREIGN KEY (rider_id) REFERENCES public.riders(id),
  CONSTRAINT orders_pricing_config_id_fkey FOREIGN KEY (pricing_config_id) REFERENCES public.pricing_config(id),
  CONSTRAINT orders_payment_id_fkey FOREIGN KEY (payment_id) REFERENCES public.payments(id),
  CONSTRAINT orders_created_device_record_id_fkey FOREIGN KEY (created_device_record_id) REFERENCES public.user_devices(id)
);
CREATE TABLE public.order_status_history (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL,
  previous_status text,
  new_status text NOT NULL,
  changed_by text NOT NULL,
  changed_by_user_id uuid,
  changed_by_rider_id uuid,
  changed_by_admin_id uuid,
  notes text,
  metadata jsonb DEFAULT '{}'::jsonb,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT order_status_history_pkey PRIMARY KEY (id),
  CONSTRAINT order_status_history_order_id_fkey FOREIGN KEY (order_id) REFERENCES public.orders(id),
  CONSTRAINT order_status_history_changed_by_user_id_fkey FOREIGN KEY (changed_by_user_id) REFERENCES public.users(id),
  CONSTRAINT order_status_history_changed_by_rider_id_fkey FOREIGN KEY (changed_by_rider_id) REFERENCES public.riders(id),
  CONSTRAINT order_status_history_changed_by_admin_id_fkey FOREIGN KEY (changed_by_admin_id) REFERENCES public.admins(id)
);
CREATE TABLE public.order_assignment_logs (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL,
  rider_id uuid NOT NULL,
  assignment_status USER-DEFINED NOT NULL DEFAULT 'sent'::intercity_assignment_status_enum,
  assignment_round integer DEFAULT 1,
  rider_distance_km numeric,
  estimated_pickup_time_min integer,
  sent_at timestamp with time zone DEFAULT now(),
  viewed_at timestamp with time zone,
  responded_at timestamp with time zone,
  rejection_reason text,
  metadata jsonb DEFAULT '{}'::jsonb,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT order_assignment_logs_pkey PRIMARY KEY (id),
  CONSTRAINT order_assignment_logs_order_id_fkey FOREIGN KEY (order_id) REFERENCES public.orders(id),
  CONSTRAINT order_assignment_logs_rider_id_fkey FOREIGN KEY (rider_id) REFERENCES public.riders(id)
);
CREATE TABLE public.dispatch_config (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  config_code text NOT NULL UNIQUE,
  round_1_radius_km numeric NOT NULL DEFAULT 3,
  round_1_batch_size integer NOT NULL DEFAULT 3,
  round_2_radius_km numeric NOT NULL DEFAULT 6,
  round_2_batch_size integer NOT NULL DEFAULT 5,
  round_3_radius_km numeric NOT NULL DEFAULT 10,
  round_3_batch_size integer NOT NULL DEFAULT 8,
  rider_response_timeout_sec integer NOT NULL DEFAULT 25,
  max_search_duration_sec integer NOT NULL DEFAULT 900,
  reject_cooldown_sec integer NOT NULL DEFAULT 600,
  timeout_cooldown_sec integer NOT NULL DEFAULT 120,
  rider_location_stale_sec integer NOT NULL DEFAULT 30,
  max_active_orders_per_rider integer NOT NULL DEFAULT 1,
  allow_round_3 boolean DEFAULT true,
  allow_boosted_priority boolean DEFAULT true,
  is_active boolean DEFAULT true,
  updated_by_admin_id uuid,
  created_at timestamp with time zone DEFAULT now(),
  updated_at timestamp with time zone DEFAULT now(),
  round_2_trigger_if_no_riders_sec integer DEFAULT 60,
  round_2_trigger_after_sec integer DEFAULT 300,
  round_3_trigger_after_sec integer DEFAULT 600,
  CONSTRAINT dispatch_config_pkey PRIMARY KEY (id),
  CONSTRAINT dispatch_config_updated_by_admin_id_fkey FOREIGN KEY (updated_by_admin_id) REFERENCES public.admins(id)
);
CREATE TABLE public.rider_assignments (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL,
  rider_id uuid NOT NULL,
  assignment_round integer NOT NULL DEFAULT 1,
  assignment_status USER-DEFINED NOT NULL DEFAULT 'sent'::intercity_assignment_status_enum,
  distance_km numeric,
  estimated_earnings numeric,
  sent_at timestamp with time zone NOT NULL DEFAULT now(),
  viewed_at timestamp with time zone,
  responded_at timestamp with time zone,
  expires_at timestamp with time zone NOT NULL,
  created_at timestamp with time zone DEFAULT now(),
  updated_at timestamp with time zone DEFAULT now(),
  last_seen_at timestamp with time zone,
  last_response_at timestamp with time zone,
  response_type text,
  hidden_until timestamp with time zone,
  last_seen_fare numeric,
  CONSTRAINT rider_assignments_pkey PRIMARY KEY (id),
  CONSTRAINT rider_assignments_order_id_fkey FOREIGN KEY (order_id) REFERENCES public.orders(id),
  CONSTRAINT rider_assignments_rider_id_fkey FOREIGN KEY (rider_id) REFERENCES public.riders(id)
);
CREATE TABLE public.rider_payout_accounts (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  rider_id uuid NOT NULL,
  user_id uuid NOT NULL,
  beneficiary_id text NOT NULL UNIQUE,
  beneficiary_name text NOT NULL,
  beneficiary_email text,
  beneficiary_phone text NOT NULL,
  account_number text CHECK (length(account_number) >= 8 AND length(account_number) <= 20),
  ifsc_code text CHECK (ifsc_code ~ '^[A-Z]{4}0[A-Z0-9]{6}$'::text),
  upi_vpa text,
  cashfree_beneficiary_added boolean DEFAULT false,
  cashfree_beneficiary_status USER-DEFINED,
  cashfree_beneficiary_response jsonb,
  is_primary boolean DEFAULT true,
  created_at timestamp with time zone DEFAULT now(),
  updated_at timestamp with time zone DEFAULT now(),
  payout_method USER-DEFINED NOT NULL,
  CONSTRAINT rider_payout_accounts_pkey PRIMARY KEY (id),
  CONSTRAINT rider_payout_accounts_rider_id_fkey FOREIGN KEY (rider_id) REFERENCES public.riders(id),
  CONSTRAINT rider_payout_accounts_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id)
);
CREATE TABLE public.rider_withdrawals (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  rider_id uuid NOT NULL,
  user_id uuid NOT NULL,
  amount numeric NOT NULL CHECK (amount > 0::numeric),
  transfer_id text NOT NULL UNIQUE,
  status USER-DEFINED NOT NULL DEFAULT 'pending'::rider_withdrawal_status_enum,
  cashfree_reference_id text,
  cashfree_response jsonb,
  created_at timestamp with time zone DEFAULT now(),
  updated_at timestamp with time zone DEFAULT now(),
  CONSTRAINT rider_withdrawals_pkey PRIMARY KEY (id),
  CONSTRAINT rider_withdrawals_rider_id_fkey FOREIGN KEY (rider_id) REFERENCES public.riders(id),
  CONSTRAINT rider_withdrawals_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id)
);
CREATE TABLE public.rider_withdrawal_events (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  withdrawal_id uuid NOT NULL,
  event_type text NOT NULL,
  old_status USER-DEFINED,
  new_status USER-DEFINED NOT NULL,
  response jsonb,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT rider_withdrawal_events_pkey PRIMARY KEY (id),
  CONSTRAINT rider_withdrawal_events_withdrawal_id_fkey FOREIGN KEY (withdrawal_id) REFERENCES public.rider_withdrawals(id)
);
CREATE TABLE public.rider_payout_updates_log (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT rider_payout_updates_log_pkey PRIMARY KEY (id),
  CONSTRAINT rider_payout_updates_log_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id)
);
CREATE TABLE public.rider_reviews (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL UNIQUE,
  rider_id uuid NOT NULL,
  user_id uuid NOT NULL,
  rating integer NOT NULL CHECK (rating >= 1 AND rating <= 5),
  tags ARRAY DEFAULT '{}'::review_tag[],
  comment text,
  created_at timestamp with time zone NOT NULL DEFAULT timezone('utc'::text, now()),
  CONSTRAINT rider_reviews_pkey PRIMARY KEY (id),
  CONSTRAINT rider_reviews_order_id_fkey FOREIGN KEY (order_id) REFERENCES public.orders(id),
  CONSTRAINT rider_reviews_rider_id_fkey FOREIGN KEY (rider_id) REFERENCES public.riders(id),
  CONSTRAINT rider_reviews_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id)
);
CREATE TABLE public.rider_travel_plans (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  rider_id uuid NOT NULL,
  pickup_city text NOT NULL,
  destination_city text NOT NULL,
  pickup_lat double precision,
  pickup_lng double precision,
  destination_lat double precision,
  destination_lng double precision,
  weight_preference text,
  travel_date timestamp with time zone NOT NULL,
  status USER-DEFINED NOT NULL DEFAULT 'active'::travel_plan_status_enum,
  created_at text DEFAULT ((now() AT TIME ZONE 'UTC'::text))::text,
  updated_at text DEFAULT ((now() AT TIME ZONE 'UTC'::text))::text,
  plan_code text UNIQUE,
  max_weight_kg numeric NOT NULL DEFAULT 0,
  max_bookings integer NOT NULL DEFAULT 3,
  travel_plan_type text NOT NULL DEFAULT 'both'::text CHECK (travel_plan_type = ANY (ARRAY['ride'::text, 'parcel'::text, 'both'::text])),
  vehicle_type USER-DEFINED,
  route_geometry text,
  CONSTRAINT rider_travel_plans_pkey PRIMARY KEY (id),
  CONSTRAINT rider_travel_plans_rider_id_fkey FOREIGN KEY (rider_id) REFERENCES public.riders(id)
);
CREATE TABLE public.order_chat_messages (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  order_id uuid,
  rider_id uuid,
  sender_id uuid NOT NULL,
  sender_type text NOT NULL CHECK (sender_type = ANY (ARRAY['user'::text, 'rider'::text, 'admin'::text, 'support'::text])),
  message text NOT NULL,
  created_at timestamp with time zone NOT NULL DEFAULT timezone('utc'::text, now()),
  is_support boolean DEFAULT false,
  user_id uuid,
  message_type text DEFAULT 'text'::text CHECK (message_type = ANY (ARRAY['text'::text, 'offer'::text, 'image'::text, 'location'::text])),
  metadata jsonb DEFAULT '{}'::jsonb,
  CONSTRAINT order_chat_messages_pkey PRIMARY KEY (id),
  CONSTRAINT order_chat_messages_order_id_fkey FOREIGN KEY (order_id) REFERENCES public.orders(id),
  CONSTRAINT order_chat_messages_rider_id_fkey FOREIGN KEY (rider_id) REFERENCES public.riders(id),
  CONSTRAINT order_chat_messages_sender_id_fkey FOREIGN KEY (sender_id) REFERENCES auth.users(id),
  CONSTRAINT order_chat_messages_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id)
);
CREATE TABLE public.user_device_tokens (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  fcm_token text NOT NULL UNIQUE,
  device_type text,
  created_at timestamp with time zone DEFAULT now(),
  updated_at timestamp with time zone DEFAULT now(),
  device_id text,
  device_model text,
  device_brand text,
  os_version text,
  app_version text,
  last_ip_address inet,
  last_lat double precision,
  last_lng double precision,
  user_device_id uuid,
  CONSTRAINT user_device_tokens_pkey PRIMARY KEY (id),
  CONSTRAINT user_device_tokens_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id),
  CONSTRAINT user_device_tokens_user_device_id_fkey FOREIGN KEY (user_device_id) REFERENCES public.user_devices(id)
);
CREATE TABLE public.intercity_requests (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  parcel_id uuid NOT NULL,
  route_id uuid,
  traveller_id uuid NOT NULL,
  sender_id uuid NOT NULL,
  initiated_by text NOT NULL CHECK (initiated_by = ANY (ARRAY['traveller'::text, 'sender'::text])),
  status text NOT NULL DEFAULT 'request_sent'::text CHECK (status = ANY (ARRAY['request_sent'::text, 'discussion_started'::text, 'fare_agreed'::text, 'confirmed'::text, 'paid'::text, 'in_progress'::text, 'completed'::text, 'expired'::text, 'cancelled'::text, 'rejected'::text])),
  proposed_fare numeric NOT NULL,
  sender_confirmed boolean NOT NULL DEFAULT false,
  traveller_confirmed boolean NOT NULL DEFAULT false,
  created_at timestamp with time zone NOT NULL DEFAULT timezone('utc'::text, now()),
  updated_at timestamp with time zone NOT NULL DEFAULT timezone('utc'::text, now()),
  booking_type text CHECK (booking_type = ANY (ARRAY['ride'::text, 'parcel'::text])),
  expires_at timestamp with time zone DEFAULT (now() + '24:00:00'::interval),
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  expiry_reason text CHECK (expiry_reason = ANY (ARRAY['negotiation_timeout'::text, 'travel_date_passed'::text, 'no_show'::text])),
  CONSTRAINT intercity_requests_pkey PRIMARY KEY (id),
  CONSTRAINT intercity_requests_parcel_id_fkey FOREIGN KEY (parcel_id) REFERENCES public.orders(id),
  CONSTRAINT intercity_requests_route_id_fkey FOREIGN KEY (route_id) REFERENCES public.rider_travel_plans(id),
  CONSTRAINT intercity_requests_traveller_id_fkey FOREIGN KEY (traveller_id) REFERENCES public.riders(id),
  CONSTRAINT intercity_requests_sender_id_fkey FOREIGN KEY (sender_id) REFERENCES public.users(id)
);
CREATE TABLE public.parcel_security_logs (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL,
  sender_user_id uuid NOT NULL,
  rider_id uuid,
  event_type text NOT NULL,
  photo_url text,
  latitude double precision,
  longitude double precision,
  ip_address inet,
  device_id text,
  metadata jsonb DEFAULT '{}'::jsonb,
  created_at timestamp with time zone DEFAULT now(),
  event_latitude numeric,
  event_longitude numeric,
  CONSTRAINT parcel_security_logs_pkey PRIMARY KEY (id),
  CONSTRAINT parcel_security_logs_order_id_fkey FOREIGN KEY (order_id) REFERENCES public.orders(id),
  CONSTRAINT parcel_security_logs_sender_user_id_fkey FOREIGN KEY (sender_user_id) REFERENCES public.users(id),
  CONSTRAINT parcel_security_logs_rider_id_fkey FOREIGN KEY (rider_id) REFERENCES public.riders(id)
);
CREATE TABLE public.order_declarations (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL,
  user_id uuid NOT NULL,
  declaration_text text NOT NULL,
  accepted boolean NOT NULL,
  accepted_ip inet,
  accepted_device_id text,
  accepted_at timestamp with time zone DEFAULT now(),
  declaration_version text DEFAULT '1.0'::text,
  accepted_device_ref text,
  CONSTRAINT order_declarations_pkey PRIMARY KEY (id),
  CONSTRAINT order_declarations_order_id_fkey FOREIGN KEY (order_id) REFERENCES public.orders(id),
  CONSTRAINT order_declarations_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id)
);
CREATE TABLE public.police_sos_logs (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL,
  rider_id uuid NOT NULL,
  opened_at timestamp with time zone DEFAULT now(),
  latitude double precision,
  longitude double precision,
  notes text,
  police_reference_code text UNIQUE,
  support_ticket_code text UNIQUE,
  rider_lat numeric,
  rider_lng numeric,
  CONSTRAINT police_sos_logs_pkey PRIMARY KEY (id),
  CONSTRAINT police_sos_logs_order_id_fkey FOREIGN KEY (order_id) REFERENCES public.orders(id),
  CONSTRAINT police_sos_logs_rider_id_fkey FOREIGN KEY (rider_id) REFERENCES public.riders(id)
);
CREATE TABLE public.order_parcel_photos (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL,
  rider_id uuid NOT NULL,
  photo_url text NOT NULL,
  latitude numeric,
  longitude numeric,
  captured_at timestamp with time zone DEFAULT now(),
  photo_type text NOT NULL DEFAULT 'pickup'::text CHECK (photo_type = ANY (ARRAY['pickup'::text, 'dropoff'::text, 'damage'::text, 'evidence'::text, 'rider_selfie'::text])),
  file_sha256 text,
  CONSTRAINT order_parcel_photos_pkey PRIMARY KEY (id),
  CONSTRAINT order_parcel_photos_order_id_fkey FOREIGN KEY (order_id) REFERENCES public.orders(id),
  CONSTRAINT order_parcel_photos_rider_id_fkey FOREIGN KEY (rider_id) REFERENCES public.riders(id)
);
CREATE TABLE public.parcel_compliance_reports (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL,
  generated_for text,
  generated_at timestamp with time zone DEFAULT now(),
  report_json jsonb NOT NULL,
  generated_by uuid,
  CONSTRAINT parcel_compliance_reports_pkey PRIMARY KEY (id),
  CONSTRAINT parcel_compliance_reports_order_id_fkey FOREIGN KEY (order_id) REFERENCES public.orders(id),
  CONSTRAINT parcel_compliance_reports_generated_by_fkey FOREIGN KEY (generated_by) REFERENCES public.users(id)
);
CREATE TABLE public.user_devices (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  device_id text NOT NULL UNIQUE,
  device_ref text NOT NULL UNIQUE,
  device_model text,
  device_brand text,
  os_version text,
  app_version text,
  last_ip_address inet,
  last_seen_at timestamp with time zone DEFAULT now(),
  created_at timestamp with time zone DEFAULT now(),
  updated_at timestamp with time zone DEFAULT now(),
  is_active boolean DEFAULT true,
  CONSTRAINT user_devices_pkey PRIMARY KEY (id),
  CONSTRAINT user_devices_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id)
);
CREATE TABLE public.distance_discounts (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  km_5_discount numeric NOT NULL DEFAULT 0 CHECK (km_5_discount >= 0::numeric AND km_5_discount <= 100::numeric),
  km_10_discount numeric NOT NULL DEFAULT 0 CHECK (km_10_discount >= 0::numeric AND km_10_discount <= 100::numeric),
  km_15_discount numeric NOT NULL DEFAULT 0 CHECK (km_15_discount >= 0::numeric AND km_15_discount <= 100::numeric),
  km_20_discount numeric NOT NULL DEFAULT 0 CHECK (km_20_discount >= 0::numeric AND km_20_discount <= 100::numeric),
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  updated_at timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT distance_discounts_pkey PRIMARY KEY (id)
);
CREATE TABLE public.wallet_transactions (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  rider_id uuid NOT NULL,
  amount numeric NOT NULL,
  type character varying NOT NULL CHECK (type::text = ANY (ARRAY['credit'::character varying, 'debit'::character varying, 'bonus'::character varying, 'settlement'::character varying, 'adjustment'::character varying]::text[])),
  reference_id uuid NOT NULL,
  reference_type character varying NOT NULL CHECK (reference_type::text = ANY (ARRAY['order'::character varying, 'withdrawal'::character varying, 'settlement'::character varying, 'bonus'::character varying]::text[])),
  description text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT wallet_transactions_pkey PRIMARY KEY (id),
  CONSTRAINT wallet_transactions_rider_id_fkey FOREIGN KEY (rider_id) REFERENCES public.riders(id)
);
CREATE TABLE public.wallet_audit_logs (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  run_at timestamp with time zone DEFAULT now(),
  discrepancies_found integer NOT NULL,
  details jsonb,
  CONSTRAINT wallet_audit_logs_pkey PRIMARY KEY (id)
);
CREATE TABLE public.promo_codes (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  code character varying NOT NULL UNIQUE,
  discount_type character varying NOT NULL CHECK (discount_type::text = ANY (ARRAY['percentage'::character varying, 'fixed_amount'::character varying]::text[])),
  discount_value numeric NOT NULL,
  max_discount numeric,
  min_order_value numeric DEFAULT 0.00,
  expires_at timestamp with time zone NOT NULL,
  max_uses integer,
  uses_count integer DEFAULT 0,
  is_active boolean DEFAULT true,
  audience_type character varying NOT NULL DEFAULT 'everyone'::character varying CHECK (audience_type::text = ANY (ARRAY['everyone'::character varying, 'restricted'::character varying]::text[])),
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT promo_codes_pkey PRIMARY KEY (id)
);
CREATE TABLE public.promo_code_users (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  promo_code_id uuid NOT NULL,
  user_id uuid NOT NULL,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT promo_code_users_pkey PRIMARY KEY (id),
  CONSTRAINT promo_code_users_promo_code_id_fkey FOREIGN KEY (promo_code_id) REFERENCES public.promo_codes(id),
  CONSTRAINT promo_code_users_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id)
);
CREATE TABLE public.user_promo_usages (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  promo_code_id uuid NOT NULL,
  used_at timestamp with time zone DEFAULT now(),
  order_id uuid,
  CONSTRAINT user_promo_usages_pkey PRIMARY KEY (id),
  CONSTRAINT user_promo_usages_promo_code_id_fkey FOREIGN KEY (promo_code_id) REFERENCES public.promo_codes(id),
  CONSTRAINT user_promo_usages_order_id_fkey FOREIGN KEY (order_id) REFERENCES public.orders(id)
);
CREATE TABLE public.rider_daily_activity (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  rider_id uuid NOT NULL,
  date date NOT NULL DEFAULT CURRENT_DATE,
  online_seconds integer NOT NULL DEFAULT 0,
  active_seconds integer NOT NULL DEFAULT 0,
  completed_orders integer DEFAULT 0,
  cancelled_orders integer DEFAULT 0,
  earnings numeric DEFAULT 0.0,
  last_online_toggle_at timestamp with time zone,
  created_at timestamp with time zone DEFAULT now(),
  updated_at timestamp with time zone DEFAULT now(),
  CONSTRAINT rider_daily_activity_pkey PRIMARY KEY (id),
  CONSTRAINT rider_daily_activity_rider_id_fkey FOREIGN KEY (rider_id) REFERENCES public.riders(id)
);
CREATE TABLE public.notifications (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  title text NOT NULL,
  body text NOT NULL,
  notification_type text NOT NULL,
  reference_id uuid,
  reference_type text,
  is_read boolean NOT NULL DEFAULT false,
  push_sent boolean NOT NULL DEFAULT false,
  delivery_status text NOT NULL DEFAULT 'pending'::text,
  delivery_error text,
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  read_at timestamp with time zone,
  CONSTRAINT notifications_pkey PRIMARY KEY (id),
  CONSTRAINT notifications_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id)
);
CREATE TABLE public.order_verifications (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL,
  verification_type text NOT NULL CHECK (verification_type = ANY (ARRAY['pickup'::text, 'dropoff'::text, 'damage_report'::text, 'signature'::text])),
  verification_status text NOT NULL DEFAULT 'verified'::text CHECK (verification_status = ANY (ARRAY['verified'::text, 'bypassed'::text, 'pending_sync'::text, 'failed'::text])),
  photo_url text,
  latitude numeric,
  longitude numeric,
  metadata jsonb DEFAULT '{}'::jsonb,
  created_by uuid,
  created_at timestamp with time zone NOT NULL DEFAULT timezone('utc'::text, now()),
  CONSTRAINT order_verifications_pkey PRIMARY KEY (id),
  CONSTRAINT order_verifications_order_id_fkey FOREIGN KEY (order_id) REFERENCES public.orders(id),
  CONSTRAINT order_verifications_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id)
);

table_name,constraint_name,constraint_type,column_name,foreign_table,foreign_column
admin_logs,2200_17682_3_not_null,CHECK,null,null,null
admin_logs,2200_17682_5_not_null,CHECK,null,null,null
admin_logs,admin_logs_admin_id_fkey,FOREIGN KEY,admin_id,admins,id
admin_logs,admin_logs_pkey,PRIMARY KEY,id,admin_logs,id
admin_logs,2200_17682_4_not_null,CHECK,null,null,null
admin_logs,2200_17682_1_not_null,CHECK,null,null,null
admin_logs,2200_17682_2_not_null,CHECK,null,null,null
admins,2200_17664_6_not_null,CHECK,null,null,null
admins,2200_17664_2_not_null,CHECK,null,null,null
admins,2200_17664_5_not_null,CHECK,null,null,null
admins,admins_admin_code_key,UNIQUE,admin_code,admins,admin_code
admins,2200_17664_8_not_null,CHECK,null,null,null
admins,2200_17664_7_not_null,CHECK,null,null,null
admins,2200_17664_4_not_null,CHECK,null,null,null
admins,2200_17664_3_not_null,CHECK,null,null,null
admins,admins_phone_key,UNIQUE,phone,admins,phone
admins,admins_email_key,UNIQUE,email,admins,email
admins,admins_pkey,PRIMARY KEY,id,admins,id
admins,2200_17664_1_not_null,CHECK,null,null,null
dispatch_config,2200_18160_6_not_null,CHECK,null,null,null
dispatch_config,2200_18160_4_not_null,CHECK,null,null,null
dispatch_config,2200_18160_5_not_null,CHECK,null,null,null
dispatch_config,2200_18160_12_not_null,CHECK,null,null,null
dispatch_config,dispatch_config_updated_by_admin_id_fkey,FOREIGN KEY,updated_by_admin_id,admins,id
dispatch_config,2200_18160_11_not_null,CHECK,null,null,null
dispatch_config,2200_18160_14_not_null,CHECK,null,null,null
dispatch_config,dispatch_config_config_code_key,UNIQUE,config_code,dispatch_config,config_code
dispatch_config,dispatch_config_pkey,PRIMARY KEY,id,dispatch_config,id
dispatch_config,2200_18160_3_not_null,CHECK,null,null,null
dispatch_config,2200_18160_2_not_null,CHECK,null,null,null
dispatch_config,2200_18160_8_not_null,CHECK,null,null,null
dispatch_config,2200_18160_9_not_null,CHECK,null,null,null
dispatch_config,2200_18160_13_not_null,CHECK,null,null,null
dispatch_config,2200_18160_10_not_null,CHECK,null,null,null
dispatch_config,2200_18160_1_not_null,CHECK,null,null,null
dispatch_config,2200_18160_7_not_null,CHECK,null,null,null
distance_discounts,2200_26374_4_not_null,CHECK,null,null,null
distance_discounts,2200_26374_2_not_null,CHECK,null,null,null
distance_discounts,2200_26374_5_not_null,CHECK,null,null,null
distance_discounts,2200_26374_3_not_null,CHECK,null,null,null
distance_discounts,km_15_discount_range,CHECK,null,distance_discounts,km_15_discount
distance_discounts,km_20_discount_range,CHECK,null,distance_discounts,km_20_discount
distance_discounts,km_10_discount_range,CHECK,null,distance_discounts,km_10_discount
distance_discounts,km_5_discount_range,CHECK,null,distance_discounts,km_5_discount
distance_discounts,2200_26374_7_not_null,CHECK,null,null,null
distance_discounts,distance_discounts_pkey,PRIMARY KEY,id,distance_discounts,id
distance_discounts,2200_26374_1_not_null,CHECK,null,null,null
distance_discounts,2200_26374_8_not_null,CHECK,null,null,null
distance_discounts,2200_26374_6_not_null,CHECK,null,null,null
intercity_requests,intercity_requests_sender_id_fkey,FOREIGN KEY,sender_id,users,id
intercity_requests,2200_25000_6_not_null,CHECK,null,null,null
intercity_requests,2200_25000_15_not_null,CHECK,null,null,null
intercity_requests,2200_25000_5_not_null,CHECK,null,null,null
intercity_requests,2200_25000_4_not_null,CHECK,null,null,null
intercity_requests,2200_25000_9_not_null,CHECK,null,null,null
intercity_requests,2200_25000_10_not_null,CHECK,null,null,null
intercity_requests,2200_25000_11_not_null,CHECK,null,null,null
intercity_requests,intercity_requests_status_check,CHECK,null,intercity_requests,status
intercity_requests,2200_25000_12_not_null,CHECK,null,null,null
intercity_requests,intercity_requests_traveller_id_fkey,FOREIGN KEY,traveller_id,riders,id
intercity_requests,intercity_requests_initiated_by_check,CHECK,null,intercity_requests,initiated_by
intercity_requests,intercity_requests_parcel_id_fkey,FOREIGN KEY,parcel_id,orders,id
intercity_requests,2200_25000_7_not_null,CHECK,null,null,null
intercity_requests,intercity_requests_expiry_reason_check,CHECK,null,intercity_requests,expiry_reason
intercity_requests,intercity_requests_pkey,PRIMARY KEY,id,intercity_requests,id
intercity_requests,intercity_requests_route_id_fkey,FOREIGN KEY,route_id,rider_travel_plans,id
intercity_requests,2200_25000_1_not_null,CHECK,null,null,null
intercity_requests,2200_25000_8_not_null,CHECK,null,null,null
intercity_requests,intercity_requests_booking_type_check,CHECK,null,intercity_requests,booking_type
intercity_requests,2200_25000_2_not_null,CHECK,null,null,null
notifications,notifications_user_id_fkey,FOREIGN KEY,user_id,users,id
notifications,notifications_pkey,PRIMARY KEY,id,notifications,id
notifications,2200_26799_12_not_null,CHECK,null,null,null
notifications,2200_26799_13_not_null,CHECK,null,null,null
notifications,2200_26799_5_not_null,CHECK,null,null,null
notifications,2200_26799_8_not_null,CHECK,null,null,null
notifications,2200_26799_4_not_null,CHECK,null,null,null
notifications,2200_26799_9_not_null,CHECK,null,null,null
notifications,2200_26799_1_not_null,CHECK,null,null,null
notifications,2200_26799_2_not_null,CHECK,null,null,null
notifications,2200_26799_3_not_null,CHECK,null,null,null
notifications,2200_26799_10_not_null,CHECK,null,null,null
order_assignment_logs,unique_order_rider_assignment,UNIQUE,assignment_round,order_assignment_logs,assignment_round
order_assignment_logs,2200_18130_3_not_null,CHECK,null,null,null
order_assignment_logs,unique_order_rider_assignment,UNIQUE,assignment_round,order_assignment_logs,order_id
order_assignment_logs,2200_18130_2_not_null,CHECK,null,null,null
order_assignment_logs,2200_18130_4_not_null,CHECK,null,null,null
order_assignment_logs,unique_order_rider_assignment,UNIQUE,assignment_round,order_assignment_logs,rider_id
order_assignment_logs,unique_order_rider_assignment,UNIQUE,rider_id,order_assignment_logs,order_id
order_assignment_logs,order_assignment_logs_pkey,PRIMARY KEY,id,order_assignment_logs,id
order_assignment_logs,order_assignment_logs_order_id_fkey,FOREIGN KEY,order_id,orders,id
order_assignment_logs,unique_order_rider_assignment,UNIQUE,rider_id,order_assignment_logs,rider_id
order_assignment_logs,2200_18130_1_not_null,CHECK,null,null,null
order_assignment_logs,unique_order_rider_assignment,UNIQUE,rider_id,order_assignment_logs,assignment_round
order_assignment_logs,unique_order_rider_assignment,UNIQUE,order_id,order_assignment_logs,rider_id
order_assignment_logs,order_assignment_logs_rider_id_fkey,FOREIGN KEY,rider_id,riders,id
order_assignment_logs,unique_order_rider_assignment,UNIQUE,order_id,order_assignment_logs,assignment_round
order_assignment_logs,unique_order_rider_assignment,UNIQUE,order_id,order_assignment_logs,order_id
order_chat_messages,2200_24175_1_not_null,CHECK,null,null,null
order_chat_messages,2200_24175_4_not_null,CHECK,null,null,null

table_name,ordinal_position,column_name,data_type,udt_name,is_nullable,column_default
admin_logs,1,id,uuid,uuid,NO,gen_random_uuid()
admin_logs,2,admin_id,uuid,uuid,NO,null
admin_logs,3,action_type,text,text,NO,null
admin_logs,4,target_type,text,text,NO,null
admin_logs,5,target_id,uuid,uuid,NO,null
admin_logs,6,description,text,text,YES,null
admin_logs,7,metadata,jsonb,jsonb,YES,'{}'::jsonb
admin_logs,8,ip_address,text,text,YES,null
admin_logs,9,user_agent,text,text,YES,null
admin_logs,10,created_at,timestamp with time zone,timestamptz,YES,now()
admins,1,id,uuid,uuid,NO,gen_random_uuid()
admins,2,admin_code,text,text,NO,null
admins,3,name,text,text,NO,null
admins,4,phone,text,text,NO,null
admins,5,email,text,text,NO,null
admins,6,password_hash,text,text,NO,null
admins,7,role,text,text,NO,null
admins,8,permissions,jsonb,jsonb,NO,'{}'::jsonb
admins,9,is_active,boolean,bool,YES,true
admins,10,is_account_locked,boolean,bool,YES,false
admins,11,last_login_at,timestamp with time zone,timestamptz,YES,null
admins,12,created_at,timestamp with time zone,timestamptz,YES,now()
dispatch_config,1,id,uuid,uuid,NO,gen_random_uuid()
dispatch_config,2,config_code,text,text,NO,null
dispatch_config,3,round_1_radius_km,numeric,numeric,NO,3
dispatch_config,4,round_1_batch_size,integer,int4,NO,3
dispatch_config,5,round_2_radius_km,numeric,numeric,NO,6
dispatch_config,6,round_2_batch_size,integer,int4,NO,5
dispatch_config,7,round_3_radius_km,numeric,numeric,NO,10
dispatch_config,8,round_3_batch_size,integer,int4,NO,8
dispatch_config,9,rider_response_timeout_sec,integer,int4,NO,25
dispatch_config,10,max_search_duration_sec,integer,int4,NO,900
dispatch_config,11,reject_cooldown_sec,integer,int4,NO,600
dispatch_config,12,timeout_cooldown_sec,integer,int4,NO,120
dispatch_config,13,rider_location_stale_sec,integer,int4,NO,30
dispatch_config,14,max_active_orders_per_rider,integer,int4,NO,1
dispatch_config,15,allow_round_3,boolean,bool,YES,true
dispatch_config,16,allow_boosted_priority,boolean,bool,YES,true
dispatch_config,17,is_active,boolean,bool,YES,true
dispatch_config,18,updated_by_admin_id,uuid,uuid,YES,null
dispatch_config,19,created_at,timestamp with time zone,timestamptz,YES,now()
dispatch_config,20,updated_at,timestamp with time zone,timestamptz,YES,now()
dispatch_config,21,round_2_trigger_if_no_riders_sec,integer,int4,YES,60
dispatch_config,22,round_2_trigger_after_sec,integer,int4,YES,300
dispatch_config,23,round_3_trigger_after_sec,integer,int4,YES,600
distance_discounts,1,id,uuid,uuid,NO,gen_random_uuid()
distance_discounts,2,km_5_discount,numeric,numeric,NO,0
distance_discounts,3,km_10_discount,numeric,numeric,NO,0
distance_discounts,4,km_15_discount,numeric,numeric,NO,0
distance_discounts,5,km_20_discount,numeric,numeric,NO,0
distance_discounts,6,is_active,boolean,bool,NO,true
distance_discounts,7,created_at,timestamp with time zone,timestamptz,NO,now()
distance_discounts,8,updated_at,timestamp with time zone,timestamptz,NO,now()
intercity_requests,1,id,uuid,uuid,NO,gen_random_uuid()
intercity_requests,2,parcel_id,uuid,uuid,NO,null
intercity_requests,3,route_id,uuid,uuid,YES,null
intercity_requests,4,traveller_id,uuid,uuid,NO,null
intercity_requests,5,sender_id,uuid,uuid,NO,null
intercity_requests,6,initiated_by,text,text,NO,null
intercity_requests,7,status,text,text,NO,'request_sent'::text
intercity_requests,8,proposed_fare,numeric,numeric,NO,null
intercity_requests,9,sender_confirmed,boolean,bool,NO,false
intercity_requests,10,traveller_confirmed,boolean,bool,NO,false
intercity_requests,11,created_at,timestamp with time zone,timestamptz,NO,"timezone('utc'::text, now())"
intercity_requests,12,updated_at,timestamp with time zone,timestamptz,NO,"timezone('utc'::text, now())"
intercity_requests,13,booking_type,text,text,YES,null
intercity_requests,14,expires_at,timestamp with time zone,timestamptz,YES,(now() + '24:00:00'::interval)
intercity_requests,15,metadata,jsonb,jsonb,NO,'{}'::jsonb
intercity_requests,16,expiry_reason,text,text,YES,null
notifications,1,id,uuid,uuid,NO,gen_random_uuid()
notifications,2,user_id,uuid,uuid,NO,null
notifications,3,title,text,text,NO,null
notifications,4,body,text,text,NO,null
notifications,5,notification_type,text,text,NO,null
notifications,6,reference_id,uuid,uuid,YES,null
notifications,7,reference_type,text,text,YES,null
notifications,8,is_read,boolean,bool,NO,false
notifications,9,push_sent,boolean,bool,NO,false
notifications,10,delivery_status,text,text,NO,'pending'::text
notifications,11,delivery_error,text,text,YES,null
notifications,12,payload,jsonb,jsonb,NO,'{}'::jsonb
notifications,13,created_at,timestamp with time zone,timestamptz,NO,now()
notifications,14,read_at,timestamp with time zone,timestamptz,YES,null
order_assignment_logs,1,id,uuid,uuid,NO,gen_random_uuid()
order_assignment_logs,2,order_id,uuid,uuid,NO,null
order_assignment_logs,3,rider_id,uuid,uuid,NO,null
order_assignment_logs,4,assignment_status,USER-DEFINED,intercity_assignment_status_enum,NO,'sent'::intercity_assignment_status_enum
order_assignment_logs,5,assignment_round,integer,int4,YES,1
order_assignment_logs,6,rider_distance_km,numeric,numeric,YES,null
order_assignment_logs,7,estimated_pickup_time_min,integer,int4,YES,null
order_assignment_logs,8,sent_at,timestamp with time zone,timestamptz,YES,now()
order_assignment_logs,9,viewed_at,timestamp with time zone,timestamptz,YES,null
order_assignment_logs,10,responded_at,timestamp with time zone,timestamptz,YES,null
order_assignment_logs,11,rejection_reason,text,text,YES,null
order_assignment_logs,12,metadata,jsonb,jsonb,YES,'{}'::jsonb
order_assignment_logs,13,created_at,timestamp with time zone,timestamptz,YES,now()
order_chat_messages,1,id,uuid,uuid,NO,gen_random_uuid()
order_chat_messages,2,order_id,uuid,uuid,YES,null
order_chat_messages,3,rider_id,uuid,uuid,YES,null
order_chat_messages,4,sender_id,uuid,uuid,NO,null

table_name,column_name,foreign_table,foreign_column
admin_logs,admin_id,admins,id
dispatch_config,updated_by_admin_id,admins,id
intercity_requests,route_id,rider_travel_plans,id
intercity_requests,sender_id,users,id
intercity_requests,traveller_id,riders,id
intercity_requests,parcel_id,orders,id
notifications,user_id,users,id
order_assignment_logs,rider_id,riders,id
order_assignment_logs,order_id,orders,id
order_chat_messages,user_id,users,id
order_chat_messages,order_id,orders,id
order_chat_messages,rider_id,riders,id
order_declarations,user_id,users,id
order_declarations,order_id,orders,id
order_parcel_photos,rider_id,riders,id
order_parcel_photos,order_id,orders,id
order_status_history,changed_by_admin_id,admins,id
order_status_history,changed_by_rider_id,riders,id
order_status_history,order_id,orders,id
order_status_history,changed_by_user_id,users,id
order_verifications,order_id,orders,id
orders,pricing_config_id,pricing_config,id
orders,user_id,users,id
orders,rider_id,riders,id
orders,payment_id,payments,id
orders,created_device_record_id,user_devices,id
parcel_compliance_reports,generated_by,users,id
parcel_compliance_reports,order_id,orders,id
parcel_security_logs,rider_id,riders,id
parcel_security_logs,order_id,orders,id
parcel_security_logs,sender_user_id,users,id
payments,rider_id,riders,id
payments,user_id,users,id
police_sos_logs,order_id,orders,id
police_sos_logs,rider_id,riders,id
pricing_change_logs,changed_by_admin_id,admins,id
pricing_change_logs,pricing_config_id,pricing_config,id
pricing_config,approved_by_admin_id,admins,id
pricing_config,created_by_admin_id,admins,id
pricing_config,pricing_zone_id,pricing_zones,id
promo_code_users,promo_code_id,promo_codes,id
promo_code_users,user_id,users,id
rider_assignments,order_id,orders,id
rider_assignments,rider_id,riders,id
rider_daily_activity,rider_id,riders,id
rider_kyc,user_id,users,id
rider_kyc,handled_by_admin_id,admins,id
rider_payout_accounts,user_id,users,id
rider_payout_accounts,rider_id,riders,id
rider_payout_updates_log,user_id,users,id
rider_reviews,order_id,orders,id
rider_reviews,rider_id,riders,id
rider_subscription_history,rider_id,riders,id
rider_subscription_history,payment_id,payments,id
rider_travel_plans,rider_id,riders,id
rider_withdrawal_events,withdrawal_id,rider_withdrawals,id
rider_withdrawals,user_id,users,id
rider_withdrawals,rider_id,riders,id
riders,user_id,users,id
riders,kyc_id,rider_kyc,id
user_device_tokens,user_device_id,user_devices,id
user_devices,user_id,users,id
user_promo_usages,promo_code_id,promo_codes,id
user_promo_usages,order_id,orders,id
wallet_transactions,rider_id,riders,id

schemaname,tablename,indexname,indexdef
public,admin_logs,admin_logs_pkey,CREATE UNIQUE INDEX admin_logs_pkey ON public.admin_logs USING btree (id)
public,admin_logs,idx_admin_logs_created_at,CREATE INDEX idx_admin_logs_created_at ON public.admin_logs USING btree (created_at DESC)
public,admin_logs,idx_admin_logs_action_type,CREATE INDEX idx_admin_logs_action_type ON public.admin_logs USING btree (action_type)
public,admin_logs,idx_admin_logs_target_id,CREATE INDEX idx_admin_logs_target_id ON public.admin_logs USING btree (target_id)
public,admin_logs,idx_admin_logs_admin_id,CREATE INDEX idx_admin_logs_admin_id ON public.admin_logs USING btree (admin_id)
public,admins,admins_email_key,CREATE UNIQUE INDEX admins_email_key ON public.admins USING btree (email)
public,admins,admins_pkey,CREATE UNIQUE INDEX admins_pkey ON public.admins USING btree (id)
public,admins,admins_admin_code_key,CREATE UNIQUE INDEX admins_admin_code_key ON public.admins USING btree (admin_code)
public,admins,admins_phone_key,CREATE UNIQUE INDEX admins_phone_key ON public.admins USING btree (phone)
public,dispatch_config,dispatch_config_pkey,CREATE UNIQUE INDEX dispatch_config_pkey ON public.dispatch_config USING btree (id)
public,dispatch_config,dispatch_config_config_code_key,CREATE UNIQUE INDEX dispatch_config_config_code_key ON public.dispatch_config USING btree (config_code)
public,distance_discounts,idx_distance_discounts_active,CREATE UNIQUE INDEX idx_distance_discounts_active ON public.distance_discounts USING btree (is_active) WHERE (is_active = true)
public,distance_discounts,distance_discounts_pkey,CREATE UNIQUE INDEX distance_discounts_pkey ON public.distance_discounts USING btree (id)
public,intercity_requests,intercity_requests_pkey,CREATE UNIQUE INDEX intercity_requests_pkey ON public.intercity_requests USING btree (id)
public,notifications,notifications_pkey,CREATE UNIQUE INDEX notifications_pkey ON public.notifications USING btree (id)
public,order_assignment_logs,idx_order_assignment_logs_sent_at,CREATE INDEX idx_order_assignment_logs_sent_at ON public.order_assignment_logs USING btree (sent_at DESC)
public,order_assignment_logs,order_assignment_logs_pkey,CREATE UNIQUE INDEX order_assignment_logs_pkey ON public.order_assignment_logs USING btree (id)
public,order_assignment_logs,idx_order_assignment_logs_order_id,CREATE INDEX idx_order_assignment_logs_order_id ON public.order_assignment_logs USING btree (order_id)
public,order_assignment_logs,idx_order_assignment_logs_assignment_status,CREATE INDEX idx_order_assignment_logs_assignment_status ON public.order_assignment_logs USING btree (assignment_status)
public,order_assignment_logs,unique_order_rider_assignment,"CREATE UNIQUE INDEX unique_order_rider_assignment ON public.order_assignment_logs USING btree (order_id, rider_id, assignment_round)"
public,order_assignment_logs,idx_order_assignment_logs_rider_id,CREATE INDEX idx_order_assignment_logs_rider_id ON public.order_assignment_logs USING btree (rider_id)
public,order_assignment_logs,idx_order_assignment_logs_assignment_round,CREATE INDEX idx_order_assignment_logs_assignment_round ON public.order_assignment_logs USING btree (assignment_round)
public,order_chat_messages,order_chat_messages_pkey,CREATE UNIQUE INDEX order_chat_messages_pkey ON public.order_chat_messages USING btree (id)
public,order_declarations,order_declarations_pkey,CREATE UNIQUE INDEX order_declarations_pkey ON public.order_declarations USING btree (id)
public,order_parcel_photos,order_parcel_photos_pkey,CREATE UNIQUE INDEX order_parcel_photos_pkey ON public.order_parcel_photos USING btree (id)
public,order_status_history,idx_order_status_history_created_at,CREATE INDEX idx_order_status_history_created_at ON public.order_status_history USING btree (created_at DESC)
public,order_status_history,order_status_history_pkey,CREATE UNIQUE INDEX order_status_history_pkey ON public.order_status_history USING btree (id)
public,order_status_history,idx_order_status_history_order_id,CREATE INDEX idx_order_status_history_order_id ON public.order_status_history USING btree (order_id)
public,order_status_history,idx_order_status_history_new_status,CREATE INDEX idx_order_status_history_new_status ON public.order_status_history USING btree (new_status)
public,order_verifications,order_verifications_pkey,CREATE UNIQUE INDEX order_verifications_pkey ON public.order_verifications USING btree (id)
public,orders,idx_orders_pickup_location,"CREATE INDEX idx_orders_pickup_location ON public.orders USING btree (pickup_lat, pickup_lng)"
public,orders,idx_orders_destination_location,"CREATE INDEX idx_orders_destination_location ON public.orders USING btree (destination_lat, destination_lng)"
public,orders,idx_orders_created_at,CREATE INDEX idx_orders_created_at ON public.orders USING btree (created_at DESC)
public,orders,idx_orders_search_expires_at,CREATE INDEX idx_orders_search_expires_at ON public.orders USING btree (search_expires_at)
public,orders,orders_order_code_key,CREATE UNIQUE INDEX orders_order_code_key ON public.orders USING btree (order_code)
public,orders,idx_orders_payment_status,CREATE INDEX idx_orders_payment_status ON public.orders USING btree (payment_status)
public,orders,idx_orders_order_status,CREATE INDEX idx_orders_order_status ON public.orders USING btree (order_status)
public,orders,idx_orders_vehicle_type,CREATE INDEX idx_orders_vehicle_type ON public.orders USING btree (vehicle_type)
public,orders,orders_pkey,CREATE UNIQUE INDEX orders_pkey ON public.orders USING btree (id)
public,orders,idx_orders_user_id,CREATE INDEX idx_orders_user_id ON public.orders USING btree (user_id)
public,orders,idx_orders_rider_id,CREATE INDEX idx_orders_rider_id ON public.orders USING btree (rider_id)
public,orders,idx_orders_order_type,CREATE INDEX idx_orders_order_type ON public.orders USING btree (order_type)
public,orders,idx_orders_order_code,CREATE INDEX idx_orders_order_code ON public.orders USING btree (order_code)
public,orders,idx_orders_payment_id,CREATE INDEX idx_orders_payment_id ON public.orders USING btree (payment_id)
public,orders,idx_orders_pricing_config_id,CREATE INDEX idx_orders_pricing_config_id ON public.orders USING btree (pricing_config_id)
public,parcel_compliance_reports,parcel_compliance_reports_pkey,CREATE UNIQUE INDEX parcel_compliance_reports_pkey ON public.parcel_compliance_reports USING btree (id)
public,parcel_security_logs,parcel_security_logs_pkey,CREATE UNIQUE INDEX parcel_security_logs_pkey ON public.parcel_security_logs USING btree (id)
public,payments,idx_payments_user_id,CREATE INDEX idx_payments_user_id ON public.payments USING btree (user_id)
public,payments,idx_unique_gateway_txn,CREATE UNIQUE INDEX idx_unique_gateway_txn ON public.payments USING btree (gateway_transaction_id)
public,payments,idx_payments_payment_status,CREATE INDEX idx_payments_payment_status ON public.payments USING btree (payment_status)
public,payments,idx_payments_reference_id,CREATE INDEX idx_payments_reference_id ON public.payments USING btree (reference_id)
public,payments,idx_payments_rider_id,CREATE INDEX idx_payments_rider_id ON public.payments USING btree (rider_id)
public,payments,payments_pkey,CREATE UNIQUE INDEX payments_pkey ON public.payments USING btree (id)
public,payments,idx_unique_pending_payment,"CREATE UNIQUE INDEX idx_unique_pending_payment ON public.payments USING btree (user_id, payment_for, reference_id) WHERE (payment_status = 'pending'::payment_status_enum)"
public,payments,payments_payment_code_key,CREATE UNIQUE INDEX payments_payment_code_key ON public.payments USING btree (payment_code)
public,payments,idx_payments_created_at,CREATE INDEX idx_payments_created_at ON public.payments USING btree (created_at DESC)
public,police_sos_logs,police_sos_logs_support_ticket_code_key,CREATE UNIQUE INDEX police_sos_logs_support_ticket_code_key ON public.police_sos_logs USING btree (support_ticket_code)
public,police_sos_logs,police_sos_logs_pkey,CREATE UNIQUE INDEX police_sos_logs_pkey ON public.police_sos_logs USING btree (id)
public,police_sos_logs,police_sos_logs_police_reference_code_key,CREATE UNIQUE INDEX police_sos_logs_police_reference_code_key ON public.police_sos_logs USING btree (police_reference_code)
public,pricing_change_logs,idx_pricing_change_logs_changed_by_admin_id,CREATE INDEX idx_pricing_change_logs_changed_by_admin_id ON public.pricing_change_logs USING btree (changed_by_admin_id)
public,pricing_change_logs,idx_pricing_change_logs_created_at,CREATE INDEX idx_pricing_change_logs_created_at ON public.pricing_change_logs USING btree (created_at DESC)
public,pricing_change_logs,pricing_change_logs_pkey,CREATE UNIQUE INDEX pricing_change_logs_pkey ON public.pricing_change_logs USING btree (id)
public,pricing_change_logs,idx_pricing_change_logs_pricing_config_id,CREATE INDEX idx_pricing_change_logs_pricing_config_id ON public.pricing_change_logs USING btree (pricing_config_id)
public,pricing_config,pricing_config_pricing_code_key,CREATE UNIQUE INDEX pricing_config_pricing_code_key ON public.pricing_config USING btree (pricing_code)
public,pricing_config,idx_pricing_config_created_at,CREATE INDEX idx_pricing_config_created_at ON public.pricing_config USING btree (created_at DESC)
public,pricing_config,unique_active_pricing_config,"CREATE UNIQUE INDEX unique_active_pricing_config ON public.pricing_config USING btree (service_type, COALESCE(vehicle_type, ''::text), COALESCE((pricing_zone_id)::text, ''::text)) WHERE (is_active = true)"
public,pricing_config,idx_pricing_config_approval_status,CREATE INDEX idx_pricing_config_approval_status ON public.pricing_config USING btree (approval_status)
public,pricing_config,idx_pricing_config_is_active,CREATE INDEX idx_pricing_config_is_active ON public.pricing_config USING btree (is_active)
public,pricing_config,idx_pricing_config_city_tier,CREATE INDEX idx_pricing_config_city_tier ON public.pricing_config USING btree (city_tier)
public,pricing_config,idx_pricing_config_vehicle_type,CREATE INDEX idx_pricing_config_vehicle_type ON public.pricing_config USING btree (vehicle_type)
public,pricing_config,idx_pricing_config_service_type,CREATE INDEX idx_pricing_config_service_type ON public.pricing_config USING btree (service_type)
public,pricing_config,pricing_config_pkey,CREATE UNIQUE INDEX pricing_config_pkey ON public.pricing_config USING btree (id)
public,pricing_zones,pricing_zones_pkey,CREATE UNIQUE INDEX pricing_zones_pkey ON public.pricing_zones USING btree (id)
public,pricing_zones,pricing_zones_zone_code_key,CREATE UNIQUE INDEX pricing_zones_zone_code_key ON public.pricing_zones USING btree (zone_code)
public,promo_code_users,promo_code_users_pkey,CREATE UNIQUE INDEX promo_code_users_pkey ON public.promo_code_users USING btree (id)
public,promo_code_users,promo_code_users_unique,"CREATE UNIQUE INDEX promo_code_users_unique ON public.promo_code_users USING btree (promo_code_id, user_id)"
public,promo_codes,idx_promo_codes_code,CREATE INDEX idx_promo_codes_code ON public.promo_codes USING btree (code)
public,promo_codes,promo_codes_code_key,CREATE UNIQUE INDEX promo_codes_code_key ON public.promo_codes USING btree (code)
public,promo_codes,promo_codes_pkey,CREATE UNIQUE INDEX promo_codes_pkey ON public.promo_codes USING btree (id)
public,rider_assignments,idx_rider_assignments_expires_at,CREATE INDEX idx_rider_assignments_expires_at ON public.rider_assignments USING btree (expires_at DESC)
public,rider_assignments,idx_rider_assignments_status,CREATE INDEX idx_rider_assignments_status ON public.rider_assignments USING btree (assignment_status)
public,rider_assignments,rider_assignments_pkey,CREATE UNIQUE INDEX rider_assignments_pkey ON public.rider_assignments USING btree (id)
public,rider_assignments,idx_rider_assignments_order_id,CREATE INDEX idx_rider_assignments_order_id ON public.rider_assignments USING btree (order_id)
public,rider_assignments,idx_rider_assignments_rider_id,CREATE INDEX idx_rider_assignments_rider_id ON public.rider_assignments USING btree (rider_id)
public,rider_assignments,idx_rider_assignments_round,CREATE INDEX idx_rider_assignments_round ON public.rider_assignments USING btree (assignment_round)
public,rider_daily_activity,rider_daily_activity_pkey,CREATE UNIQUE INDEX rider_daily_activity_pkey ON public.rider_daily_activity USING btree (id)
public,rider_daily_activity,rider_daily_activity_rider_id_date_key,"CREATE UNIQUE INDEX rider_daily_activity_rider_id_date_key ON public.rider_daily_activity USING btree (rider_id, date)"
public,rider_kyc,rider_kyc_pkey,CREATE UNIQUE INDEX rider_kyc_pkey ON public.rider_kyc USING btree (id)
public,rider_kyc,idx_rider_kyc_created_at,CREATE INDEX idx_rider_kyc_created_at ON public.rider_kyc USING btree (created_at DESC)
public,rider_kyc,idx_rider_kyc_activation_status,CREATE INDEX idx_rider_kyc_activation_status ON public.rider_kyc USING btree (activation_status)
public,rider_kyc,idx_rider_kyc_kyc_status,CREATE INDEX idx_rider_kyc_kyc_status ON public.rider_kyc USING btree (kyc_status)
public,rider_kyc,idx_rider_kyc_handled_by_admin_id,CREATE INDEX idx_rider_kyc_handled_by_admin_id ON public.rider_kyc USING btree (handled_by_admin_id)
public,rider_kyc,idx_rider_kyc_user_id,CREATE INDEX idx_rider_kyc_user_id ON public.rider_kyc USING btree (user_id)
public,rider_payout_accounts,idx_rider_payout_accounts_beneficiary_id,CREATE INDEX idx_rider_payout_accounts_beneficiary_id ON public.rider_payout_accounts USING btree (beneficiary_id)
public,rider_payout_accounts,idx_rider_payout_accounts_user_id,CREATE UNIQUE INDEX idx_rider_payout_accounts_user_id ON public.rider_payout_accounts USING btree (user_id)
public,rider_payout_accounts,rider_payout_accounts_beneficiary_id_key,CREATE UNIQUE INDEX rider_payout_accounts_beneficiary_id_key ON public.rider_payout_accounts USING btree (beneficiary_id)
public,rider_payout_accounts,idx_rider_payout_accounts_rider_id,CREATE UNIQUE INDEX idx_rider_payout_accounts_rider_id ON public.rider_payout_accounts USING btree (rider_id)
public,rider_payout_accounts,idx_rider_payout_accounts_cashfree_status,CREATE INDEX idx_rider_payout_accounts_cashfree_status ON public.rider_payout_accounts USING btree (cashfree_beneficiary_status)
public,rider_payout_accounts,rider_payout_accounts_pkey,CREATE UNIQUE INDEX rider_payout_accounts_pkey ON public.rider_payout_accounts USING btree (id)
public,rider_payout_updates_log,idx_rider_payout_updates_log_user_created,"CREATE INDEX idx_rider_payout_updates_log_user_created ON public.rider_payout_updates_log USING btree (user_id, created_at)"

schema_name,function_name,arguments,definition
public,accept_intercity_offer,"p_request_id uuid, p_actor_type text","CREATE OR REPLACE FUNCTION public.accept_intercity_offer(p_request_id uuid, p_actor_type text)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_request RECORD;
    v_metadata jsonb;
BEGIN
    SELECT * INTO v_request
    FROM public.intercity_requests
    WHERE id = p_request_id
    FOR UPDATE;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Request not found';
    END IF;
    
    v_metadata := COALESCE(v_request.metadata, '{}'::jsonb);
    
    IF p_actor_type = 'sender' THEN
        v_metadata := v_metadata || '{""sender_agreed"": true}'::jsonb;
    ELSIF p_actor_type = 'traveller' THEN
        v_metadata := v_metadata || '{""traveller_agreed"": true}'::jsonb;
    ELSE
        RAISE EXCEPTION 'Invalid actor type: %', p_actor_type;
    END IF;
    
    IF COALESCE((v_metadata->>'sender_agreed')::boolean, false) = true 
       AND COALESCE((v_metadata->>'traveller_agreed')::boolean, false) = true THEN
        UPDATE public.intercity_requests
        SET metadata = v_metadata,
            status = 'fare_agreed',
            updated_at = now()
        WHERE id = p_request_id;
    ELSE
        UPDATE public.intercity_requests
        SET metadata = v_metadata,
            status = 'discussion_started',
            updated_at = now()
        WHERE id = p_request_id;
    END IF;
    
    SELECT json_build_object(
        'id', id,
        'status', status,
        'metadata', metadata,
        'proposed_fare', proposed_fare
    )::jsonb INTO v_metadata
    FROM public.intercity_requests
    WHERE id = p_request_id;
    
    RETURN v_metadata;
END;
$function$
"
public,accept_intercity_request,"p_request_id uuid, p_rider_user_id uuid","CREATE OR REPLACE FUNCTION public.accept_intercity_request(p_request_id uuid, p_rider_user_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_request RECORD;
    v_order RECORD;
    v_rider RECORD;
    v_travel_plan RECORD;
    v_otp text;
    v_active_orders_count int;
BEGIN
    -- 1. Get rider details and validate active status
    SELECT * INTO v_rider
    FROM public.riders
    WHERE user_id = p_rider_user_id;

    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'INVALID_REQUEST',
            'message', 'Rider profile not found for user.'
        );
    END IF;

    -- 2. Fetch request to find the order ID (read-only for now)
    SELECT * INTO v_request
    FROM public.intercity_requests
    WHERE id = p_request_id;

    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'INVALID_REQUEST',
            'message', 'Intercity request not found.'
        );
    END IF;

    -- Ownership check: Request traveller_id must match rider id
    IF v_request.traveller_id != v_rider.id THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'INVALID_REQUEST',
            'message', 'Request does not belong to this traveller.'
        );
    END IF;

    -- 3. Lock and fetch order (Order is source of truth, lock first)
    SELECT * INTO v_order
    FROM public.orders
    WHERE id = v_request.parcel_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'INVALID_REQUEST',
            'message', 'Associated order not found.'
        );
    END IF;

    -- Idempotency check: If order is already assigned to this rider and accepted
    IF v_order.rider_id = v_rider.id AND v_order.order_status = 'accepted' THEN
        RETURN jsonb_build_object(
            'success', true,
            'code', 'ALREADY_ACCEPTED',
            'order_id', v_order.id,
            'request_id', v_request.id
        );
    END IF;

    -- Validate order availability
    IF v_order.order_status != 'searching' OR v_order.rider_id IS NOT NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'ORDER_ALREADY_ASSIGNED',
            'message', 'Booking no longer available.'
        );
    END IF;

    -- Validate order search expiration
    IF v_order.search_expires_at IS NOT NULL AND v_order.search_expires_at < now() THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'REQUEST_EXPIRED',
            'message', 'Order search has expired.'
        );
    END IF;

    -- Lock request now for update
    SELECT * INTO v_request
    FROM public.intercity_requests
    WHERE id = p_request_id
    FOR UPDATE;

    -- Validate request expiration
    IF v_request.expires_at IS NOT NULL AND v_request.expires_at < now() THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'REQUEST_EXPIRED',
            'message', 'Request negotiation has expired.'
        );
    END IF;

    -- Validate request status is eligible
    IF v_request.status NOT IN ('request_sent', 'discussion_started', 'fare_agreed') THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'INVALID_REQUEST',
            'message', 'Request status is not eligible for acceptance.'
        );
    END IF;

    -- 4. Validate traveler plan active status
    SELECT * INTO v_travel_plan
    FROM public.rider_travel_plans
    WHERE id = v_request.route_id;

    IF v_travel_plan IS NULL OR v_travel_plan.status::text != 'active' THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'TRAVEL_PLAN_INACTIVE',
            'message', 'Travel plan is no longer active.'
        );
    END IF;

    -- 5. Validate rider is not already busy on another active order
    SELECT COUNT(*) INTO v_active_orders_count
    FROM public.orders
    WHERE rider_id = v_rider.id
      AND order_status IN ('accepted', 'rider_arrived', 'picked_up', 'rider_at_drop', 'ongoing');

    IF v_active_orders_count > 0 THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'RIDER_ALREADY_BUSY',
            'message', 'Rider is already handling another active order.'
        );
    END IF;

    -- 6. Generate cryptographically safe 4-digit OTP (loop to avoid collisions on orders)
    LOOP
        v_otp := floor(random() * 9000 + 1000)::text;
        -- Check collision in orders table
        PERFORM 1 FROM public.orders WHERE otp = v_otp AND order_status IN ('accepted', 'picked_up');
        EXIT WHEN NOT FOUND;
    END LOOP;

    -- 7. Update Request Status to 'confirmed'
    UPDATE public.intercity_requests
    SET status = 'confirmed',
        updated_at = now()
    WHERE id = p_request_id;

    -- 8. Update Order (assigned, otp, pricing)
    UPDATE public.orders
    SET order_status = 'accepted'::public.order_status_enum,
        rider_id = v_rider.id,
        final_fare = v_request.proposed_fare,
        current_fare = v_request.proposed_fare,
        otp = v_otp,
        updated_at = now()
    WHERE id = v_order.id;

    -- 9. Insert chat system notification message
    INSERT INTO public.order_chat_messages(
        sender_id,
        sender_type,
        message,
        user_id,
        is_support,
        order_id,
        rider_id,
        created_at
    ) VALUES (
        v_rider.id,
        'rider',
        '[AGREED] Rider accepted the request. Booking is confirmed.',
        v_order.user_id,
        false,
        v_order.id,
        v_rider.id,
        now()
    );

    RETURN jsonb_build_object(
        'success', true,
        'code', 'SUCCESS',
        'order_id', v_order.id,
        'request_id', v_request.id
    );

EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'success', false,
            'code', 'INVALID_REQUEST',
            'message', SQLERRM
        );
END;
$function$
"
public,assign_nearby_searching_orders_to_rider,,"CREATE OR REPLACE FUNCTION public.assign_nearby_searching_orders_to_rider()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_order RECORD;
    v_radius_km double precision;
    v_stale_sec integer;
    v_dist_km double precision;
    v_timeout_sec integer;
    v_existing_id uuid;
    v_existing_status text;
BEGIN
    -- 1. If coordinates are missing, bypass
    IF NEW.current_lat IS NULL OR NEW.current_lng IS NULL THEN
        RETURN NEW;
    END IF;

    -- 2. Fetch active dispatch config values
    SELECT 
        COALESCE(round_2_radius_km, 5.0),
        COALESCE(rider_location_stale_sec, 60),
        COALESCE(rider_response_timeout_sec, 120)
    INTO 
        v_radius_km, 
        v_stale_sec, 
        v_timeout_sec
    FROM public.dispatch_config
    WHERE is_active = true
    LIMIT 1;

    -- Fallbacks if config is missing or null
    v_radius_km := COALESCE(v_radius_km, 5.0);
    v_stale_sec := COALESCE(v_stale_sec, 60);
    v_timeout_sec := COALESCE(v_timeout_sec, 120);

    FOR v_order IN (
        SELECT o.id, o.pickup_lat, o.pickup_lng, o.vehicle_type::text AS vehicle_type, o.order_type::text AS order_type, o.rider_earning
        FROM public.orders o
        WHERE o.order_status = 'searching'
    ) LOOP
        -- Calculate distance between rider and order pickup location
        v_dist_km := 6371 * acos(
            LEAST(GREATEST(
                cos(radians(v_order.pickup_lat))
                * cos(radians(NEW.current_lat))
                * cos(
                    radians(NEW.current_lng)
                    - radians(v_order.pickup_lng)
                )
                + sin(radians(v_order.pickup_lat))
                * sin(radians(NEW.current_lat))
            , -1.0), 1.0)
        );

        -- If the rider is within the max radius, and matches the vehicle type filter
        IF v_dist_km <= v_radius_km AND (v_order.order_type != 'ride' OR EXISTS (
            SELECT 1 FROM public.rider_kyc rk 
            WHERE rk.user_id = NEW.user_id 
              AND rk.vehicle_type::text = v_order.vehicle_type
        )) THEN
            -- Check if this rider doesn't already have an assignment for this order
            v_existing_id := NULL;
            v_existing_status := NULL;
            
            SELECT id, assignment_status INTO v_existing_id, v_existing_status
            FROM public.rider_assignments
            WHERE order_id = v_order.id 
              AND rider_id = NEW.id
            LIMIT 1;

            BEGIN
                IF v_existing_id IS NULL THEN
                    -- Insert assignment
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
                        NEW.id,
                        1,
                        'sent',
                        v_dist_km,
                        v_order.rider_earning,
                        NOW(),
                        NOW() + (v_timeout_sec || ' seconds')::interval,
                        NOW(),
                        v_order.rider_earning
                    );

                    -- Also insert into logs
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
                        NEW.id,
                        1,
                        'sent',
                        v_dist_km,
                        v_order.rider_earning,
                        NOW()
                    );
                ELSIF v_existing_status = 'expired' THEN
                    -- Only show again if the fare is boosted
                    IF EXISTS (
                        SELECT 1 FROM public.rider_assignments
                        WHERE id = v_existing_id
                          AND v_order.rider_earning > COALESCE(last_seen_fare, estimated_earnings, 0)
                    ) THEN
                        -- Update existing assignment back to 'sent' with fresh expiry
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

                        -- Log the update
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
                            NEW.id,
                            1,
                            'sent',
                            v_dist_km,
                            CEIL(v_dist_km * 3),
                            NOW()
                        );
                    END IF;
                ELSIF v_existing_status = 'rejected' THEN
                    -- Only show again if 4-minute cooldown is over AND the fare is boosted
                    IF EXISTS (
                        SELECT 1 FROM public.rider_assignments
                        WHERE id = v_existing_id
                          AND NOW() >= COALESCE(hidden_until, NOW())
                          AND v_order.rider_earning > COALESCE(last_seen_fare, estimated_earnings, 0)
                    ) THEN
                        -- Update existing assignment back to 'sent' with fresh expiry
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

                        -- Log the update
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
                            NEW.id,
                            1,
                            'sent',
                            v_dist_km,
                            CEIL(v_dist_km * 3),
                            NOW()
                        );
                    END IF;
                END IF;
            EXCEPTION WHEN unique_violation THEN
                -- Safely ignore duplicate key constraint violations
                NULL;
            END;
        END IF;
    END LOOP;

    RETURN NEW;
END;
$function$
"
public,audit_rider_wallets,,"CREATE OR REPLACE FUNCTION public.audit_rider_wallets()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_discrepancy_count integer := 0;
  v_details jsonb;
BEGIN
  -- Find all riders where wallet_balance != sum of wallet_transactions
  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'rider_id', r.id,
    'wallet_balance', r.wallet_balance,
    'ledger_sum', coalesce(sum(t.amount), 0)
  )), '[]'::jsonb)
  INTO v_details
  FROM public.riders r
  LEFT JOIN public.wallet_transactions t ON t.rider_id = r.id
  GROUP BY r.id, r.wallet_balance
  HAVING r.wallet_balance != coalesce(sum(t.amount), 0);

  v_discrepancy_count := jsonb_array_length(v_details);

  -- Log the run results
  INSERT INTO public.wallet_audit_logs (discrepancies_found, details)
  VALUES (v_discrepancy_count, v_details);

  RETURN jsonb_build_object(
    'success', true,
    'discrepancies_found', v_discrepancy_count,
    'details', v_details
  );
END;
$function$
"
public,cancel_order,"p_order_id uuid, p_cancelled_by text, p_cancel_reason text, p_rider_id uuid, p_user_id uuid, p_admin_id uuid","CREATE OR REPLACE FUNCTION public.cancel_order(p_order_id uuid, p_cancelled_by text, p_cancel_reason text DEFAULT NULL::text, p_rider_id uuid DEFAULT NULL::uuid, p_user_id uuid DEFAULT NULL::uuid, p_admin_id uuid DEFAULT NULL::uuid)
 RETURNS json
 LANGUAGE plpgsql
AS $function$

DECLARE

    v_order RECORD;

BEGIN



    -- =====================================================
    -- LOCK ORDER
    -- =====================================================

    SELECT *

    INTO v_order

    FROM orders

    WHERE id = p_order_id

    FOR UPDATE;



    IF v_order IS NULL THEN

        RETURN json_build_object(

            'success', false,

            'message', 'Order not found'

        );

    END IF;



    -- =====================================================
    -- COMPLETED CHECK
    -- =====================================================

    IF v_order.order_status IN (

        'completed',

        'delivered',

        'cancelled'

    ) THEN

        RETURN json_build_object(

            'success', false,

            'message', 'Order already closed'

        );

    END IF;



    -- =====================================================
    -- RIDER CANCEL AFTER ACCEPT
    -- =====================================================
    --
    -- VERY IMPORTANT MARKETPLACE FLOW
    --
    -- accepted
    -- → rider cancels
    -- → back to searching
    --
    -- =====================================================

    IF

        p_cancelled_by = 'rider'

        AND

        v_order.order_status IN (

            'accepted',

            'rider_arrived'

        )

    THEN



        -- ================================================
        -- RELEASE RIDER
        -- ================================================

        UPDATE riders

        SET

            account_status = 'online',

            updated_at = now()

        WHERE id = v_order.rider_id;



        -- ================================================
        -- RESET ORDER
        -- ================================================

        UPDATE orders

        SET

            rider_id = NULL,

            order_status = 'searching',

            accepted_at = NULL,

            updated_at = now()

        WHERE id = p_order_id;



        -- ================================================
        -- STATUS HISTORY
        -- ================================================

        INSERT INTO order_status_history (

            order_id,

            previous_status,

            new_status,

            changed_by,

            changed_by_rider_id,

            notes,

            metadata

        )

        VALUES (

            p_order_id,

            v_order.order_status,

            'searching',

            'rider',

            p_rider_id,

            'Rider cancelled order, dispatch restarted',

            json_build_object(

                'cancel_reason',

                p_cancel_reason

            )

        );



        RETURN json_build_object(

            'success', true,

            'message', 'Order returned to searching state'

        );

    END IF;



    -- =====================================================
    -- NORMAL CANCELLATION
    -- =====================================================

    UPDATE orders

    SET

        order_status = 'cancelled',

        cancelled_by = p_cancelled_by,

        cancel_reason = p_cancel_reason,

        cancelled_at = now(),

        updated_at = now()

    WHERE id = p_order_id;



    -- =====================================================
    -- RELEASE RIDER IF EXISTS
    -- =====================================================

    IF v_order.rider_id IS NOT NULL THEN

        UPDATE riders

        SET

            account_status = 'online',

            updated_at = now()

        WHERE id = v_order.rider_id;

    END IF;



    -- =====================================================
    -- EXPIRE ASSIGNMENTS
    -- =====================================================

    UPDATE order_assignment_logs

    SET

        assignment_status = 'cancelled',

        responded_at = now()

    WHERE

        order_id = p_order_id

        AND assignment_status IN (

            'sent',

            'accepted'

        );



    -- =====================================================
    -- STATUS HISTORY
    -- =====================================================

    INSERT INTO order_status_history (

        order_id,

        previous_status,

        new_status,

        changed_by,

        changed_by_user_id,

        changed_by_rider_id,

        changed_by_admin_id,

        notes,

        metadata

    )

    VALUES (

        p_order_id,

        v_order.order_status,

        'cancelled',

        p_cancelled_by,

        p_user_id,

        p_rider_id,

        p_admin_id,

        'Order cancelled',

        json_build_object(

            'cancel_reason',

            p_cancel_reason

        )

    );



    RETURN json_build_object(

        'success', true,

        'message', 'Order cancelled successfully'

    );

END;

$function$
"
public,check_dormant_riders,,"CREATE OR REPLACE FUNCTION public.check_dormant_riders()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_rider RECORD;
    v_sub RECORD;
    v_hour integer;
BEGIN
    -- Get current hour in IST timezone
    v_hour := extract(hour from now() at time zone 'Asia/Kolkata');

    -- 3.1. Morning Dormant Rider Check (8:00 AM to 11:00 AM IST)
    -- If rider is offline for >2 hours and hasn't been notified today
    IF v_hour >= 8 AND v_hour <= 11 THEN
        FOR v_rider IN 
            SELECT r.id, r.user_id 
            FROM public.riders r
            WHERE (r.account_status != 'online' OR r.account_status IS NULL)
              AND (r.updated_at IS NULL OR r.updated_at < now() - INTERVAL '2 hours')
              AND (r.last_dormant_notification_sent_at IS NULL OR r.last_dormant_notification_sent_at < date_trunc('day', now() at time zone 'Asia/Kolkata'))
        LOOP
            PERFORM public.send_push_notification_fnc(
                v_rider.user_id,
                'Go Online! Rides & Parcels Waiting 🚀',
                'Rides and parcels are waiting in your location. Go online now to start earning!',
                jsonb_build_object('type', 'go_online')
            );
            
            UPDATE public.riders 
            SET last_dormant_notification_sent_at = now() 
            WHERE id = v_rider.id;
        END LOOP;
    END IF;

    -- 3.2. Active Subscription Offline Check
    -- If subscription is active, and rider is offline for >2 hours, remind them of zero commission benefits
    FOR v_rider IN 
        SELECT r.id, r.user_id 
        FROM public.riders r
        INNER JOIN public.rider_subscription_history sub ON sub.rider_id = r.id
        WHERE (r.account_status != 'online' OR r.account_status IS NULL)
          AND sub.is_active = true 
          AND sub.expires_at > now()
          AND (r.updated_at IS NULL OR r.updated_at < now() - INTERVAL '2 hours')
          AND (r.last_sub_offline_notification_sent_at IS NULL OR r.last_sub_offline_notification_sent_at < now() - INTERVAL '24 hours')
    LOOP
        PERFORM public.send_push_notification_fnc(
            v_rider.user_id,
            'Your Subscription is Active! ⚡',
            'Your Waydrop MAX subscription is active. Go online and take rides now to avail 100% commission-free earnings!',
            jsonb_build_object('type', 'go_online_sub')
        );
        
        UPDATE public.riders 
        SET last_sub_offline_notification_sent_at = now() 
        WHERE id = v_rider.id;
    END LOOP;

    -- 3.3. Subscription Expiry Checker
    -- A) Mark expired subscriptions inactive & notify
    FOR v_sub IN 
        SELECT sub.id, sub.rider_id, r.user_id 
        FROM public.rider_subscription_history sub
        INNER JOIN public.riders r ON r.id = sub.rider_id
        WHERE sub.is_active = true 
          AND sub.expires_at <= now()
    LOOP
        UPDATE public.rider_subscription_history 
        SET is_active = false 
        WHERE id = v_sub.id;

        PERFORM public.send_push_notification_fnc(
            v_sub.user_id,
            'Waydrop MAX Subscription Expired ⚠️',
            'Your commission-free subscription has expired. Renew/extend now to keep earning without commissions!',
            jsonb_build_object('type', 'subscription_expired')
        );
    END LOOP;

    -- B) Notify subscriptions expiring in the next 24 hours
    FOR v_sub IN 
        SELECT sub.id, sub.rider_id, r.user_id, sub.expires_at 
        FROM public.rider_subscription_history sub
        INNER JOIN public.riders r ON r.id = sub.rider_id
        WHERE sub.is_active = true 
          AND sub.expires_at > now() 
          AND sub.expires_at <= now() + INTERVAL '24 hours'
          AND sub.expire_warning_sent = false
    LOOP
        UPDATE public.rider_subscription_history 
        SET expire_warning_sent = true 
        WHERE id = v_sub.id;

        PERFORM public.send_push_notification_fnc(
            v_sub.user_id,
            'Subscription Expiring Soon ⏰',
            'Your Waydrop MAX subscription expires in less than 24 hours (on ' || to_char(v_sub.expires_at at time zone 'Asia/Kolkata', 'HH:MI AM, DD Mon') || '). Extend now!',
            jsonb_build_object('type', 'subscription_expiring')
        );
    END LOOP;
END;
$function$
"
public,check_is_order_candidate_rider,"p_order_id uuid, p_user_id uuid","CREATE OR REPLACE FUNCTION public.check_is_order_candidate_rider(p_order_id uuid, p_user_id uuid)
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
"
public,check_is_order_passenger,"p_order_id uuid, p_user_id uuid","CREATE OR REPLACE FUNCTION public.check_is_order_passenger(p_order_id uuid, p_user_id uuid)
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
"
public,check_payout_update_limit,,"CREATE OR REPLACE FUNCTION public.check_payout_update_limit()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_update_count integer;
BEGIN
    -- Check if it's insert, or if it's update where rider-initiated fields changed
    IF (TG_OP = 'INSERT') OR 
       (TG_OP = 'UPDATE' AND (
           OLD.account_number IS DISTINCT FROM NEW.account_number OR
           OLD.ifsc_code IS DISTINCT FROM NEW.ifsc_code OR
           OLD.upi_vpa IS DISTINCT FROM NEW.upi_vpa OR
           OLD.beneficiary_name IS DISTINCT FROM NEW.beneficiary_name OR
           OLD.beneficiary_phone IS DISTINCT FROM NEW.beneficiary_phone OR
           OLD.beneficiary_email IS DISTINCT FROM NEW.beneficiary_email OR
           OLD.payout_method IS DISTINCT FROM NEW.payout_method
       )) THEN
       
        -- 1. Lock the user row to prevent race conditions on concurrent requests
        PERFORM 1 FROM public.users WHERE id = NEW.user_id FOR UPDATE;

        -- 2. Count updates in the last 7 days (rolling window)
        SELECT COUNT(*) INTO v_update_count
        FROM public.rider_payout_updates_log
        WHERE user_id = NEW.user_id
          AND created_at > now() - INTERVAL '7 days';

        IF v_update_count >= 2 THEN
            RAISE EXCEPTION 'Maximum of 2 payout account updates allowed per week';
        END IF;

        -- 3. Log this update event
        INSERT INTO public.rider_payout_updates_log (user_id)
        VALUES (NEW.user_id);
        
    END IF;

    RETURN NEW;
END;
$function$
"
public,check_travel_plan_active_bookings,,"CREATE OR REPLACE FUNCTION public.check_travel_plan_active_bookings()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    IF EXISTS (
        SELECT 1 FROM public.intercity_requests
        WHERE route_id = OLD.id
          AND status IN ('confirmed', 'paid')
    ) THEN
        RAISE EXCEPTION 'Cannot delete travel plan while active bookings exist. Mark it inactive instead.';
    END IF;
    RETURN OLD;
END;
$function$
"
public,complete_withdrawal,"p_withdrawal_id uuid, p_cashfree_ref_id text, p_status text, p_response jsonb","CREATE OR REPLACE FUNCTION public.complete_withdrawal(p_withdrawal_id uuid, p_cashfree_ref_id text, p_status text, p_response jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_rider_id uuid;
    v_amount numeric;
    v_current_status public.rider_withdrawal_status_enum;
    v_new_status public.rider_withdrawal_status_enum;
BEGIN
    -- Safely cast input status text to enum
    BEGIN
        v_new_status := p_status::public.rider_withdrawal_status_enum;
    EXCEPTION WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'message', 'Invalid status to complete withdrawal');
    END;

    -- Fetch and lock the withdrawal record
    SELECT rider_id, amount, status INTO v_rider_id, v_amount, v_current_status
    FROM public.rider_withdrawals
    WHERE id = p_withdrawal_id
    FOR UPDATE;

    IF v_rider_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'Withdrawal record not found');
    END IF;

    -- Check if already finalized (success or failed)
    IF v_current_status IN ('success'::public.rider_withdrawal_status_enum, 'failed'::public.rider_withdrawal_status_enum) THEN
        RETURN jsonb_build_object('success', true, 'message', 'Withdrawal already finalized in ' || v_current_status::text || ' state');
    END IF;

    -- Prevent invalid transition from processing back to pending
    IF v_current_status = 'processing'::public.rider_withdrawal_status_enum AND v_new_status = 'pending'::public.rider_withdrawal_status_enum THEN
        RETURN jsonb_build_object('success', false, 'message', 'Cannot transition from processing back to pending');
    END IF;

    -- Update withdrawal status (updated_at is handled by trigger)
    UPDATE public.rider_withdrawals
    SET status = v_new_status,
        cashfree_reference_id = p_cashfree_ref_id,
        cashfree_response = p_response
    WHERE id = p_withdrawal_id;

    -- Refund rider's wallet balance if status resolved to failed
    IF v_new_status = 'failed'::public.rider_withdrawal_status_enum THEN
        -- Lock rider row for update
        PERFORM id FROM public.riders WHERE id = v_rider_id FOR UPDATE;

        UPDATE public.riders
        SET wallet_balance = wallet_balance + v_amount
        WHERE id = v_rider_id;
    END IF;

    RETURN jsonb_build_object('success', true);
END;
$function$
"
public,confirm_intercity_booking,p_request_id uuid,"CREATE OR REPLACE FUNCTION public.confirm_intercity_booking(p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_request RECORD;
    v_active_bookings INT;
    v_max_bookings INT;
    v_plan_pickup TEXT;
    v_plan_dest TEXT;
    v_plan_vehicle public.vehicle_type_enum;
    v_plan_date TIMESTAMPTZ;
    v_plan_weight NUMERIC;
    v_order_weight NUMERIC;
    v_order_type TEXT;
    v_pickup_city TEXT;
    v_dest_city TEXT;
    v_metadata jsonb;
BEGIN
    SELECT * INTO v_request
    FROM public.intercity_requests
    WHERE id = p_request_id
    FOR UPDATE;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Request not found';
    END IF;
    
    IF v_request.status = 'confirmed' THEN
        RETURN json_build_object('success', true, 'status', 'confirmed')::jsonb;
    END IF;
    
    IF COALESCE((v_request.metadata->>'sender_agreed')::boolean, false) IS NOT TRUE 
       OR COALESCE((v_request.metadata->>'traveller_agreed')::boolean, false) IS NOT TRUE THEN
        RAISE EXCEPTION 'Cannot confirm booking before both parties agree on the fare.';
    END IF;
    
    SELECT max_bookings, pickup_city, destination_city, vehicle_type, travel_date, max_weight_kg 
    INTO v_max_bookings, v_plan_pickup, v_plan_dest, v_plan_vehicle, v_plan_date, v_plan_weight
    FROM public.rider_travel_plans
    WHERE id = v_request.route_id
    FOR UPDATE;
    
    SELECT COUNT(*) INTO v_active_bookings
    FROM public.intercity_requests
    WHERE route_id = v_request.route_id
      AND status IN ('confirmed', 'paid')
      AND id IS DISTINCT FROM p_request_id;
      
    IF v_active_bookings >= v_max_bookings THEN
        RAISE EXCEPTION 'This travel plan is fully booked. (Current: %, Max limit: %)', v_active_bookings, v_max_bookings;
    END IF;
    
    SELECT actual_weight_kg, order_type, pickup_city, destination_city
    INTO v_order_weight, v_order_type, v_pickup_city, v_dest_city
    FROM public.orders
    WHERE id = v_request.parcel_id;
    
    v_metadata := COALESCE(v_request.metadata, '{}'::jsonb) || jsonb_build_object(
        'travel_plan_snapshot', jsonb_build_object(
            'pickup_city', v_plan_pickup,
            'destination_city', v_plan_dest,
            'vehicle_type', v_plan_vehicle,
            'travel_date', v_plan_date,
            'max_weight_kg', v_plan_weight
        ),
        'booking_snapshot', jsonb_build_object(
            'agreed_fare', v_request.proposed_fare,
            'booking_type', v_request.booking_type,
            'pickup_city', v_pickup_city,
            'destination_city', v_dest_city,
            'weight_kg', v_order_weight
        )
    );
    
    UPDATE public.intercity_requests
    SET status = 'confirmed',
        metadata = v_metadata,
        updated_at = now()
    WHERE id = p_request_id;
    
    UPDATE public.orders
    SET order_status = 'accepted'::public.order_status_enum,
        rider_id = v_request.traveller_id,
        final_fare = v_request.proposed_fare,
        current_fare = v_request.proposed_fare,
        updated_at = now()
    WHERE id = v_request.parcel_id;
    
    RETURN json_build_object('success', true, 'status', 'confirmed')::jsonb;
END;
$function$
"
public,create_rider_profile_on_activation,,"CREATE OR REPLACE FUNCTION public.create_rider_profile_on_activation()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$

BEGIN

  -- =====================================
  -- PREVENT DUPLICATES
  -- =====================================

  IF NOT EXISTS (

    SELECT 1

    FROM riders

    WHERE user_id = NEW.user_id

  ) THEN

    INSERT INTO riders (

      kyc_id,

      user_id,

      account_status,

      is_verified

    )

    VALUES (

      NEW.id,

      NEW.user_id,

      'offline',

      true
    );

  END IF;

  RETURN NEW;

END;

$function$
"
public,deliver_push_notification_http_fnc,"p_user_id uuid, p_title text, p_body text, p_data jsonb","CREATE OR REPLACE FUNCTION public.deliver_push_notification_http_fnc(p_user_id uuid, p_title text, p_body text, p_data jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
    PERFORM net.http_post(
        url := 'https://yvwpchffctiagevpqgwy.supabase.co/functions/v1/send-push-notification',
        headers := '{""Content-Type"": ""application/json"", ""Authorization"": ""Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Inl2d3BjaGZmY3RpYWdldnBxZ3d5Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzgxMzQ3NzUsImV4cCI6MjA5MzcxMDc3NX0.y4Shv58UDlTF2BNGsVVy3fWR3O7M2MzjQmHabJAFdCA""}'::jsonb,
        body := jsonb_build_object(
            'user_id', p_user_id,
            'title', p_title,
            'body', p_body,
            'data', p_data
        ),
        timeout_milliseconds := 5000
    );
EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'Failed to send push notification HTTP call: %', SQLERRM;
END;
$function$
"
public,expire_stale_intercity_requests,,"CREATE OR REPLACE FUNCTION public.expire_stale_intercity_requests()
 RETURNS void
 LANGUAGE plpgsql
AS $function$
BEGIN
    -- Stale negotiation expiration (24h)
    UPDATE public.intercity_requests
    SET status = 'expired',
        expiry_reason = 'negotiation_timeout',
        updated_at = now()
    WHERE status IN ('request_sent', 'discussion_started', 'fare_agreed')
      AND expires_at < now();

    -- Travel plan auto-expiry
    UPDATE public.rider_travel_plans
    SET status = 'expired'::public.travel_plan_status_enum
    WHERE travel_date < now()
      AND status = 'active'::public.travel_plan_status_enum;
END;
$function$
"
public,fail_withdrawal,"p_withdrawal_id uuid, p_error_response jsonb","CREATE OR REPLACE FUNCTION public.fail_withdrawal(p_withdrawal_id uuid, p_error_response jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_rider_id uuid;
    v_amount numeric;
    v_status public.rider_withdrawal_status_enum;
BEGIN
    -- Fetch and lock the withdrawal record
    SELECT rider_id, amount, status INTO v_rider_id, v_amount, v_status
    FROM public.rider_withdrawals
    WHERE id = p_withdrawal_id
    FOR UPDATE;

    IF v_rider_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'Withdrawal record not found');
    END IF;

    -- Only allow failing from non-finalized states (pending or processing)
    IF v_status IN ('success'::public.rider_withdrawal_status_enum, 'failed'::public.rider_withdrawal_status_enum) THEN
        RETURN jsonb_build_object('success', true, 'message', 'Withdrawal already finalized in ' || v_status::text || ' state');
    END IF;

    -- Update withdrawal status (updated_at is handled by trigger)
    UPDATE public.rider_withdrawals
    SET status = 'failed'::public.rider_withdrawal_status_enum,
        cashfree_response = p_error_response
    WHERE id = p_withdrawal_id;

    -- Lock rider row for update
    PERFORM id FROM public.riders WHERE id = v_rider_id FOR UPDATE;

    -- Refund rider's wallet balance
    UPDATE public.riders
    SET wallet_balance = wallet_balance + v_amount
    WHERE id = v_rider_id;

    RETURN jsonb_build_object('success', true);
END;
$function$
"
public,find_nearby_riders,"p_order_id uuid, p_pickup_lat double precision, p_pickup_lng double precision, p_radius_km double precision, p_limit integer","CREATE OR REPLACE FUNCTION public.find_nearby_riders(p_order_id uuid, p_pickup_lat double precision, p_pickup_lng double precision, p_radius_km double precision, p_limit integer)
 RETURNS TABLE(rider_id uuid, user_id uuid, full_name text, vehicle_type text, vehicle_number text, current_lat double precision, current_lng double precision, distance_km numeric)
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_order_type text;
    v_vehicle_type text;
    v_stale_sec integer;
    v_creator_user_id uuid;
    v_weight_kg double precision;
BEGIN
    -- Fetch order details, prioritizing actual_weight_kg (numeric) over weight_category
    SELECT
        o.order_type,
        o.vehicle_type,
        o.user_id,
        COALESCE(
            o.actual_weight_kg,
            COALESCE(NULLIF(regexp_replace(o.weight_category::text, '[^0-9.]', '', 'g'), ''), '0')::double precision
        )::double precision
    INTO
        v_order_type,
        v_vehicle_type,
        v_creator_user_id,
        v_weight_kg
    FROM orders o
    WHERE o.id = p_order_id;

    -- Fetch stale timeout from active dispatch config, fallback to 60 seconds
    SELECT COALESCE(rider_location_stale_sec, 60)
    INTO v_stale_sec
    FROM dispatch_config
    WHERE is_active = true
    LIMIT 1;

    RETURN QUERY
    SELECT
        r.id AS rider_id,
        r.user_id,
        rk.full_name,
        rk.vehicle_type::text AS vehicle_type,
        rk.vehicle_number,
        r.current_lat,
        r.current_lng,
        ROUND(
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
            )::numeric,
            2
        ) AS distance_km
    FROM riders r
    INNER JOIN rider_kyc rk
        ON rk.user_id = r.user_id
    WHERE
        r.account_status = 'online'
        AND r.current_lat IS NOT NULL
        AND r.current_lng IS NOT NULL
        -- Enforce creator user exclusion
        AND r.user_id != v_creator_user_id
        AND (rk.kyc_status::text IN ('approved', 'pending', 'under_review', 'resubmitted') OR rk.kyc_status IS NULL)
        AND (rk.activation_status::text IN ('active', 'pending', 'inactive') OR rk.activation_status IS NULL)
        AND (
            r.last_location_updated_at >= (NOW() - (v_stale_sec || ' seconds')::interval)
            OR
            r.last_location_updated_at >= (NOW() - INTERVAL '24 hours')
            OR
            r.last_location_updated_at IS NULL
        )
        -- Vehicle filter
        AND (
            -- Ride / Intercity Ride
            ((v_order_type = 'ride' OR v_order_type = 'intercity_ride' OR v_order_type = 'intercity') AND 
             rk.vehicle_type::text = v_vehicle_type)
            OR
            -- Ride Sharing
            (v_order_type = 'ride_sharing' AND rk.vehicle_type::text IN ('auto', 'cab'))
            OR
            -- Parcels / Deliveries
            -- Local Parcels / Deliveries
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
            -- Intercity Parcels
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
            -- Others
            (v_order_type NOT IN ('ride', 'intercity_ride', 'intercity', 'ride_sharing', 'local_parcel', 'intercity_parcel') AND v_order_type NOT LIKE '%parcel%' AND v_order_type NOT LIKE '%delivery%')
        )
        -- No active orders filter
        AND NOT EXISTS (
            SELECT 1
            FROM orders o
            WHERE
                o.rider_id = r.id
                AND o.order_status IN (
                    'accepted',
                    'rider_arrived',
                    'picked_up',
                    'ongoing'
                )
        )
        -- Search radius filter
        AND (
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
        ) <= p_radius_km
    ORDER BY distance_km ASC
    LIMIT p_limit;
END;
$function$
"
public,generate_police_reference_code,,"CREATE OR REPLACE FUNCTION public.generate_police_reference_code()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_date text;
    v_random_sos text;
    v_random_sup text;
    v_code_sos text;
    v_code_sup text;
    v_exists boolean;
BEGIN
    v_date := to_char(NOW(), 'YYYYMMDD');
    
    -- Generate Police Reference Code (SOS-WDP-YYYYMMDD-XXXXXX)
    LOOP
        v_random_sos := upper(substring(md5(random()::text) from 1 for 6));
        v_code_sos := 'SOS-WDP-' || v_date || '-' || v_random_sos;
        
        SELECT EXISTS(SELECT 1 FROM public.police_sos_logs WHERE police_reference_code = v_code_sos) INTO v_exists;
        IF NOT v_exists THEN
            NEW.police_reference_code := v_code_sos;
            EXIT;
        END IF;
    END LOOP;
    
    -- Generate Support Ticket Code (SUP-YYYYMMDD-XXXXXX)
    LOOP
        v_random_sup := upper(substring(md5(random()::text) from 1 for 6));
        v_code_sup := 'SUP-' || v_date || '-' || v_random_sup;
        
        SELECT EXISTS(SELECT 1 FROM public.police_sos_logs WHERE support_ticket_code = v_code_sup) INTO v_exists;
        IF NOT v_exists THEN
            NEW.support_ticket_code := v_code_sup;
            EXIT;
        END IF;
    END LOOP;
    
    RETURN NEW;
END;
$function$
"
public,generate_random_alphanumeric,p_length integer,"CREATE OR REPLACE FUNCTION public.generate_random_alphanumeric(p_length integer)
 RETURNS text
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_chars text := '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ';
    v_result text := '';
    i integer;
BEGIN
    FOR i IN 1..p_length LOOP
        v_result := v_result || substr(v_chars, floor(random() * length(v_chars) + 1)::integer, 1);
    END LOOP;
    RETURN v_result;
END;
$function$
"
public,generate_rider_beneficiary_id,,"CREATE OR REPLACE FUNCTION public.generate_rider_beneficiary_id()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
    if new.beneficiary_id is null then
        new.beneficiary_id :=
            'WDR' || lpad(nextval('rider_beneficiary_seq')::text, 6, '0');
    end if;

    return new;
end;
$function$
"
public,generate_unique_order_code,p_order_type text,"CREATE OR REPLACE FUNCTION public.generate_unique_order_code(p_order_type text)
 RETURNS text
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_prefix text;
    v_code text;
    v_exists boolean;
    v_attempts integer := 0;
BEGIN
    v_prefix := public.get_order_code_prefix(p_order_type);
    LOOP
        v_attempts := v_attempts + 1;
        v_code := v_prefix || public.generate_random_alphanumeric(6);
        SELECT EXISTS(SELECT 1 FROM public.orders WHERE order_code = v_code) INTO v_exists;
        IF NOT v_exists THEN
            RETURN v_code;
        END IF;
        IF v_attempts > 100 THEN
            RAISE EXCEPTION 'Failed to generate unique order_code after 100 attempts';
        END IF;
    END LOOP;
END;
$function$
"
public,generate_unique_payment_code,,"CREATE OR REPLACE FUNCTION public.generate_unique_payment_code()
 RETURNS text
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_code text;
    v_exists boolean;
    v_attempts integer := 0;
BEGIN
    LOOP
        v_attempts := v_attempts + 1;
        v_code := 'WDTX' || public.generate_random_alphanumeric(6);
        SELECT EXISTS(SELECT 1 FROM public.payments WHERE payment_code = v_code) INTO v_exists;
        IF NOT v_exists THEN
            RETURN v_code;
        END IF;
        IF v_attempts > 100 THEN
            RAISE EXCEPTION 'Failed to generate unique payment_code after 100 attempts';
        END IF;
    END LOOP;
END;
$function$
"
public,generate_unique_plan_code,,"CREATE OR REPLACE FUNCTION public.generate_unique_plan_code()
 RETURNS text
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_code text;
    v_exists boolean;
    v_attempts integer := 0;
BEGIN
    LOOP
        v_attempts := v_attempts + 1;
        v_code := 'WDTP' || public.generate_random_alphanumeric(6);
        SELECT EXISTS(SELECT 1 FROM public.rider_travel_plans WHERE plan_code = v_code) INTO v_exists;
        IF NOT v_exists THEN
            RETURN v_code;
        END IF;
        IF v_attempts > 100 THEN
            RAISE EXCEPTION 'Failed to generate unique plan_code after 100 attempts';
        END IF;
    END LOOP;
END;
$function$
"
public,generate_unique_transfer_id,,"CREATE OR REPLACE FUNCTION public.generate_unique_transfer_id()
 RETURNS text
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_code text;
    v_exists boolean;
    v_attempts integer := 0;
BEGIN
    LOOP
        v_attempts := v_attempts + 1;
        v_code := 'WDPY' || public.generate_random_alphanumeric(6);
        SELECT EXISTS(SELECT 1 FROM public.rider_withdrawals WHERE transfer_id = v_code) INTO v_exists;
        IF NOT v_exists THEN
            RETURN v_code;
        END IF;
        IF v_attempts > 100 THEN
            RAISE EXCEPTION 'Failed to generate unique transfer_id after 100 attempts';
        END IF;
    END LOOP;
END;
$function$
"
public,generate_unique_user_code,,"CREATE OR REPLACE FUNCTION public.generate_unique_user_code()
 RETURNS text
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_code text;
    v_exists boolean;
    v_attempts integer := 0;
BEGIN
    LOOP
        v_attempts := v_attempts + 1;
        v_code := 'WDU' || public.generate_random_alphanumeric(6);
        SELECT EXISTS(SELECT 1 FROM public.users WHERE user_code = v_code) INTO v_exists;
        IF NOT v_exists THEN
            RETURN v_code;
        END IF;
        IF v_attempts > 100 THEN
            RAISE EXCEPTION 'Failed to generate unique user_code after 100 attempts';
        END IF;
    END LOOP;
END;
$function$
"
public,get_order_code_prefix,p_order_type text,"CREATE OR REPLACE FUNCTION public.get_order_code_prefix(p_order_type text)
 RETURNS text
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
BEGIN
    RETURN CASE p_order_type
        WHEN 'ride' THEN 'WDR'
        WHEN 'intercity_ride' THEN 'WDIR'
        WHEN 'local_parcel' THEN 'WDP'
        WHEN 'intercity_parcel' THEN 'WDIP'
        WHEN 'ride_sharing' THEN 'WDS'
        WHEN 'food_delivery' THEN 'WDF'
        WHEN 'grocery_delivery' THEN 'WDG'
        WHEN 'batch_delivery' THEN 'WDB'
        ELSE 'WD'
    END;
END;
$function$
"
public,get_rider_reliability_stats,p_rider_id uuid,"CREATE OR REPLACE FUNCTION public.get_rider_reliability_stats(p_rider_id uuid)
 RETURNS TABLE(reliability_score integer, rating numeric, completion_rate numeric, on_time_rate numeric, total_completed bigint, total_cancelled bigint, experience_score integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_rating NUMERIC;
    v_completed BIGINT;
    v_cancelled BIGINT;
    v_on_time BIGINT;
    v_completion_rate NUMERIC;
    v_on_time_rate NUMERIC;
    v_experience_score INT;
    v_rating_score NUMERIC;
    v_reliability_score INT;
BEGIN
    -- 1. Get rating (Bayesian rating calculated in riders table)
    SELECT COALESCE(r.rating, 5.0) INTO v_rating FROM public.riders r WHERE r.id = p_rider_id;
    v_rating_score := v_rating * 20.0; -- 5.0 rating -> 100 points

    -- 2. Completed / Cancelled / On-Time counts
    SELECT 
        COUNT(id) FILTER (WHERE order_status IN ('completed', 'delivered')),
        COUNT(id) FILTER (WHERE order_status = 'cancelled'),
        COUNT(id) FILTER (
            WHERE order_status IN ('completed', 'delivered') 
              AND (travel_date IS NULL OR completed_at <= travel_date + INTERVAL '4 hours')
              AND NOT EXISTS (
                  SELECT 1 FROM public.rider_reviews rr 
                  WHERE rr.order_id = orders.id AND 'late_arrival' = ANY(rr.tags)
              )
        )
    INTO v_completed, v_cancelled, v_on_time
    FROM public.orders
    WHERE rider_id = p_rider_id;

    -- 3. Calculate Rates
    IF (v_completed + v_cancelled) > 0 THEN
        v_completion_rate := (v_completed::numeric / (v_completed + v_cancelled)) * 100.0;
    ELSE
        v_completion_rate := 100.0; -- Default for new riders
    END IF;

    IF v_completed > 0 THEN
        v_on_time_rate := (v_on_time::numeric / v_completed) * 100.0;
    ELSE
        v_on_time_rate := 100.0; -- Default for new riders
    END IF;

    -- 4. Experience Score (Piecewise curve)
    IF v_completed = 0 THEN
        v_experience_score := 0;
    ELSIF v_completed < 10 THEN
        v_experience_score := 20;
    ELSIF v_completed < 50 THEN
        v_experience_score := 60;
    ELSIF v_completed < 100 THEN
        v_experience_score := 80;
    ELSE
        v_experience_score := 100;
    END IF;

    -- 5. Calculate final reliability score (40% rating, 40% completion rate, 20% experience)
    v_reliability_score := ROUND((v_rating_score * 0.40) + (v_completion_rate * 0.40) + (v_experience_score * 0.20));

    RETURN QUERY SELECT 
        LEAST(GREATEST(v_reliability_score, 0), 100)::INT,
        v_rating,
        ROUND(v_completion_rate, 2),
        ROUND(v_on_time_rate, 2),
        v_completed,
        v_cancelled,
        v_experience_score;
END;
$function$
"
public,handle_order_activity_tracking,,"CREATE OR REPLACE FUNCTION public.handle_order_activity_tracking()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_trip_time integer := 0;
  v_earnings numeric := 0.0;
  v_date date;
BEGIN
  -- Track changes to completed, delivered, or cancelled status
  IF NEW.order_status IS DISTINCT FROM OLD.order_status THEN
    v_date := (COALESCE(NEW.completed_at, NEW.cancelled_at, now()) AT TIME ZONE 'Asia/Kolkata')::date;
    
    -- Completed / Delivered
    IF NEW.order_status IN ('completed', 'delivered') AND NEW.rider_id IS NOT NULL THEN
      -- Calculate trip time in seconds
      IF NEW.time_taken_seconds IS NOT NULL AND NEW.time_taken_seconds > 0 THEN
        v_trip_time := NEW.time_taken_seconds;
      ELSE
        -- Fallback to difference between completed_at and picked_up_at / accepted_at
        IF NEW.completed_at IS NOT NULL THEN
          v_trip_time := EXTRACT(EPOCH FROM (NEW.completed_at - COALESCE(NEW.picked_up_at, NEW.accepted_at, NEW.created_at)))::integer;
          IF v_trip_time < 0 THEN v_trip_time := 0; END IF;
        END IF;
      END IF;

      v_earnings := COALESCE(NEW.rider_earning, 0.0);

      INSERT INTO public.rider_daily_activity (rider_id, date, active_seconds, completed_orders, earnings)
      VALUES (NEW.rider_id, v_date, v_trip_time, 1, v_earnings)
      ON CONFLICT (rider_id, date) DO UPDATE
      SET active_seconds = rider_daily_activity.active_seconds + v_trip_time,
          completed_orders = rider_daily_activity.completed_orders + 1,
          earnings = rider_daily_activity.earnings + v_earnings,
          updated_at = now();
          
    -- Cancelled
    ELSIF NEW.order_status = 'cancelled' AND NEW.rider_id IS NOT NULL THEN
      INSERT INTO public.rider_daily_activity (rider_id, date, cancelled_orders)
      VALUES (NEW.rider_id, v_date, 1)
      ON CONFLICT (rider_id, date) DO UPDATE
      SET cancelled_orders = rider_daily_activity.cancelled_orders + 1,
          updated_at = now();
    END IF;
  END IF;
  RETURN NEW;
END;
$function$
"
public,handle_promo_usage_changes,,"CREATE OR REPLACE FUNCTION public.handle_promo_usage_changes()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
  IF TG_OP = 'INSERT' THEN
    UPDATE public.promo_codes
    SET uses_count = uses_count + 1
    WHERE id = NEW.promo_code_id;
  ELSIF TG_OP = 'DELETE' THEN
    UPDATE public.promo_codes
    SET uses_count = GREATEST(0, uses_count - 1)
    WHERE id = OLD.promo_code_id;
  END IF;
  RETURN NULL;
END;
$function$
"
public,handle_rider_status_change,,"CREATE OR REPLACE FUNCTION public.handle_rider_status_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
BEGIN
  -- If account_status is toggled
  IF NEW.account_status IS DISTINCT FROM OLD.account_status THEN
    -- Going online
    IF NEW.account_status = 'online' THEN
      INSERT INTO public.rider_daily_activity (rider_id, date, last_online_toggle_at)
      VALUES (NEW.id, (now() AT TIME ZONE 'Asia/Kolkata')::date, now())
      ON CONFLICT (rider_id, date) DO UPDATE
      SET last_online_toggle_at = now(),
          updated_at = now();
    -- Going offline
    ELSIF NEW.account_status = 'offline' AND OLD.account_status = 'online' THEN
      UPDATE public.rider_daily_activity
      SET online_seconds = online_seconds + EXTRACT(EPOCH FROM (now() - last_online_toggle_at))::integer,
          last_online_toggle_at = NULL,
          updated_at = now()
      WHERE rider_id = NEW.id AND last_online_toggle_at IS NOT NULL;
    END IF;
  END IF;
  RETURN NEW;
END;
$function$
"
public,initiate_withdrawal,"p_amount numeric, p_user_id uuid","CREATE OR REPLACE FUNCTION public.initiate_withdrawal(p_amount numeric, p_user_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_rider_id uuid;
    v_wallet_balance numeric;
    v_payout_account_id uuid;
    v_payout_status public.cashfree_beneficiary_status_enum;
    v_transfer_id text;
    v_withdrawal_id uuid;
    v_beneficiary_id text;
    v_payout_method public.payout_method_enum;
    v_upi_vpa text;
BEGIN
    -- 1. Validation for withdrawal amount
    IF p_amount <= 0 THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', 'Invalid withdrawal amount'
        );
    END IF;

    -- 2. Fetch rider and lock row to prevent race conditions on balance updates
    SELECT id, wallet_balance INTO v_rider_id, v_wallet_balance
    FROM public.riders
    WHERE user_id = p_user_id
    FOR UPDATE;

    IF v_rider_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'Rider profile not found');
    END IF;

    -- 3. Fetch payout account details (limit to 1 account to prevent multi-row return database exception)
    SELECT id, cashfree_beneficiary_status, beneficiary_id, payout_method, upi_vpa
    INTO v_payout_account_id, v_payout_status, v_beneficiary_id, v_payout_method, v_upi_vpa
    FROM public.rider_payout_accounts
    WHERE user_id = p_user_id
    ORDER BY created_at DESC
    LIMIT 1;

    IF v_payout_account_id IS NULL OR v_beneficiary_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'Payout account beneficiary ID not found');
    END IF;

    -- 4. Check wallet balance
    IF v_wallet_balance < p_amount THEN
        RETURN jsonb_build_object('success', false, 'message', 'Insufficient wallet balance');
    END IF;

    -- 5. Generate unique transfer_id using WDPY prefix
    v_transfer_id := public.generate_unique_transfer_id();

    -- 6. Deduct wallet balance (rider row is already locked)
    UPDATE public.riders
    SET wallet_balance = wallet_balance - p_amount
    WHERE id = v_rider_id;

    -- 7. Insert pending withdrawal (logs trigger automatically)
    INSERT INTO public.rider_withdrawals (
        rider_id,
        user_id,
        amount,
        transfer_id,
        status
    ) VALUES (
        v_rider_id,
        p_user_id,
        p_amount,
        v_transfer_id,
        'pending'::public.rider_withdrawal_status_enum
    ) RETURNING id INTO v_withdrawal_id;

    RETURN jsonb_build_object(
        'success', true,
        'rider_id', v_rider_id,
        'withdrawal_id', v_withdrawal_id,
        'transfer_id', v_transfer_id,
        'beneficiary_id', v_beneficiary_id,
        'payout_method', v_payout_method,
        'upi_vpa', v_upi_vpa
    );
END;
$function$
"
public,log_rider_withdrawal_event,,"CREATE OR REPLACE FUNCTION public.log_rider_withdrawal_event()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
    IF (TG_OP = 'INSERT') THEN
        INSERT INTO public.rider_withdrawal_events (
            withdrawal_id,
            event_type,
            old_status,
            new_status,
            response
        ) VALUES (
            NEW.id,
            'initiated',
            NULL,
            NEW.status,
            NEW.cashfree_response
        );
    ELSIF (TG_OP = 'UPDATE') THEN
        -- Only log if status changed, response metadata changed, or reference id changed
        IF (OLD.status != NEW.status OR OLD.cashfree_response IS DISTINCT FROM NEW.cashfree_response OR OLD.cashfree_reference_id IS DISTINCT FROM NEW.cashfree_reference_id) THEN
            INSERT INTO public.rider_withdrawal_events (
                withdrawal_id,
                event_type,
                old_status,
                new_status,
                response
            ) VALUES (
                NEW.id,
                CASE 
                    WHEN OLD.status != NEW.status THEN 'status_change'
                    ELSE 'metadata_update'
                END,
                OLD.status,
                NEW.status,
                NEW.cashfree_response
            );
        END IF;
    END IF;
    RETURN NEW;
END;
$function$
"
public,on_intercity_request_change,,"CREATE OR REPLACE FUNCTION public.on_intercity_request_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_rider_user_id uuid := NULL;
    v_passenger_user_id uuid := NEW.sender_id;
    v_title text := '';
    v_body text := '';
    v_notify_user_id uuid := NULL;
BEGIN
    -- Fetch the rider's user_id
    SELECT user_id INTO v_rider_user_id FROM public.riders WHERE id = NEW.traveller_id;

    -- A) When a request is INSERTED (request_sent)
    IF TG_OP = 'INSERT' THEN
        IF NEW.initiated_by = 'sender' THEN
            -- Sender is passenger, notify rider (traveller)
            v_notify_user_id := v_rider_user_id;
            v_title := 'New Request Received 📦';
            v_body := 'A passenger wants you to carry their shipment or ride. Open details to discuss!';
        ELSE
            -- Initiator is rider, notify passenger (sender)
            v_notify_user_id := v_passenger_user_id;
            v_title := 'New Offer Received ⚡';
            v_body := 'A traveller offered to carry your shipment or ride. Open details to discuss!';
        END IF;

    -- B) When request is UPDATED and status changes
    ELSIF TG_OP = 'UPDATE' AND OLD.status IS DISTINCT FROM NEW.status THEN
        IF NEW.status = 'discussion_started' THEN
            -- Discussion accepted, notify the initiator of request
            IF NEW.initiated_by = 'sender' THEN
                v_notify_user_id := v_passenger_user_id;
            ELSE
                v_notify_user_id := v_rider_user_id;
            END IF;
            v_title := 'Discussion Opened 💬';
            v_body := 'The conversation has been accepted. You can now chat and negotiate the fare!';
            
        ELSIF NEW.status = 'confirmed' THEN
            -- Let's notify passenger (sender) to complete payment
            v_notify_user_id := v_passenger_user_id;
            v_title := 'Booking Confirmed! 🎉';
            v_body := 'Both parties have confirmed the booking. Please proceed to payment.';
            
        ELSIF NEW.status = 'paid' THEN
            -- Passenger paid, notify traveller (rider)
            v_notify_user_id := v_rider_user_id;
            v_title := 'Payment Verified! 💳';
            v_body := 'Passenger has paid for the trip. You can now start the transit.';
            
        ELSIF NEW.status = 'in_progress' THEN
            -- Trip started, notify passenger
            v_notify_user_id := v_passenger_user_id;
            v_title := 'Trip on the Way 🗺️';
            v_body := 'Traveller has collected the parcel/started the ride. Track live updates!';
            
        ELSIF NEW.status = 'completed' THEN
            -- Completed, notify passenger
            v_notify_user_id := v_passenger_user_id;
            v_title := 'Trip Completed Successfully 🎉';
            v_body := 'Your shipment/ride has been delivered. Thank the traveller!';
        END IF;
    END IF;

    -- Send push notification if a target recipient is identified
    IF v_notify_user_id IS NOT NULL THEN
        PERFORM public.send_push_notification_fnc(
            v_notify_user_id,
            v_title,
            v_body,
            jsonb_build_object(
                'type', 'intercity_request',
                'request_id', NEW.id,
                'order_id', NEW.parcel_id,
                'rider_id', NEW.traveller_id,
                'status', NEW.status
            )
        );
    END IF;

    -- In case of final confirmed status, let's also notify the rider (separate call since both need it)
    IF TG_OP = 'UPDATE' AND OLD.status IS DISTINCT FROM NEW.status AND NEW.status = 'confirmed' THEN
        IF v_rider_user_id IS NOT NULL THEN
            PERFORM public.send_push_notification_fnc(
                v_rider_user_id,
                'Booking Confirmed! 🎉',
                'Booking is confirmed by the passenger. Awaiting payment.',
                jsonb_build_object(
                    'type', 'intercity_request',
                    'request_id', NEW.id,
                    'order_id', NEW.parcel_id,
                    'rider_id', NEW.traveller_id,
                    'status', NEW.status
                )
            );
        END IF;
    END IF;

    RETURN NEW;
END;
$function$
"
public,on_new_chat_message,,"CREATE OR REPLACE FUNCTION public.on_new_chat_message()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_recipient_user_id uuid := NULL;
    v_customer_user_id uuid := NULL;
    v_rider_user_id uuid := NULL;
    v_order_rider_id uuid := NULL;
    v_sender_name text := 'Someone';
BEGIN
    -- Get sender name if possible
    SELECT COALESCE(full_name, 'Someone') INTO v_sender_name 
    FROM public.users 
    WHERE id = NEW.sender_id;

    IF NEW.order_id IS NOT NULL THEN
        -- Order chat
        SELECT user_id, rider_id INTO v_customer_user_id, v_order_rider_id 
        FROM public.orders 
        WHERE id = NEW.order_id;
        
        -- Get rider's user_id
        IF NEW.rider_id IS NOT NULL THEN
            SELECT user_id INTO v_rider_user_id FROM public.riders WHERE id = NEW.rider_id;
        ELSIF v_order_rider_id IS NOT NULL THEN
            SELECT user_id INTO v_rider_user_id FROM public.riders WHERE id = v_order_rider_id;
        END IF;

        IF NEW.sender_id = v_customer_user_id THEN
            v_recipient_user_id := v_rider_user_id;
        ELSIF NEW.sender_id = v_rider_user_id THEN
            v_recipient_user_id := v_customer_user_id;
        END IF;
    ELSE
        -- Support chat
        IF NEW.user_id IS NOT NULL AND NEW.sender_id != NEW.user_id THEN
            v_recipient_user_id := NEW.user_id;
        END IF;
    END IF;

    -- Send notification if recipient is determined
    IF v_recipient_user_id IS NOT NULL THEN
        PERFORM public.send_push_notification_fnc(
            v_recipient_user_id,
            v_sender_name,
            NEW.message,
            jsonb_build_object(
                'type', 'chat_message',
                'order_id', NEW.order_id,
                'message_id', NEW.id,
                'sender_type', NEW.sender_type
            )
        );
    END IF;

    RETURN NEW;
END;
$function$
"
public,on_notification_insert,,"CREATE OR REPLACE FUNCTION public.on_notification_insert()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
    -- Call delivery helper to trigger FCM send-push-notification edge function
    PERFORM public.deliver_push_notification_http_fnc(
        NEW.user_id,
        NEW.title,
        NEW.body,
        NEW.payload || jsonb_build_object(
            'notification_id', NEW.id,
            'type', NEW.notification_type,
            'reference_id', NEW.reference_id,
            'reference_type', NEW.reference_type
        )
    );
    RETURN NEW;
END;
$function$
"
public,on_order_status_update,,"CREATE OR REPLACE FUNCTION public.on_order_status_update()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_rider_user_id uuid := NULL;
    v_title text := '';
    v_body text := '';
BEGIN
    -- Check if status actually changed
    IF OLD.order_status IS DISTINCT FROM NEW.order_status THEN
        -- 1. Notify Passenger (NEW.user_id) for status updates
        IF NEW.order_status = 'accepted' THEN
            v_title := 'Order Accepted';
            v_body := 'A rider has accepted your order!';
        ELSIF NEW.order_status = 'rider_arrived' THEN
            v_title := 'Rider Arrived';
            v_body := 'Your rider has arrived at the pickup location.';
        ELSIF NEW.order_status = 'picked_up' THEN
            v_title := 'Order Picked Up';
            v_body := 'Your order is on the way!';
        ELSIF NEW.order_status = 'completed' THEN
            v_title := 'Order Completed';
            v_body := 'Your trip has been completed successfully.';
        ELSIF NEW.order_status = 'cancelled' THEN
            v_title := 'Order Cancelled';
            v_body := 'Your order has been cancelled.';
        END IF;

        -- Send to passenger
        IF v_title != '' AND v_body != '' AND NEW.user_id IS NOT NULL THEN
            PERFORM public.send_push_notification_fnc(
                NEW.user_id,
                v_title,
                v_body,
                jsonb_build_object(
                    'type', 'order_status',
                    'order_id', NEW.id,
                    'status', NEW.order_status
                )
            );
        END IF;

        -- 2. Notify Rider if order was cancelled
        IF NEW.order_status = 'cancelled' AND NEW.rider_id IS NOT NULL THEN
            SELECT user_id INTO v_rider_user_id FROM public.riders WHERE id = NEW.rider_id;
            
            IF v_rider_user_id IS NOT NULL THEN
                PERFORM public.send_push_notification_fnc(
                    v_rider_user_id,
                    'Order Cancelled',
                    'The order you accepted has been cancelled by the customer.',
                    jsonb_build_object(
                        'type', 'order_status',
                        'order_id', NEW.id,
                        'status', 'cancelled'
                    )
                );
            END IF;
        END IF;
    END IF;

    RETURN NEW;
END;
$function$
"
public,on_rider_assignment_change,,"CREATE OR REPLACE FUNCTION public.on_rider_assignment_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_rider_user_id uuid := NULL;
BEGIN
    -- Notify when status is set or updated to 'sent'
    IF NEW.assignment_status = 'sent' AND (TG_OP = 'INSERT' OR OLD.assignment_status IS DISTINCT FROM 'sent') THEN
        SELECT user_id INTO v_rider_user_id FROM public.riders WHERE id = NEW.rider_id;

        IF v_rider_user_id IS NOT NULL THEN
            PERFORM public.send_push_notification_fnc(
                v_rider_user_id,
                'New Order Request',
                'You have a new order request nearby!',
                jsonb_build_object(
                    'type', 'order_assignment',
                    'order_id', NEW.order_id,
                    'assignment_id', NEW.id
                )
            );
        END IF;
    END IF;

    RETURN NEW;
END;
$function$
"
public,on_rider_review_insert,,"CREATE OR REPLACE FUNCTION public.on_rider_review_insert()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_rider_user_id uuid := NULL;
    v_title text := 'New Review Received';
    v_body text := '';
BEGIN
    SELECT user_id INTO v_rider_user_id FROM public.riders WHERE id = NEW.rider_id;

    IF v_rider_user_id IS NOT NULL THEN
        IF NEW.rating = 5 THEN
            v_title := 'You''ve been rated 5-Star! 🌟';
            v_body := 'Excellent job! A passenger rated you 5 stars. Keep up the amazing work!';
        ELSE
            v_title := 'New Rating Received ⭐';
            v_body := 'You received a new ' || NEW.rating::text || '-star rating from your recent ride.';
        END IF;

        IF NEW.comment IS NOT NULL AND NEW.comment != '' THEN
            v_body := v_body || ' Feedback: ""' || substring(NEW.comment from 1 for 40) || '...""';
        END IF;

        PERFORM public.send_push_notification_fnc(
            v_rider_user_id,
            v_title,
            v_body,
            jsonb_build_object(
                'type', 'new_rating',
                'rating', NEW.rating,
                'review_id', NEW.id
            )
        );
    END IF;

    RETURN NEW;
END;
$function$
"
public,on_rider_wallet_balance_update,,"CREATE OR REPLACE FUNCTION public.on_rider_wallet_balance_update()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
    -- If wallet balance drops below -500 (meaning they owe more than 500 rupees cash collected)
    -- And it was not below -500 before (to avoid spamming on subsequent updates)
    IF NEW.wallet_balance < -500 AND (OLD.wallet_balance IS NULL OR OLD.wallet_balance >= -500) THEN
        PERFORM public.send_push_notification_fnc(
            NEW.user_id,
            'COD Settlement Required 💳',
            'Your cash collections exceed the allowed limit. Please pay your COD settlement of ₹' || ABS(NEW.wallet_balance)::text || ' to continue receiving ride requests.',
            jsonb_build_object(
                'type', 'cod_settlement',
                'balance', NEW.wallet_balance
            )
        );
    END IF;
    RETURN NEW;
END;
$function$
"
public,prevent_wallet_transaction_modifications,,"CREATE OR REPLACE FUNCTION public.prevent_wallet_transaction_modifications()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    RAISE EXCEPTION 'Immutable Ledger Error: Wallet transactions cannot be updated or deleted.';
END;
$function$
"
public,reject_order,"p_order_id uuid, p_rider_id uuid, p_rejection_reason text","CREATE OR REPLACE FUNCTION public.reject_order(p_order_id uuid, p_rider_id uuid, p_rejection_reason text DEFAULT NULL::text)
 RETURNS json
 LANGUAGE plpgsql
AS $function$

DECLARE

    v_order RECORD;

BEGIN



    -- =====================================================
    -- FETCH ORDER
    -- =====================================================

    SELECT *

    INTO v_order

    FROM orders

    WHERE id = p_order_id;



    IF v_order IS NULL THEN

        RETURN json_build_object(

            'success', false,

            'message', 'Order not found'

        );

    END IF;



    -- =====================================================
    -- VALIDATE STATUS
    -- =====================================================

    IF v_order.order_status NOT IN (

        'created',

        'searching'

    ) THEN

        RETURN json_build_object(

            'success', false,

            'message', 'Order no longer available'

        );

    END IF;



    -- =====================================================
    -- UPDATE ASSIGNMENT LOG
    -- =====================================================

    UPDATE order_assignment_logs

    SET

        assignment_status = 'rejected',

        rejection_reason = p_rejection_reason,

        responded_at = now()

    WHERE

        order_id = p_order_id

        AND rider_id = p_rider_id

        AND assignment_status = 'sent';



    -- =====================================================
    -- INSERT STATUS HISTORY
    -- =====================================================

    INSERT INTO order_status_history (

        order_id,

        previous_status,

        new_status,

        changed_by,

        changed_by_rider_id,

        notes,

        metadata

    )

    VALUES (

        p_order_id,

        v_order.order_status,

        v_order.order_status,

        'rider',

        p_rider_id,

        'Rider rejected assignment',

        json_build_object(

            'rejection_reason',

            p_rejection_reason

        )

    );



    RETURN json_build_object(

        'success', true,

        'message', 'Order rejected successfully'

    );

END;

$function$
"
public,send_admin_push_notification,"p_recipient_type text, p_city text, p_title text, p_body text, p_data jsonb","CREATE OR REPLACE FUNCTION public.send_admin_push_notification(p_recipient_type text, p_city text, p_title text, p_body text, p_data jsonb DEFAULT '{}'::jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_user_id uuid;
BEGIN
    IF p_recipient_type = 'riders' THEN
        FOR v_user_id IN 
            SELECT DISTINCT r.user_id 
            FROM public.riders r
            WHERE p_city IS NULL OR EXISTS (
                SELECT 1 FROM public.orders o 
                WHERE o.rider_id = r.id AND (o.pickup_city = p_city OR o.destination_city = p_city)
                LIMIT 1
            )
        LOOP
            PERFORM public.send_push_notification_fnc(v_user_id, p_title, p_body, p_data);
        END LOOP;
        
    ELSIF p_recipient_type = 'users' THEN
        FOR v_user_id IN 
            SELECT DISTINCT u.id 
            FROM public.users u
            WHERE (p_city IS NULL OR EXISTS (
                SELECT 1 FROM public.orders o 
                WHERE o.user_id = u.id AND (o.pickup_city = p_city OR o.destination_city = p_city)
                LIMIT 1
            ))
            AND NOT EXISTS (SELECT 1 FROM public.riders r WHERE r.user_id = u.id)
        LOOP
            PERFORM public.send_push_notification_fnc(v_user_id, p_title, p_body, p_data);
        END LOOP;
        
    ELSE
        FOR v_user_id IN 
            SELECT id FROM public.users u
            WHERE p_city IS NULL OR EXISTS (
                SELECT 1 FROM public.orders o 
                WHERE o.user_id = u.id AND (o.pickup_city = p_city OR o.destination_city = p_city)
                LIMIT 1
            )
        LOOP
            PERFORM public.send_push_notification_fnc(v_user_id, p_title, p_body, p_data);
        END LOOP;
    END IF;
END;
$function$
"
public,send_push_notification_fnc,"p_user_id uuid, p_title text, p_body text, p_data jsonb","CREATE OR REPLACE FUNCTION public.send_push_notification_fnc(p_user_id uuid, p_title text, p_body text, p_data jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_notification_type text := COALESCE(p_data->>'type', 'general');
    v_reference_id uuid := NULL;
    v_reference_type text := NULL;
BEGIN
    -- Extract reference info if present
    IF p_data ? 'order_id' THEN
        BEGIN
            v_reference_id := (p_data->>'order_id')::uuid;
            v_reference_type := 'order';
        EXCEPTION WHEN OTHERS THEN
            -- Ignore formatting errors
        END;
    ELSIF p_data ? 'payment_id' THEN
        BEGIN
            v_reference_id := (p_data->>'payment_id')::uuid;
            v_reference_type := 'payment';
        EXCEPTION WHEN OTHERS THEN
            -- Ignore formatting errors
        END;
    END IF;

    -- Insert into notifications log table (which triggers async HTTP delivery)
    INSERT INTO public.notifications (
        user_id,
        title,
        body,
        notification_type,
        reference_id,
        reference_type,
        payload
    ) VALUES (
        p_user_id,
        p_title,
        p_body,
        v_notification_type,
        v_reference_id,
        v_reference_type,
        p_data
    );
END;
$function$
"
public,set_compliance_retention,,"CREATE OR REPLACE FUNCTION public.set_compliance_retention()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    IF (NEW.order_status IN ('completed', 'delivered') AND OLD.order_status NOT IN ('completed', 'delivered')) THEN
        NEW.compliance_retention_until := NOW() + INTERVAL '5 years';
    END IF;
    RETURN NEW;
END;
$function$
"
public,sync_travel_plan_status_after,,"CREATE OR REPLACE FUNCTION public.sync_travel_plan_status_after()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_active_bookings INT;
    v_max_bookings INT;
    v_plan_status public.travel_plan_status_enum;
    v_route_id uuid;
BEGIN
    IF TG_OP = 'DELETE' THEN
        v_route_id := OLD.route_id;
    ELSE
        v_route_id := NEW.route_id;
    END IF;

    IF v_route_id IS NULL THEN
        RETURN NULL;
    END IF;

    SELECT max_bookings, status INTO v_max_bookings, v_plan_status
    FROM public.rider_travel_plans
    WHERE id = v_route_id
    FOR UPDATE;

    SELECT COUNT(*) INTO v_active_bookings
    FROM public.intercity_requests
    WHERE route_id = v_route_id
      AND status IN ('confirmed', 'paid');

    IF v_active_bookings >= v_max_bookings THEN
        IF v_plan_status = 'active'::public.travel_plan_status_enum THEN
            UPDATE public.rider_travel_plans 
            SET status = 'fully_booked'::public.travel_plan_status_enum 
            WHERE id = v_route_id;
        END IF;
    ELSE
        -- Revive only fully_booked plans. Never touch expired or cancelled plans.
        IF v_plan_status = 'fully_booked'::public.travel_plan_status_enum THEN
            UPDATE public.rider_travel_plans 
            SET status = 'active'::public.travel_plan_status_enum 
            WHERE id = v_route_id;
        END IF;
    END IF;

    RETURN NULL;
END;
$function$
"
public,timeout_assignment,"p_order_id uuid, p_rider_id uuid","CREATE OR REPLACE FUNCTION public.timeout_assignment(p_order_id uuid, p_rider_id uuid)
 RETURNS json
 LANGUAGE plpgsql
AS $function$

BEGIN



    UPDATE order_assignment_logs

    SET

        assignment_status = 'timed_out',

        responded_at = now()

    WHERE

        order_id = p_order_id

        AND rider_id = p_rider_id

        AND assignment_status = 'sent';



    RETURN json_build_object(

        'success', true,

        'message', 'Assignment timed out'

    );

END;

$function$
"
public,trg_orders_order_code,,"CREATE OR REPLACE FUNCTION public.trg_orders_order_code()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    IF NEW.order_code IS NULL OR NEW.order_code = '' OR NEW.order_code LIKE 'WX%' THEN
        NEW.order_code := public.generate_unique_order_code(NEW.order_type::text);
    END IF;
    RETURN NEW;
END;
$function$
"
public,trg_payments_payment_code,,"CREATE OR REPLACE FUNCTION public.trg_payments_payment_code()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    IF NEW.payment_code IS NULL OR NEW.payment_code = '' THEN
        NEW.payment_code := public.generate_unique_payment_code();
    END IF;
    RETURN NEW;
END;
$function$
"
public,trg_rider_withdrawals_transfer_id,,"CREATE OR REPLACE FUNCTION public.trg_rider_withdrawals_transfer_id()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    IF NEW.transfer_id IS NULL OR NEW.transfer_id = '' OR NOT (NEW.transfer_id LIKE 'WDPY%') THEN
        NEW.transfer_id := public.generate_unique_transfer_id();
    END IF;
    RETURN NEW;
END;
$function$
"
public,trg_travel_plans_plan_code,,"CREATE OR REPLACE FUNCTION public.trg_travel_plans_plan_code()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    IF NEW.plan_code IS NULL OR NEW.plan_code = '' THEN
        NEW.plan_code := public.generate_unique_plan_code();
    END IF;
    RETURN NEW;
END;
$function$
"
public,trg_users_user_code,,"CREATE OR REPLACE FUNCTION public.trg_users_user_code()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    IF NEW.user_code IS NULL OR NEW.user_code = '' THEN
        NEW.user_code := public.generate_unique_user_code();
    END IF;
    RETURN NEW;
END;
$function$
"
public,update_rider_average_rating,,"CREATE OR REPLACE FUNCTION public.update_rider_average_rating()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_rider_id UUID;
BEGIN
  IF TG_OP = 'DELETE' THEN
    v_rider_id := OLD.rider_id;
  ELSE
    v_rider_id := NEW.rider_id;
  END IF;

  UPDATE public.riders
  SET rating = (
    SELECT CASE 
      WHEN COUNT(rating) > 0 THEN
        GREATEST(
          ROUND(
            (SUM(rating) + 25.0)::numeric / (COUNT(rating) + 5),
            2
          ),
          3.5
        )
      ELSE 5.0
    END
    FROM public.rider_reviews
    WHERE rider_id = v_rider_id
  )
  WHERE id = v_rider_id;
  
  RETURN NULL;
END;
$function$
"
public,update_updated_at_column,,"CREATE OR REPLACE FUNCTION public.update_updated_at_column()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$function$
"
public,validate_and_calculate_promo,"p_code character varying, p_order_value numeric, p_user_id uuid","CREATE OR REPLACE FUNCTION public.validate_and_calculate_promo(p_code character varying, p_order_value numeric, p_user_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_promo record;
  v_used_count integer;
  v_discount numeric := 0.00;
BEGIN
  -- 1. Fetch promo details
  SELECT * INTO v_promo
  FROM public.promo_codes
  WHERE code = UPPER(p_code)
    AND is_active = true
    AND expires_at > now();

  IF v_promo.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'message', 'Invalid or expired promo code');
  END IF;

  -- 1.5 Verify audience constraints
  IF v_promo.audience_type = 'restricted' THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.promo_code_users
      WHERE promo_code_id = v_promo.id AND user_id = p_user_id
    ) THEN
      RETURN jsonb_build_object('success', false, 'message', 'This promo code is not valid for your account');
    END IF;
  END IF;

  -- 2. Verify global usage limit
  IF v_promo.max_uses IS NOT NULL AND v_promo.uses_count >= v_promo.max_uses THEN
    RETURN jsonb_build_object('success', false, 'message', 'Promo code usage limit has been reached');
  END IF;

  -- 3. Verify min order value
  IF p_order_value < v_promo.min_order_value THEN
    RETURN jsonb_build_object('success', false, 'message', 'Minimum order value of ₹' || v_promo.min_order_value::text || ' is required');
  END IF;

  -- 4. Verify single usage per user
  SELECT count(*) INTO v_used_count
  FROM public.user_promo_usages
  WHERE user_id = p_user_id AND promo_code_id = v_promo.id;

  IF v_used_count > 0 THEN
    RETURN jsonb_build_object('success', false, 'message', 'You have already used this promo code');
  END IF;

  -- 5. Calculate discount amount
  IF v_promo.discount_type = 'fixed_amount' THEN
    v_discount := LEAST(v_promo.discount_value, p_order_value);
  ELSIF v_promo.discount_type = 'percentage' THEN
    v_discount := (p_order_value * (v_promo.discount_value / 100.00));
    IF v_promo.max_discount IS NOT NULL THEN
      v_discount := LEAST(v_discount, v_promo.max_discount);
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'promo_id', v_promo.id,
    'discount_amount', round(v_discount, 2),
    'discount_type', v_promo.discount_type,
    'discount_value', v_promo.discount_value
  );
END;
$function$
"

event_object_table,trigger_name,action_timing,event_manipulation,action_statement
intercity_requests,trigger_intercity_request_change,AFTER,UPDATE,EXECUTE FUNCTION on_intercity_request_change()
intercity_requests,trigger_intercity_request_change,AFTER,INSERT,EXECUTE FUNCTION on_intercity_request_change()
intercity_requests,trigger_sync_travel_plan_status,AFTER,INSERT,EXECUTE FUNCTION sync_travel_plan_status_after()
intercity_requests,trigger_sync_travel_plan_status,AFTER,UPDATE,EXECUTE FUNCTION sync_travel_plan_status_after()
intercity_requests,trigger_sync_travel_plan_status,AFTER,DELETE,EXECUTE FUNCTION sync_travel_plan_status_after()
notifications,trigger_notification_insert,AFTER,INSERT,EXECUTE FUNCTION on_notification_insert()
order_chat_messages,trigger_new_chat_message,AFTER,INSERT,EXECUTE FUNCTION on_new_chat_message()
orders,trigger_order_status_update,AFTER,UPDATE,EXECUTE FUNCTION on_order_status_update()
orders,on_order_activity_tracking,AFTER,UPDATE,EXECUTE FUNCTION handle_order_activity_tracking()
orders,trg_orders_compliance_retention,BEFORE,UPDATE,EXECUTE FUNCTION set_compliance_retention()
orders,trg_populate_order_code,BEFORE,INSERT,EXECUTE FUNCTION trg_orders_order_code()
payments,trg_populate_payment_code,BEFORE,INSERT,EXECUTE FUNCTION trg_payments_payment_code()
police_sos_logs,trg_police_sos_reference_code,BEFORE,INSERT,EXECUTE FUNCTION generate_police_reference_code()
rider_assignments,trigger_rider_assignment_change,AFTER,INSERT,EXECUTE FUNCTION on_rider_assignment_change()
rider_assignments,trigger_rider_assignment_change,AFTER,UPDATE,EXECUTE FUNCTION on_rider_assignment_change()
rider_kyc,trigger_create_rider_profile,AFTER,UPDATE,EXECUTE FUNCTION create_rider_profile_on_activation()
rider_payout_accounts,trigger_check_payout_update_limit,BEFORE,UPDATE,EXECUTE FUNCTION check_payout_update_limit()
rider_payout_accounts,trigger_generate_beneficiary_id,BEFORE,INSERT,EXECUTE FUNCTION generate_rider_beneficiary_id()
rider_payout_accounts,trigger_check_payout_update_limit,BEFORE,INSERT,EXECUTE FUNCTION check_payout_update_limit()
rider_reviews,trigger_rider_review_insert,AFTER,INSERT,EXECUTE FUNCTION on_rider_review_insert()
rider_reviews,tr_update_rider_average_rating,AFTER,UPDATE,EXECUTE FUNCTION update_rider_average_rating()
rider_reviews,tr_update_rider_average_rating,AFTER,DELETE,EXECUTE FUNCTION update_rider_average_rating()
rider_reviews,tr_update_rider_average_rating,AFTER,INSERT,EXECUTE FUNCTION update_rider_average_rating()
rider_travel_plans,prevent_delete_active_travel_plan,BEFORE,DELETE,EXECUTE FUNCTION check_travel_plan_active_bookings()
rider_travel_plans,trg_populate_plan_code,BEFORE,INSERT,EXECUTE FUNCTION trg_travel_plans_plan_code()
rider_withdrawals,trg_populate_transfer_id,BEFORE,INSERT,EXECUTE FUNCTION trg_rider_withdrawals_transfer_id()
rider_withdrawals,log_withdrawal_event,AFTER,UPDATE,EXECUTE FUNCTION log_rider_withdrawal_event()
rider_withdrawals,set_updated_at,BEFORE,UPDATE,EXECUTE FUNCTION update_updated_at_column()
rider_withdrawals,log_withdrawal_event,AFTER,INSERT,EXECUTE FUNCTION log_rider_withdrawal_event()
riders,trigger_rider_wallet_balance_update,AFTER,UPDATE,EXECUTE FUNCTION on_rider_wallet_balance_update()
riders,trigger_assign_nearby_orders,AFTER,UPDATE,EXECUTE FUNCTION assign_nearby_searching_orders_to_rider()
riders,on_rider_status_change,AFTER,UPDATE,EXECUTE FUNCTION handle_rider_status_change()
user_promo_usages,trigger_handle_promo_usage_changes,AFTER,DELETE,EXECUTE FUNCTION handle_promo_usage_changes()
user_promo_usages,trigger_handle_promo_usage_changes,AFTER,INSERT,EXECUTE FUNCTION handle_promo_usage_changes()
users,trg_populate_user_code,BEFORE,INSERT,EXECUTE FUNCTION trg_users_user_code()
wallet_transactions,trigger_prevent_wallet_transaction_mods,BEFORE,UPDATE,EXECUTE FUNCTION prevent_wallet_transaction_modifications()
wallet_transactions,trigger_prevent_wallet_transaction_mods,BEFORE,DELETE,EXECUTE FUNCTION prevent_wallet_transaction_modifications()

schemaname,tablename,rowsecurity
public,order_chat_messages,true
public,wallet_transactions,true
public,pricing_change_logs,true
public,wallet_audit_logs,true
public,rider_payout_accounts,true
public,rider_withdrawals,true
public,rider_withdrawal_events,true
public,promo_codes,true
public,promo_code_users,true
public,user_promo_usages,true
public,rider_daily_activity,true
public,users,true
public,user_device_tokens,true
public,rider_payout_updates_log,true
public,orders,true
public,admins,true
public,police_sos_logs,true
public,order_parcel_photos,true
public,parcel_compliance_reports,true
public,notifications,true
public,parcel_security_logs,true
public,order_declarations,true
public,admin_logs,true
public,user_devices,true
public,rider_travel_plans,true
public,rider_reviews,true
public,riders,true
public,pricing_config,true
public,pricing_zones,true
public,dispatch_config,true
public,distance_discounts,true
public,payments,true
public,order_verifications,true
public,intercity_requests,true
public,rider_subscription_history,true
public,order_status_history,true
public,rider_kyc,true
public,order_assignment_logs,true
public,rider_assignments,true

proname,pg_get_functiondef
update_updated_at_column,"CREATE OR REPLACE FUNCTION public.update_updated_at_column()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$function$
"
log_rider_withdrawal_event,"CREATE OR REPLACE FUNCTION public.log_rider_withdrawal_event()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
    IF (TG_OP = 'INSERT') THEN
        INSERT INTO public.rider_withdrawal_events (
            withdrawal_id,
            event_type,
            old_status,
            new_status,
            response
        ) VALUES (
            NEW.id,
            'initiated',
            NULL,
            NEW.status,
            NEW.cashfree_response
        );
    ELSIF (TG_OP = 'UPDATE') THEN
        -- Only log if status changed, response metadata changed, or reference id changed
        IF (OLD.status != NEW.status OR OLD.cashfree_response IS DISTINCT FROM NEW.cashfree_response OR OLD.cashfree_reference_id IS DISTINCT FROM NEW.cashfree_reference_id) THEN
            INSERT INTO public.rider_withdrawal_events (
                withdrawal_id,
                event_type,
                old_status,
                new_status,
                response
            ) VALUES (
                NEW.id,
                CASE 
                    WHEN OLD.status != NEW.status THEN 'status_change'
                    ELSE 'metadata_update'
                END,
                OLD.status,
                NEW.status,
                NEW.cashfree_response
            );
        END IF;
    END IF;
    RETURN NEW;
END;
$function$
"
update_rider_average_rating,"CREATE OR REPLACE FUNCTION public.update_rider_average_rating()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_rider_id UUID;
BEGIN
  IF TG_OP = 'DELETE' THEN
    v_rider_id := OLD.rider_id;
  ELSE
    v_rider_id := NEW.rider_id;
  END IF;

  UPDATE public.riders
  SET rating = (
    SELECT CASE 
      WHEN COUNT(rating) > 0 THEN
        GREATEST(
          ROUND(
            (SUM(rating) + 25.0)::numeric / (COUNT(rating) + 5),
            2
          ),
          3.5
        )
      ELSE 5.0
    END
    FROM public.rider_reviews
    WHERE rider_id = v_rider_id
  )
  WHERE id = v_rider_id;
  
  RETURN NULL;
END;
$function$
"
generate_police_reference_code,"CREATE OR REPLACE FUNCTION public.generate_police_reference_code()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_date text;
    v_random_sos text;
    v_random_sup text;
    v_code_sos text;
    v_code_sup text;
    v_exists boolean;
BEGIN
    v_date := to_char(NOW(), 'YYYYMMDD');
    
    -- Generate Police Reference Code (SOS-WDP-YYYYMMDD-XXXXXX)
    LOOP
        v_random_sos := upper(substring(md5(random()::text) from 1 for 6));
        v_code_sos := 'SOS-WDP-' || v_date || '-' || v_random_sos;
        
        SELECT EXISTS(SELECT 1 FROM public.police_sos_logs WHERE police_reference_code = v_code_sos) INTO v_exists;
        IF NOT v_exists THEN
            NEW.police_reference_code := v_code_sos;
            EXIT;
        END IF;
    END LOOP;
    
    -- Generate Support Ticket Code (SUP-YYYYMMDD-XXXXXX)
    LOOP
        v_random_sup := upper(substring(md5(random()::text) from 1 for 6));
        v_code_sup := 'SUP-' || v_date || '-' || v_random_sup;
        
        SELECT EXISTS(SELECT 1 FROM public.police_sos_logs WHERE support_ticket_code = v_code_sup) INTO v_exists;
        IF NOT v_exists THEN
            NEW.support_ticket_code := v_code_sup;
            EXIT;
        END IF;
    END LOOP;
    
    RETURN NEW;
END;
$function$
"
set_compliance_retention,"CREATE OR REPLACE FUNCTION public.set_compliance_retention()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    IF (NEW.order_status IN ('completed', 'delivered') AND OLD.order_status NOT IN ('completed', 'delivered')) THEN
        NEW.compliance_retention_until := NOW() + INTERVAL '5 years';
    END IF;
    RETURN NEW;
END;
$function$
"
generate_rider_beneficiary_id,"CREATE OR REPLACE FUNCTION public.generate_rider_beneficiary_id()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
    if new.beneficiary_id is null then
        new.beneficiary_id :=
            'WDR' || lpad(nextval('rider_beneficiary_seq')::text, 6, '0');
    end if;

    return new;
end;
$function$
"
on_notification_insert,"CREATE OR REPLACE FUNCTION public.on_notification_insert()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
    -- Call delivery helper to trigger FCM send-push-notification edge function
    PERFORM public.deliver_push_notification_http_fnc(
        NEW.user_id,
        NEW.title,
        NEW.body,
        NEW.payload || jsonb_build_object(
            'notification_id', NEW.id,
            'type', NEW.notification_type,
            'reference_id', NEW.reference_id,
            'reference_type', NEW.reference_type
        )
    );
    RETURN NEW;
END;
$function$
"
handle_rider_status_change,"CREATE OR REPLACE FUNCTION public.handle_rider_status_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
BEGIN
  -- If account_status is toggled
  IF NEW.account_status IS DISTINCT FROM OLD.account_status THEN
    -- Going online
    IF NEW.account_status = 'online' THEN
      INSERT INTO public.rider_daily_activity (rider_id, date, last_online_toggle_at)
      VALUES (NEW.id, (now() AT TIME ZONE 'Asia/Kolkata')::date, now())
      ON CONFLICT (rider_id, date) DO UPDATE
      SET last_online_toggle_at = now(),
          updated_at = now();
    -- Going offline
    ELSIF NEW.account_status = 'offline' AND OLD.account_status = 'online' THEN
      UPDATE public.rider_daily_activity
      SET online_seconds = online_seconds + EXTRACT(EPOCH FROM (now() - last_online_toggle_at))::integer,
          last_online_toggle_at = NULL,
          updated_at = now()
      WHERE rider_id = NEW.id AND last_online_toggle_at IS NOT NULL;
    END IF;
  END IF;
  RETURN NEW;
END;
$function$
"
handle_order_activity_tracking,"CREATE OR REPLACE FUNCTION public.handle_order_activity_tracking()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_trip_time integer := 0;
  v_earnings numeric := 0.0;
  v_date date;
BEGIN
  -- Track changes to completed, delivered, or cancelled status
  IF NEW.order_status IS DISTINCT FROM OLD.order_status THEN
    v_date := (COALESCE(NEW.completed_at, NEW.cancelled_at, now()) AT TIME ZONE 'Asia/Kolkata')::date;
    
    -- Completed / Delivered
    IF NEW.order_status IN ('completed', 'delivered') AND NEW.rider_id IS NOT NULL THEN
      -- Calculate trip time in seconds
      IF NEW.time_taken_seconds IS NOT NULL AND NEW.time_taken_seconds > 0 THEN
        v_trip_time := NEW.time_taken_seconds;
      ELSE
        -- Fallback to difference between completed_at and picked_up_at / accepted_at
        IF NEW.completed_at IS NOT NULL THEN
          v_trip_time := EXTRACT(EPOCH FROM (NEW.completed_at - COALESCE(NEW.picked_up_at, NEW.accepted_at, NEW.created_at)))::integer;
          IF v_trip_time < 0 THEN v_trip_time := 0; END IF;
        END IF;
      END IF;

      v_earnings := COALESCE(NEW.rider_earning, 0.0);

      INSERT INTO public.rider_daily_activity (rider_id, date, active_seconds, completed_orders, earnings)
      VALUES (NEW.rider_id, v_date, v_trip_time, 1, v_earnings)
      ON CONFLICT (rider_id, date) DO UPDATE
      SET active_seconds = rider_daily_activity.active_seconds + v_trip_time,
          completed_orders = rider_daily_activity.completed_orders + 1,
          earnings = rider_daily_activity.earnings + v_earnings,
          updated_at = now();
          
    -- Cancelled
    ELSIF NEW.order_status = 'cancelled' AND NEW.rider_id IS NOT NULL THEN
      INSERT INTO public.rider_daily_activity (rider_id, date, cancelled_orders)
      VALUES (NEW.rider_id, v_date, 1)
      ON CONFLICT (rider_id, date) DO UPDATE
      SET cancelled_orders = rider_daily_activity.cancelled_orders + 1,
          updated_at = now();
    END IF;
  END IF;
  RETURN NEW;
END;
$function$
"
check_payout_update_limit,"CREATE OR REPLACE FUNCTION public.check_payout_update_limit()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_update_count integer;
BEGIN
    -- Check if it's insert, or if it's update where rider-initiated fields changed
    IF (TG_OP = 'INSERT') OR 
       (TG_OP = 'UPDATE' AND (
           OLD.account_number IS DISTINCT FROM NEW.account_number OR
           OLD.ifsc_code IS DISTINCT FROM NEW.ifsc_code OR
           OLD.upi_vpa IS DISTINCT FROM NEW.upi_vpa OR
           OLD.beneficiary_name IS DISTINCT FROM NEW.beneficiary_name OR
           OLD.beneficiary_phone IS DISTINCT FROM NEW.beneficiary_phone OR
           OLD.beneficiary_email IS DISTINCT FROM NEW.beneficiary_email OR
           OLD.payout_method IS DISTINCT FROM NEW.payout_method
       )) THEN
       
        -- 1. Lock the user row to prevent race conditions on concurrent requests
        PERFORM 1 FROM public.users WHERE id = NEW.user_id FOR UPDATE;

        -- 2. Count updates in the last 7 days (rolling window)
        SELECT COUNT(*) INTO v_update_count
        FROM public.rider_payout_updates_log
        WHERE user_id = NEW.user_id
          AND created_at > now() - INTERVAL '7 days';

        IF v_update_count >= 2 THEN
            RAISE EXCEPTION 'Maximum of 2 payout account updates allowed per week';
        END IF;

        -- 3. Log this update event
        INSERT INTO public.rider_payout_updates_log (user_id)
        VALUES (NEW.user_id);
        
    END IF;

    RETURN NEW;
END;
$function$
"
prevent_wallet_transaction_modifications,"CREATE OR REPLACE FUNCTION public.prevent_wallet_transaction_modifications()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    RAISE EXCEPTION 'Immutable Ledger Error: Wallet transactions cannot be updated or deleted.';
END;
$function$
"
handle_promo_usage_changes,"CREATE OR REPLACE FUNCTION public.handle_promo_usage_changes()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
  IF TG_OP = 'INSERT' THEN
    UPDATE public.promo_codes
    SET uses_count = uses_count + 1
    WHERE id = NEW.promo_code_id;
  ELSIF TG_OP = 'DELETE' THEN
    UPDATE public.promo_codes
    SET uses_count = GREATEST(0, uses_count - 1)
    WHERE id = OLD.promo_code_id;
  END IF;
  RETURN NULL;
END;
$function$
"
check_travel_plan_active_bookings,"CREATE OR REPLACE FUNCTION public.check_travel_plan_active_bookings()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    IF EXISTS (
        SELECT 1 FROM public.intercity_requests
        WHERE route_id = OLD.id
          AND status IN ('confirmed', 'paid')
    ) THEN
        RAISE EXCEPTION 'Cannot delete travel plan while active bookings exist. Mark it inactive instead.';
    END IF;
    RETURN OLD;
END;
$function$
"
trg_users_user_code,"CREATE OR REPLACE FUNCTION public.trg_users_user_code()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    IF NEW.user_code IS NULL OR NEW.user_code = '' THEN
        NEW.user_code := public.generate_unique_user_code();
    END IF;
    RETURN NEW;
END;
$function$
"
trg_orders_order_code,"CREATE OR REPLACE FUNCTION public.trg_orders_order_code()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    IF NEW.order_code IS NULL OR NEW.order_code = '' OR NEW.order_code LIKE 'WX%' THEN
        NEW.order_code := public.generate_unique_order_code(NEW.order_type::text);
    END IF;
    RETURN NEW;
END;
$function$
"
trg_travel_plans_plan_code,"CREATE OR REPLACE FUNCTION public.trg_travel_plans_plan_code()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    IF NEW.plan_code IS NULL OR NEW.plan_code = '' THEN
        NEW.plan_code := public.generate_unique_plan_code();
    END IF;
    RETURN NEW;
END;
$function$
"
trg_payments_payment_code,"CREATE OR REPLACE FUNCTION public.trg_payments_payment_code()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    IF NEW.payment_code IS NULL OR NEW.payment_code = '' THEN
        NEW.payment_code := public.generate_unique_payment_code();
    END IF;
    RETURN NEW;
END;
$function$
"
trg_rider_withdrawals_transfer_id,"CREATE OR REPLACE FUNCTION public.trg_rider_withdrawals_transfer_id()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    IF NEW.transfer_id IS NULL OR NEW.transfer_id = '' OR NOT (NEW.transfer_id LIKE 'WDPY%') THEN
        NEW.transfer_id := public.generate_unique_transfer_id();
    END IF;
    RETURN NEW;
END;
$function$
"
assign_nearby_searching_orders_to_rider,"CREATE OR REPLACE FUNCTION public.assign_nearby_searching_orders_to_rider()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_order RECORD;
    v_radius_km double precision;
    v_stale_sec integer;
    v_dist_km double precision;
    v_timeout_sec integer;
    v_existing_id uuid;
    v_existing_status text;
BEGIN
    -- 1. If coordinates are missing, bypass
    IF NEW.current_lat IS NULL OR NEW.current_lng IS NULL THEN
        RETURN NEW;
    END IF;

    -- 2. Fetch active dispatch config values
    SELECT 
        COALESCE(round_2_radius_km, 5.0),
        COALESCE(rider_location_stale_sec, 60),
        COALESCE(rider_response_timeout_sec, 120)
    INTO 
        v_radius_km, 
        v_stale_sec, 
        v_timeout_sec
    FROM public.dispatch_config
    WHERE is_active = true
    LIMIT 1;

    -- Fallbacks if config is missing or null
    v_radius_km := COALESCE(v_radius_km, 5.0);
    v_stale_sec := COALESCE(v_stale_sec, 60);
    v_timeout_sec := COALESCE(v_timeout_sec, 120);

    FOR v_order IN (
        SELECT o.id, o.pickup_lat, o.pickup_lng, o.vehicle_type::text AS vehicle_type, o.order_type::text AS order_type, o.rider_earning
        FROM public.orders o
        WHERE o.order_status = 'searching'
    ) LOOP
        -- Calculate distance between rider and order pickup location
        v_dist_km := 6371 * acos(
            LEAST(GREATEST(
                cos(radians(v_order.pickup_lat))
                * cos(radians(NEW.current_lat))
                * cos(
                    radians(NEW.current_lng)
                    - radians(v_order.pickup_lng)
                )
                + sin(radians(v_order.pickup_lat))
                * sin(radians(NEW.current_lat))
            , -1.0), 1.0)
        );

        -- If the rider is within the max radius, and matches the vehicle type filter
        IF v_dist_km <= v_radius_km AND (v_order.order_type != 'ride' OR EXISTS (
            SELECT 1 FROM public.rider_kyc rk 
            WHERE rk.user_id = NEW.user_id 
              AND rk.vehicle_type::text = v_order.vehicle_type
        )) THEN
            -- Check if this rider doesn't already have an assignment for this order
            v_existing_id := NULL;
            v_existing_status := NULL;
            
            SELECT id, assignment_status INTO v_existing_id, v_existing_status
            FROM public.rider_assignments
            WHERE order_id = v_order.id 
              AND rider_id = NEW.id
            LIMIT 1;

            BEGIN
                IF v_existing_id IS NULL THEN
                    -- Insert assignment
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
                        NEW.id,
                        1,
                        'sent',
                        v_dist_km,
                        v_order.rider_earning,
                        NOW(),
                        NOW() + (v_timeout_sec || ' seconds')::interval,
                        NOW(),
                        v_order.rider_earning
                    );

                    -- Also insert into logs
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
                        NEW.id,
                        1,
                        'sent',
                        v_dist_km,
                        v_order.rider_earning,
                        NOW()
                    );
                ELSIF v_existing_status = 'expired' THEN
                    -- Only show again if the fare is boosted
                    IF EXISTS (
                        SELECT 1 FROM public.rider_assignments
                        WHERE id = v_existing_id
                          AND v_order.rider_earning > COALESCE(last_seen_fare, estimated_earnings, 0)
                    ) THEN
                        -- Update existing assignment back to 'sent' with fresh expiry
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

                        -- Log the update
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
                            NEW.id,
                            1,
                            'sent',
                            v_dist_km,
                            CEIL(v_dist_km * 3),
                            NOW()
                        );
                    END IF;
                ELSIF v_existing_status = 'rejected' THEN
                    -- Only show again if 4-minute cooldown is over AND the fare is boosted
                    IF EXISTS (
                        SELECT 1 FROM public.rider_assignments
                        WHERE id = v_existing_id
                          AND NOW() >= COALESCE(hidden_until, NOW())
                          AND v_order.rider_earning > COALESCE(last_seen_fare, estimated_earnings, 0)
                    ) THEN
                        -- Update existing assignment back to 'sent' with fresh expiry
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

                        -- Log the update
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
                            NEW.id,
                            1,
                            'sent',
                            v_dist_km,
                            CEIL(v_dist_km * 3),
                            NOW()
                        );
                    END IF;
                END IF;
            EXCEPTION WHEN unique_violation THEN
                -- Safely ignore duplicate key constraint violations
                NULL;
            END;
        END IF;
    END LOOP;

    RETURN NEW;
END;
$function$
"
sync_travel_plan_status_after,"CREATE OR REPLACE FUNCTION public.sync_travel_plan_status_after()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_active_bookings INT;
    v_max_bookings INT;
    v_plan_status public.travel_plan_status_enum;
    v_route_id uuid;
BEGIN
    IF TG_OP = 'DELETE' THEN
        v_route_id := OLD.route_id;
    ELSE
        v_route_id := NEW.route_id;
    END IF;

    IF v_route_id IS NULL THEN
        RETURN NULL;
    END IF;

    SELECT max_bookings, status INTO v_max_bookings, v_plan_status
    FROM public.rider_travel_plans
    WHERE id = v_route_id
    FOR UPDATE;

    SELECT COUNT(*) INTO v_active_bookings
    FROM public.intercity_requests
    WHERE route_id = v_route_id
      AND status IN ('confirmed', 'paid');

    IF v_active_bookings >= v_max_bookings THEN
        IF v_plan_status = 'active'::public.travel_plan_status_enum THEN
            UPDATE public.rider_travel_plans 
            SET status = 'fully_booked'::public.travel_plan_status_enum 
            WHERE id = v_route_id;
        END IF;
    ELSE
        -- Revive only fully_booked plans. Never touch expired or cancelled plans.
        IF v_plan_status = 'fully_booked'::public.travel_plan_status_enum THEN
            UPDATE public.rider_travel_plans 
            SET status = 'active'::public.travel_plan_status_enum 
            WHERE id = v_route_id;
        END IF;
    END IF;

    RETURN NULL;
END;
$function$
"
on_order_status_update,"CREATE OR REPLACE FUNCTION public.on_order_status_update()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_rider_user_id uuid := NULL;
    v_title text := '';
    v_body text := '';
BEGIN
    -- Check if status actually changed
    IF OLD.order_status IS DISTINCT FROM NEW.order_status THEN
        -- 1. Notify Passenger (NEW.user_id) for status updates
        IF NEW.order_status = 'accepted' THEN
            v_title := 'Order Accepted';
            v_body := 'A rider has accepted your order!';
        ELSIF NEW.order_status = 'rider_arrived' THEN
            v_title := 'Rider Arrived';
            v_body := 'Your rider has arrived at the pickup location.';
        ELSIF NEW.order_status = 'picked_up' THEN
            v_title := 'Order Picked Up';
            v_body := 'Your order is on the way!';
        ELSIF NEW.order_status = 'completed' THEN
            v_title := 'Order Completed';
            v_body := 'Your trip has been completed successfully.';
        ELSIF NEW.order_status = 'cancelled' THEN
            v_title := 'Order Cancelled';
            v_body := 'Your order has been cancelled.';
        END IF;

        -- Send to passenger
        IF v_title != '' AND v_body != '' AND NEW.user_id IS NOT NULL THEN
            PERFORM public.send_push_notification_fnc(
                NEW.user_id,
                v_title,
                v_body,
                jsonb_build_object(
                    'type', 'order_status',
                    'order_id', NEW.id,
                    'status', NEW.order_status
                )
            );
        END IF;

        -- 2. Notify Rider if order was cancelled
        IF NEW.order_status = 'cancelled' AND NEW.rider_id IS NOT NULL THEN
            SELECT user_id INTO v_rider_user_id FROM public.riders WHERE id = NEW.rider_id;
            
            IF v_rider_user_id IS NOT NULL THEN
                PERFORM public.send_push_notification_fnc(
                    v_rider_user_id,
                    'Order Cancelled',
                    'The order you accepted has been cancelled by the customer.',
                    jsonb_build_object(
                        'type', 'order_status',
                        'order_id', NEW.id,
                        'status', 'cancelled'
                    )
                );
            END IF;
        END IF;
    END IF;

    RETURN NEW;
END;
$function$
"
on_rider_review_insert,"CREATE OR REPLACE FUNCTION public.on_rider_review_insert()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_rider_user_id uuid := NULL;
    v_title text := 'New Review Received';
    v_body text := '';
BEGIN
    SELECT user_id INTO v_rider_user_id FROM public.riders WHERE id = NEW.rider_id;

    IF v_rider_user_id IS NOT NULL THEN
        IF NEW.rating = 5 THEN
            v_title := 'You''ve been rated 5-Star! 🌟';
            v_body := 'Excellent job! A passenger rated you 5 stars. Keep up the amazing work!';
        ELSE
            v_title := 'New Rating Received ⭐';
            v_body := 'You received a new ' || NEW.rating::text || '-star rating from your recent ride.';
        END IF;

        IF NEW.comment IS NOT NULL AND NEW.comment != '' THEN
            v_body := v_body || ' Feedback: ""' || substring(NEW.comment from 1 for 40) || '...""';
        END IF;

        PERFORM public.send_push_notification_fnc(
            v_rider_user_id,
            v_title,
            v_body,
            jsonb_build_object(
                'type', 'new_rating',
                'rating', NEW.rating,
                'review_id', NEW.id
            )
        );
    END IF;

    RETURN NEW;
END;
$function$
"
on_rider_wallet_balance_update,"CREATE OR REPLACE FUNCTION public.on_rider_wallet_balance_update()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
    -- If wallet balance drops below -500 (meaning they owe more than 500 rupees cash collected)
    -- And it was not below -500 before (to avoid spamming on subsequent updates)
    IF NEW.wallet_balance < -500 AND (OLD.wallet_balance IS NULL OR OLD.wallet_balance >= -500) THEN
        PERFORM public.send_push_notification_fnc(
            NEW.user_id,
            'COD Settlement Required 💳',
            'Your cash collections exceed the allowed limit. Please pay your COD settlement of ₹' || ABS(NEW.wallet_balance)::text || ' to continue receiving ride requests.',
            jsonb_build_object(
                'type', 'cod_settlement',
                'balance', NEW.wallet_balance
            )
        );
    END IF;
    RETURN NEW;
END;
$function$
"
create_rider_profile_on_activation,"CREATE OR REPLACE FUNCTION public.create_rider_profile_on_activation()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$

BEGIN

  -- =====================================
  -- PREVENT DUPLICATES
  -- =====================================

  IF NOT EXISTS (

    SELECT 1

    FROM riders

    WHERE user_id = NEW.user_id

  ) THEN

    INSERT INTO riders (

      kyc_id,

      user_id,

      account_status,

      is_verified

    )

    VALUES (

      NEW.id,

      NEW.user_id,

      'offline',

      true
    );

  END IF;

  RETURN NEW;

END;

$function$
"
on_new_chat_message,"CREATE OR REPLACE FUNCTION public.on_new_chat_message()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_recipient_user_id uuid := NULL;
    v_customer_user_id uuid := NULL;
    v_rider_user_id uuid := NULL;
    v_order_rider_id uuid := NULL;
    v_sender_name text := 'Someone';
BEGIN
    -- Get sender name if possible
    SELECT COALESCE(full_name, 'Someone') INTO v_sender_name 
    FROM public.users 
    WHERE id = NEW.sender_id;

    IF NEW.order_id IS NOT NULL THEN
        -- Order chat
        SELECT user_id, rider_id INTO v_customer_user_id, v_order_rider_id 
        FROM public.orders 
        WHERE id = NEW.order_id;
        
        -- Get rider's user_id
        IF NEW.rider_id IS NOT NULL THEN
            SELECT user_id INTO v_rider_user_id FROM public.riders WHERE id = NEW.rider_id;
        ELSIF v_order_rider_id IS NOT NULL THEN
            SELECT user_id INTO v_rider_user_id FROM public.riders WHERE id = v_order_rider_id;
        END IF;

        IF NEW.sender_id = v_customer_user_id THEN
            v_recipient_user_id := v_rider_user_id;
        ELSIF NEW.sender_id = v_rider_user_id THEN
            v_recipient_user_id := v_customer_user_id;
        END IF;
    ELSE
        -- Support chat
        IF NEW.user_id IS NOT NULL AND NEW.sender_id != NEW.user_id THEN
            v_recipient_user_id := NEW.user_id;
        END IF;
    END IF;

    -- Send notification if recipient is determined
    IF v_recipient_user_id IS NOT NULL THEN
        PERFORM public.send_push_notification_fnc(
            v_recipient_user_id,
            v_sender_name,
            NEW.message,
            jsonb_build_object(
                'type', 'chat_message',
                'order_id', NEW.order_id,
                'message_id', NEW.id,
                'sender_type', NEW.sender_type
            )
        );
    END IF;

    RETURN NEW;
END;
$function$
"
on_rider_assignment_change,"CREATE OR REPLACE FUNCTION public.on_rider_assignment_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_rider_user_id uuid := NULL;
BEGIN
    -- Notify when status is set or updated to 'sent'
    IF NEW.assignment_status = 'sent' AND (TG_OP = 'INSERT' OR OLD.assignment_status IS DISTINCT FROM 'sent') THEN
        SELECT user_id INTO v_rider_user_id FROM public.riders WHERE id = NEW.rider_id;

        IF v_rider_user_id IS NOT NULL THEN
            PERFORM public.send_push_notification_fnc(
                v_rider_user_id,
                'New Order Request',
                'You have a new order request nearby!',
                jsonb_build_object(
                    'type', 'order_assignment',
                    'order_id', NEW.order_id,
                    'assignment_id', NEW.id
                )
            );
        END IF;
    END IF;

    RETURN NEW;
END;
$function$
"
on_intercity_request_change,"CREATE OR REPLACE FUNCTION public.on_intercity_request_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_rider_user_id uuid := NULL;
    v_passenger_user_id uuid := NEW.sender_id;
    v_title text := '';
    v_body text := '';
    v_notify_user_id uuid := NULL;
BEGIN
    -- Fetch the rider's user_id
    SELECT user_id INTO v_rider_user_id FROM public.riders WHERE id = NEW.traveller_id;

    -- A) When a request is INSERTED (request_sent)
    IF TG_OP = 'INSERT' THEN
        IF NEW.initiated_by = 'sender' THEN
            -- Sender is passenger, notify rider (traveller)
            v_notify_user_id := v_rider_user_id;
            v_title := 'New Request Received 📦';
            v_body := 'A passenger wants you to carry their shipment or ride. Open details to discuss!';
        ELSE
            -- Initiator is rider, notify passenger (sender)
            v_notify_user_id := v_passenger_user_id;
            v_title := 'New Offer Received ⚡';
            v_body := 'A traveller offered to carry your shipment or ride. Open details to discuss!';
        END IF;

    -- B) When request is UPDATED and status changes
    ELSIF TG_OP = 'UPDATE' AND OLD.status IS DISTINCT FROM NEW.status THEN
        IF NEW.status = 'discussion_started' THEN
            -- Discussion accepted, notify the initiator of request
            IF NEW.initiated_by = 'sender' THEN
                v_notify_user_id := v_passenger_user_id;
            ELSE
                v_notify_user_id := v_rider_user_id;
            END IF;
            v_title := 'Discussion Opened 💬';
            v_body := 'The conversation has been accepted. You can now chat and negotiate the fare!';
            
        ELSIF NEW.status = 'confirmed' THEN
            -- Let's notify passenger (sender) to complete payment
            v_notify_user_id := v_passenger_user_id;
            v_title := 'Booking Confirmed! 🎉';
            v_body := 'Both parties have confirmed the booking. Please proceed to payment.';
            
        ELSIF NEW.status = 'paid' THEN
            -- Passenger paid, notify traveller (rider)
            v_notify_user_id := v_rider_user_id;
            v_title := 'Payment Verified! 💳';
            v_body := 'Passenger has paid for the trip. You can now start the transit.';
            
        ELSIF NEW.status = 'in_progress' THEN
            -- Trip started, notify passenger
            v_notify_user_id := v_passenger_user_id;
            v_title := 'Trip on the Way 🗺️';
            v_body := 'Traveller has collected the parcel/started the ride. Track live updates!';
            
        ELSIF NEW.status = 'completed' THEN
            -- Completed, notify passenger
            v_notify_user_id := v_passenger_user_id;
            v_title := 'Trip Completed Successfully 🎉';
            v_body := 'Your shipment/ride has been delivered. Thank the traveller!';
        END IF;
    END IF;

    -- Send push notification if a target recipient is identified
    IF v_notify_user_id IS NOT NULL THEN
        PERFORM public.send_push_notification_fnc(
            v_notify_user_id,
            v_title,
            v_body,
            jsonb_build_object(
                'type', 'intercity_request',
                'request_id', NEW.id,
                'order_id', NEW.parcel_id,
                'rider_id', NEW.traveller_id,
                'status', NEW.status
            )
        );
    END IF;

    -- In case of final confirmed status, let's also notify the rider (separate call since both need it)
    IF TG_OP = 'UPDATE' AND OLD.status IS DISTINCT FROM NEW.status AND NEW.status = 'confirmed' THEN
        IF v_rider_user_id IS NOT NULL THEN
            PERFORM public.send_push_notification_fnc(
                v_rider_user_id,
                'Booking Confirmed! 🎉',
                'Booking is confirmed by the passenger. Awaiting payment.',
                jsonb_build_object(
                    'type', 'intercity_request',
                    'request_id', NEW.id,
                    'order_id', NEW.parcel_id,
                    'rider_id', NEW.traveller_id,
                    'status', NEW.status
                )
            );
        END IF;
    END IF;

    RETURN NEW;
END;
$function$

"

schemaname,tablename,rowsecurity
public,order_chat_messages,true
public,wallet_transactions,true
public,pricing_change_logs,true
public,wallet_audit_logs,true
public,rider_payout_accounts,true
public,rider_withdrawals,true
public,rider_withdrawal_events,true
public,promo_codes,true
public,promo_code_users,true
public,user_promo_usages,true
public,rider_daily_activity,true
public,users,true
public,user_device_tokens,true
public,rider_payout_updates_log,true
public,orders,true
public,admins,true
public,police_sos_logs,true
public,order_parcel_photos,true
public,parcel_compliance_reports,true
public,notifications,true
public,parcel_security_logs,true
public,order_declarations,true
public,admin_logs,true
public,user_devices,true
public,rider_travel_plans,true
public,rider_reviews,true
public,riders,true
public,pricing_config,true
public,pricing_zones,true
public,dispatch_config,true
public,distance_discounts,true
public,payments,true
public,order_verifications,true
public,intercity_requests,true
public,rider_subscription_history,true
public,order_status_history,true
public,rider_kyc,true
public,order_assignment_logs,true
public,rider_assignments,true

schemaname,tablename,policyname,permissive,roles,cmd,qual,with_check
public,distance_discounts,Public read distance_discounts,PERMISSIVE,"{anon,authenticated}",SELECT,true,null
public,intercity_requests,Allow request participants to read/write,PERMISSIVE,{authenticated},ALL,"((sender_id = auth.uid()) OR (EXISTS ( SELECT 1
   FROM riders r
  WHERE ((r.id = intercity_requests.traveller_id) AND (r.user_id = auth.uid())))))","((sender_id = auth.uid()) OR (EXISTS ( SELECT 1
   FROM riders r
  WHERE ((r.id = intercity_requests.traveller_id) AND (r.user_id = auth.uid())))))"
public,notifications,Users can view their own notifications,PERMISSIVE,{public},SELECT,(auth.uid() = user_id),null
public,notifications,Users can update their own notifications,PERMISSIVE,{public},UPDATE,(auth.uid() = user_id),(auth.uid() = user_id)
public,order_assignment_logs,Allow riders and orders owners to view logs,PERMISSIVE,{authenticated},SELECT,"((EXISTS ( SELECT 1
   FROM riders r
  WHERE ((r.id = order_assignment_logs.rider_id) AND (r.user_id = auth.uid())))) OR (EXISTS ( SELECT 1
   FROM orders o
  WHERE ((o.id = order_assignment_logs.order_id) AND (o.user_id = auth.uid())))))",null
public,order_chat_messages,Allow chat participants to read/write,PERMISSIVE,{authenticated},ALL,"((EXISTS ( SELECT 1
   FROM users
  WHERE ((users.id = auth.uid()) AND ((users.role = 'admin'::text) OR (users.role = 'support'::text))))) OR (sender_id = auth.uid()) OR (user_id = auth.uid()) OR ((order_id IS NOT NULL) AND ((EXISTS ( SELECT 1
   FROM orders o
  WHERE ((o.id = order_chat_messages.order_id) AND (o.user_id = auth.uid())))) OR (EXISTS ( SELECT 1
   FROM riders r
  WHERE ((r.user_id = auth.uid()) AND ((r.id = order_chat_messages.rider_id) OR (r.id IN ( SELECT o.rider_id
           FROM orders o
          WHERE (o.id = order_chat_messages.order_id))) OR (r.id IN ( SELECT ra.rider_id
           FROM rider_assignments ra
          WHERE (ra.order_id = ra.order_id))))))))) OR ((order_id IS NULL) AND ((sender_id = auth.uid()) OR (rider_id IN ( SELECT riders.id
   FROM riders
  WHERE (riders.user_id = auth.uid()))))))",null
public,order_declarations,Allow users to select their declarations,PERMISSIVE,{authenticated},SELECT,true,null
public,order_declarations,Allow users to insert order declarations,PERMISSIVE,{authenticated},INSERT,null,true
public,order_parcel_photos,Allow riders to insert parcel verification photos,PERMISSIVE,{authenticated},INSERT,null,true
public,order_parcel_photos,Allow authenticated to select parcel verification photos,PERMISSIVE,{authenticated},SELECT,true,null
public,order_verifications,Allow participants to view order verifications,PERMISSIVE,{authenticated},SELECT,"(EXISTS ( SELECT 1
   FROM orders o
  WHERE ((o.id = order_verifications.order_id) AND ((o.user_id = auth.uid()) OR (o.rider_id IN ( SELECT r.id
           FROM riders r
          WHERE (r.user_id = auth.uid())))))))",null
public,order_verifications,Allow assigned rider to insert order verifications,PERMISSIVE,{authenticated},INSERT,null,"(EXISTS ( SELECT 1
   FROM orders o
  WHERE ((o.id = order_verifications.order_id) AND (o.rider_id IN ( SELECT r.id
           FROM riders r
          WHERE (r.user_id = auth.uid()))))))"
public,orders,Allow users to view their own or assigned orders,PERMISSIVE,{authenticated},SELECT,"((auth.uid() = user_id) OR (EXISTS ( SELECT 1
   FROM riders r
  WHERE ((r.id = orders.rider_id) AND (r.user_id = auth.uid())))) OR check_is_order_candidate_rider(id, auth.uid()))",null
public,orders,Allow passengers to create orders,PERMISSIVE,{authenticated},INSERT,null,(auth.uid() = user_id)
public,orders,Allow passengers and assigned riders to update orders,PERMISSIVE,{authenticated},UPDATE,"((auth.uid() = user_id) OR (EXISTS ( SELECT 1
   FROM riders r
  WHERE ((r.id = orders.rider_id) AND (r.user_id = auth.uid())))))",null
public,orders,user_can_view_own_orders,PERMISSIVE,{authenticated},SELECT,(auth.uid() = user_id),null
public,orders,rider_can_view_assigned_orders,PERMISSIVE,{authenticated},SELECT,"(rider_id IN ( SELECT riders.id
   FROM riders
  WHERE (riders.user_id = auth.uid())))",null
public,orders,user_can_update_own_order,PERMISSIVE,{authenticated},UPDATE,((auth.uid() = user_id) AND (order_status = 'searching'::order_status_enum)),(auth.uid() = user_id)
public,parcel_compliance_reports,Allow authenticated users to select compliance reports,PERMISSIVE,{authenticated},SELECT,true,null
public,parcel_security_logs,Allow users/riders to select their parcel security logs,PERMISSIVE,{authenticated},SELECT,true,null
public,parcel_security_logs,Allow authenticated users to insert security logs,PERMISSIVE,{authenticated},INSERT,null,true
public,police_sos_logs,Allow authenticated to select police sos logs,PERMISSIVE,{authenticated},SELECT,true,null
public,police_sos_logs,Allow riders to insert police sos logs,PERMISSIVE,{authenticated},INSERT,null,true
public,pricing_zones,Allow public read access to pricing_zones,PERMISSIVE,"{anon,authenticated}",SELECT,true,null
public,promo_code_users,Users can view their own promo assignments,PERMISSIVE,{authenticated},SELECT,(user_id = auth.uid()),null
public,promo_codes,Allow read access to active and applicable promos,PERMISSIVE,{authenticated},SELECT,"((is_active = true) AND (expires_at > now()) AND (((audience_type)::text = 'everyone'::text) OR (EXISTS ( SELECT 1
   FROM promo_code_users pcu
  WHERE ((pcu.promo_code_id = pcu.id) AND (pcu.user_id = auth.uid()))))))",null
public,rider_assignments,Allow passengers to view assignments for their own orders,PERMISSIVE,{authenticated},SELECT,"check_is_order_passenger(order_id, auth.uid())",null
public,rider_assignments,Allow riders to view their own assignments,PERMISSIVE,{authenticated},SELECT,"(EXISTS ( SELECT 1
   FROM riders r
  WHERE ((r.id = rider_assignments.rider_id) AND (r.user_id = auth.uid()))))",null
public,rider_assignments,Riders can view own assignments,PERMISSIVE,{authenticated},SELECT,"(EXISTS ( SELECT 1
   FROM riders r
  WHERE ((r.id = rider_assignments.rider_id) AND (r.user_id = auth.uid()))))",null
public,rider_assignments,Riders can update own assignments,PERMISSIVE,{authenticated},UPDATE,"(EXISTS ( SELECT 1
   FROM riders r
  WHERE ((r.id = rider_assignments.rider_id) AND (r.user_id = auth.uid()))))","(EXISTS ( SELECT 1
   FROM riders r
  WHERE ((r.id = rider_assignments.rider_id) AND (r.user_id = auth.uid()))))"
public,rider_assignments,Allow passengers to insert assignments for their own orders,PERMISSIVE,{authenticated},INSERT,null,"check_is_order_passenger(order_id, auth.uid())"
public,rider_assignments,Allow passengers to update assignments for their own orders,PERMISSIVE,{authenticated},UPDATE,"check_is_order_passenger(order_id, auth.uid())","check_is_order_passenger(order_id, auth.uid())"
public,rider_assignments,Authenticated can insert rider assignments,PERMISSIVE,{authenticated},INSERT,null,true
public,rider_assignments,Allow riders to update their own assignments,PERMISSIVE,{authenticated},UPDATE,"(EXISTS ( SELECT 1
   FROM riders r
  WHERE ((r.id = rider_assignments.rider_id) AND (r.user_id = auth.uid()))))","(EXISTS ( SELECT 1
   FROM riders r
  WHERE ((r.id = rider_assignments.rider_id) AND (r.user_id = auth.uid()))))"
public,rider_daily_activity,Riders can view their own daily activity,PERMISSIVE,{authenticated},SELECT,"(rider_id IN ( SELECT riders.id
   FROM riders
  WHERE (riders.user_id = auth.uid())))",null
public,rider_kyc,Riders can insert own KYC,PERMISSIVE,{public},INSERT,null,(auth.uid() = user_id)
public,rider_kyc,Riders can view own KYC,PERMISSIVE,{public},SELECT,(auth.uid() = user_id),null
public,rider_kyc,Users can view own kyc,PERMISSIVE,{authenticated},SELECT,(auth.uid() = user_id),null
public,rider_kyc,Users can create own kyc,PERMISSIVE,{authenticated},INSERT,null,(auth.uid() = user_id)
public,rider_kyc,Users can update own kyc,PERMISSIVE,{authenticated},UPDATE,(auth.uid() = user_id),null
public,rider_kyc,Allow view own KYC or online rider KYC,PERMISSIVE,{authenticated},SELECT,"((auth.uid() = user_id) OR (EXISTS ( SELECT 1
   FROM riders r
  WHERE ((r.user_id = rider_kyc.user_id) AND (r.account_status = 'online'::rider_account_status_enum)))))",null
public,rider_payout_accounts,rider_select_own_payout_account,PERMISSIVE,{authenticated},SELECT,(auth.uid() = user_id),null
public,rider_payout_accounts,rider_insert_own_payout_account,PERMISSIVE,{authenticated},INSERT,null,(auth.uid() = user_id)
public,rider_payout_accounts,rider_update_own_payout_account,PERMISSIVE,{authenticated},UPDATE,(auth.uid() = user_id),(auth.uid() = user_id)
public,rider_payout_updates_log,Riders can view their own payout updates log,PERMISSIVE,{authenticated},SELECT,(auth.uid() = user_id),null
public,rider_reviews,Users and riders can view reviews,PERMISSIVE,{authenticated},SELECT,"((auth.uid() = user_id) OR (rider_id IN ( SELECT riders.id
   FROM riders
  WHERE (riders.user_id = auth.uid()))))",null
public,rider_reviews,Users can insert reviews for their own orders,PERMISSIVE,{authenticated},INSERT,null,(auth.uid() = user_id)
public,rider_travel_plans,Allow authenticated users to view active travel plans,PERMISSIVE,{authenticated},SELECT,"((status = 'active'::travel_plan_status_enum) OR (EXISTS ( SELECT 1
   FROM riders r
  WHERE ((r.id = rider_travel_plans.rider_id) AND (r.user_id = auth.uid())))))",null
public,rider_travel_plans,Allow riders to delete their own travel plans,PERMISSIVE,{authenticated},DELETE,"(EXISTS ( SELECT 1
   FROM riders r
  WHERE ((r.id = rider_travel_plans.rider_id) AND (r.user_id = auth.uid()))))",null
public,rider_travel_plans,Allow riders to insert their own travel plans,PERMISSIVE,{authenticated},INSERT,null,"(EXISTS ( SELECT 1
   FROM riders r
  WHERE ((r.id = rider_travel_plans.rider_id) AND (r.user_id = auth.uid()))))"
public,rider_travel_plans,Allow riders to update their own travel plans,PERMISSIVE,{authenticated},UPDATE,"(EXISTS ( SELECT 1
   FROM riders r
  WHERE ((r.id = rider_travel_plans.rider_id) AND (r.user_id = auth.uid()))))","(EXISTS ( SELECT 1
   FROM riders r
  WHERE ((r.id = rider_travel_plans.rider_id) AND (r.user_id = auth.uid()))))"
public,rider_withdrawal_events,Users can view own withdrawal events,PERMISSIVE,{authenticated},SELECT,"(EXISTS ( SELECT 1
   FROM rider_withdrawals rw
  WHERE ((rw.id = rider_withdrawal_events.withdrawal_id) AND (rw.user_id = auth.uid()))))",null
public,rider_withdrawal_events,Riders can view their own withdrawal events,PERMISSIVE,{authenticated},SELECT,"(EXISTS ( SELECT 1
   FROM rider_withdrawals w
  WHERE ((w.id = rider_withdrawal_events.withdrawal_id) AND (w.user_id = auth.uid()))))",null
public,rider_withdrawals,Riders can view their own withdrawals,PERMISSIVE,{authenticated},SELECT,(auth.uid() = user_id),null
public,rider_withdrawals,Users can view own withdrawals,PERMISSIVE,{authenticated},SELECT,(auth.uid() = user_id),null
public,riders,Riders can view own rider profile,PERMISSIVE,{public},SELECT,(auth.uid() = user_id),null
public,riders,Users can view own rider profile,PERMISSIVE,{authenticated},SELECT,(auth.uid() = user_id),null
public,riders,Allow authenticated users to view online riders,PERMISSIVE,{authenticated},SELECT,((account_status = 'online'::rider_account_status_enum) OR (auth.uid() = user_id)),null
public,riders,Riders can update own rider profile,PERMISSIVE,{public},UPDATE,(auth.uid() = user_id),null
public,riders,Allow riders to update their own profile,PERMISSIVE,{authenticated},UPDATE,(auth.uid() = user_id),(auth.uid() = user_id)
public,user_device_tokens,Users can manage their own device tokens,PERMISSIVE,{authenticated},ALL,(( SELECT auth.uid() AS uid) = user_id),(( SELECT auth.uid() AS uid) = user_id)
public,user_devices,Allow users to select their own devices,PERMISSIVE,{authenticated},SELECT,(auth.uid() = user_id),null
public,user_devices,Allow users to insert their own devices,PERMISSIVE,{authenticated},INSERT,null,(auth.uid() = user_id)
public,user_devices,Allow users to update their own devices,PERMISSIVE,{authenticated},UPDATE,(auth.uid() = user_id),(auth.uid() = user_id)
public,user_promo_usages,Users can record their own promo usage,PERMISSIVE,{authenticated},INSERT,null,(auth.uid() = user_id)
public,user_promo_usages,Users can view their own promo usages,PERMISSIVE,{authenticated},SELECT,(auth.uid() = user_id),null
public,users,Users can update own profile,PERMISSIVE,{authenticated},UPDATE,(auth.uid() = id),null
public,users,Users can view own profile,PERMISSIVE,{authenticated},SELECT,(auth.uid() = id),null
public,users,Users can insert own profile,PERMISSIVE,{authenticated},INSERT,null,(auth.uid() = id)
public,wallet_transactions,Riders can view their own wallet transactions,PERMISSIVE,{authenticated},SELECT,"(EXISTS ( SELECT 1
   FROM riders r
  WHERE ((r.id = wallet_transactions.rider_id) AND (r.user_id = auth.uid()))))",null

  enum_name,enumsortorder,enumlabel
activation_status_enum,1,inactive
activation_status_enum,2,profile_pending
activation_status_enum,3,active
activation_status_enum,4,suspended
assignment_status_enum,1,sent
assignment_status_enum,2,viewed
assignment_status_enum,3,accepted
assignment_status_enum,4,rejected
assignment_status_enum,5,timed_out
assignment_status_enum,6,expired
assignment_status_enum,7,cancelled
cancelled_by_enum,1,user
cancelled_by_enum,2,rider
cancelled_by_enum,3,admin
cancelled_by_enum,4,system
cashfree_beneficiary_status_enum,1,pending
cashfree_beneficiary_status_enum,2,active
cashfree_beneficiary_status_enum,3,failed
cashfree_beneficiary_status_enum,4,disabled
intercity_assignment_status_enum,1,sent
intercity_assignment_status_enum,2,viewed
intercity_assignment_status_enum,3,accepted
intercity_assignment_status_enum,4,rejected
intercity_assignment_status_enum,5,timed_out
intercity_assignment_status_enum,6,expired
intercity_assignment_status_enum,7,cancelled
intercity_assignment_status_enum,8,accepted_by_user
kyc_status_enum,1,pending
kyc_status_enum,2,under_review
kyc_status_enum,3,approved
kyc_status_enum,4,rejected
kyc_status_enum,5,resubmitted
order_status_enum,1,created
order_status_enum,2,searching
order_status_enum,3,accepted
order_status_enum,4,rider_arrived
order_status_enum,5,picked_up
order_status_enum,6,ongoing
order_status_enum,7,rider_at_drop
order_status_enum,8,completed
order_status_enum,9,delivered
order_status_enum,10,cancelled
order_status_enum,11,expired
order_type_enum,1,ride
order_type_enum,2,intercity_ride
order_type_enum,3,ride_sharing
order_type_enum,4,local_parcel
order_type_enum,5,intercity_parcel
order_type_enum,6,batch_delivery
order_type_enum,7,food_delivery
order_type_enum,8,grocery_delivery
parcel_type_enum,1,documents
parcel_type_enum,2,electronics
parcel_type_enum,3,food
parcel_type_enum,4,clothes
parcel_type_enum,5,fragile
parcel_type_enum,6,others
payment_for_enum,1,ride_order
payment_for_enum,2,parcel_order
payment_for_enum,3,wallet_topup
payment_for_enum,4,subscription
payment_for_enum,5,withdrawal
payment_for_enum,6,refund
payment_for_enum,7,cod_settlement
payment_for_enum,8,ride_boost
payment_for_enum,9,intercity_ride_boost
payment_for_enum,10,intercity_parcel_boost
payment_for_enum,11,intercity_ride_order
payment_for_enum,12,intercity_parcel_order
payment_for_enum,13,ride_sharing
payment_method_enum,1,upi
payment_method_enum,2,card
payment_method_enum,3,wallet
payment_method_enum,4,netbanking
payment_method_enum,5,cash
payment_method_enum,6,cod
payment_method_enum,7,cashfree
payment_mode_enum,1,cash
payment_mode_enum,2,online
payment_mode_enum,3,wallet
payment_status_enum,1,pending
payment_status_enum,2,paid
payment_status_enum,3,failed
payment_status_enum,4,refunded
payment_status_enum,5,partial_refund
payment_status_enum,6,cash_collected
payment_status_enum,7,cash_pending_settlement
payout_method_enum,1,bank_account
payout_method_enum,2,upi
preferred_mode_enum,1,user
preferred_mode_enum,2,rider
pricing_city_tier_enum,1,tier_1
pricing_city_tier_enum,2,tier_2
pricing_service_type_enum,1,ride
pricing_service_type_enum,2,local_parcel
pricing_service_type_enum,3,intercity_parcel
pricing_service_type_enum,4,intercity_ride
pricing_service_type_enum,5,ride_sharing
review_tag,1,clean_vehicle
review_tag,2,polite_behavior

table_name,view_definition
settlement_reconciliation_summary," SELECT id AS order_id,
    rider_id,
    final_fare,
    order_status,
    payment_mode,
    payment_status,
        CASE
            WHEN ((payment_mode = 'cash'::payment_mode_enum) AND (order_status = ANY (ARRAY['completed'::order_status_enum, 'delivered'::order_status_enum]))) THEN final_fare
            ELSE 0.00
        END AS cash_collected,
    COALESCE(( SELECT sum(wallet_transactions.amount) AS sum
           FROM wallet_transactions
          WHERE ((wallet_transactions.reference_id = o.id) AND ((wallet_transactions.reference_type)::text = 'order'::text))), 0.00) AS wallet_transaction_sum,
    COALESCE(( SELECT sum(rider_withdrawals.amount) AS sum
           FROM rider_withdrawals
          WHERE ((rider_withdrawals.rider_id = o.rider_id) AND (rider_withdrawals.status = 'success'::rider_withdrawal_status_enum))), 0.00) AS total_settlements
   FROM orders o;"
parcel_compliance_view," SELECT o.id AS order_id,
    o.order_code,
    o.order_type,
    o.order_status,
    o.compliance_status,
    o.compliance_score,
    o.compliance_flagged,
    o.compliance_notes,
    o.parcel_declared_value,
    o.high_risk_parcel,
    o.created_device_ref,
    o.created_device_record_id,
    o.created_device_model,
    o.created_device_brand,
    o.created_os_version,
    o.created_app_version,
    o.created_ip_address,
    o.created_lat,
    o.created_lng,
    o.pickup_verification_completed,
    o.pickup_verification_completed_at,
    o.compliance_retention_until,
    u.id AS sender_id,
    u.phone AS sender_phone,
    od.id AS declaration_id,
    od.declaration_version,
    od.declaration_text,
    od.accepted_at AS declaration_accepted_at,
    od.accepted_ip AS declaration_accepted_ip,
    od.accepted_device_ref AS declaration_accepted_device_ref,
    ( SELECT count(*) AS count
           FROM police_sos_logs psl
          WHERE (psl.order_id = o.id)) AS sos_trigger_count,
    ( SELECT count(*) AS count
           FROM order_parcel_photos opp
          WHERE (opp.order_id = o.id)) AS photo_count
   FROM ((orders o
     LEFT JOIN users u ON ((u.id = o.user_id)))
     LEFT JOIN order_declarations od ON ((od.order_id = o.id)));"
parcel_security_timeline_view," SELECT o.id AS order_id,
    o.order_code,
    psl.id AS log_id,
    psl.event_type,
    psl.event_latitude,
    psl.event_longitude,
    psl.created_at AS event_timestamp,
    psl.device_id,
    psl.metadata
   FROM (orders o
     JOIN parcel_security_logs psl ON ((psl.order_id = o.id)))
  ORDER BY psl.created_at;"
rider_reliability_view," SELECT r.id AS rider_id,
    r.user_id,
    stats.reliability_score,
    stats.rating,
    stats.completion_rate,
    stats.on_time_rate,
    stats.total_completed,
    stats.total_cancelled,
    stats.experience_score
   FROM (riders r
     CROSS JOIN LATERAL get_rider_reliability_stats(r.id) stats(reliability_score, rating, completion_rate, on_time_rate, total_completed, total_cancelled, experience_score));"
travel_plan_capacity_view," WITH active_weight_usage AS (
         SELECT o.rider_id,
            COALESCE(sum(COALESCE(o.actual_weight_kg, (COALESCE(NULLIF(regexp_replace(o.weight_category, '[^0-9.]'::text, ''::text, 'g'::text), ''::text), '0'::text))::numeric)), 0.0) AS used_weight_kg
           FROM orders o
          WHERE (o.order_status = ANY (ARRAY['accepted'::order_status_enum, 'rider_arrived'::order_status_enum, 'picked_up'::order_status_enum, 'ongoing'::order_status_enum, 'rider_at_drop'::order_status_enum]))
          GROUP BY o.rider_id
        )
 SELECT tp.id AS plan_id,
    tp.max_weight_kg,
    COALESCE(uw.used_weight_kg, 0.0) AS used_weight_kg,
    GREATEST((tp.max_weight_kg - COALESCE(uw.used_weight_kg, 0.0)), 0.0) AS remaining_capacity_kg
   FROM (rider_travel_plans tp
     LEFT JOIN active_weight_usage uw ON ((uw.rider_id = tp.rider_id)));"

     sequence_catalog,sequence_schema,sequence_name,data_type,numeric_precision,numeric_precision_radix,numeric_scale,start_value,minimum_value,maximum_value,increment,cycle_option
postgres,public,rider_beneficiary_seq,bigint,64,2,0,100001,1,9223372036854775807,1,NO

oid,extname,extowner,extnamespace,extrelocatable,extversion,extconfig,extcondition
24614,pg_net,10,2200,false,0.20.0,null,null
16393,pg_stat_statements,16388,16392,true,1.11,null,null
16447,pgcrypto,16388,16392,true,1.3,null,null
13615,plpgsql,10,11,false,1.0,null,null
16608,supabase_vault,10,16607,false,0.3.1,[16612],"[""""]"
16436,uuid-ossp,16388,16392,true,1.1,null,null

oid,pubname,pubowner,puballtables,pubinsert,pubupdate,pubdelete,pubtruncate,pubviaroot
18598,supabase_realtime_messages_publication,10,false,true,true,true,true,false
16430,supabase_realtime,16388,false,true,true,true,true,false

table_name,grantee,privilege_type
admin_logs,anon,TRUNCATE
admin_logs,postgres,SELECT
admin_logs,service_role,INSERT
admin_logs,postgres,DELETE
admin_logs,postgres,TRUNCATE
admin_logs,postgres,UPDATE
admin_logs,authenticated,TRIGGER
admin_logs,anon,TRIGGER
admin_logs,anon,REFERENCES
admin_logs,postgres,TRIGGER
admin_logs,authenticated,REFERENCES
admin_logs,service_role,REFERENCES
admin_logs,postgres,REFERENCES
admin_logs,service_role,TRIGGER
admin_logs,service_role,TRUNCATE
admin_logs,service_role,SELECT
admin_logs,authenticated,TRUNCATE
admin_logs,postgres,INSERT
admins,postgres,TRIGGER
admins,postgres,INSERT
admins,postgres,SELECT
admins,service_role,REFERENCES
admins,anon,REFERENCES
admins,service_role,UPDATE
admins,postgres,UPDATE
admins,postgres,TRUNCATE
admins,anon,TRIGGER
admins,service_role,SELECT
admins,service_role,TRUNCATE
admins,postgres,REFERENCES
admins,authenticated,TRUNCATE
admins,authenticated,REFERENCES
admins,postgres,DELETE
admins,service_role,INSERT
admins,authenticated,TRIGGER
admins,anon,TRUNCATE
admins,service_role,TRIGGER
dispatch_config,postgres,TRUNCATE
dispatch_config,anon,TRUNCATE
dispatch_config,service_role,TRUNCATE
dispatch_config,service_role,UPDATE
dispatch_config,service_role,TRIGGER
dispatch_config,service_role,DELETE
dispatch_config,service_role,REFERENCES
dispatch_config,authenticated,TRUNCATE
dispatch_config,authenticated,SELECT
dispatch_config,authenticated,TRIGGER
dispatch_config,anon,TRIGGER
dispatch_config,authenticated,REFERENCES
dispatch_config,postgres,REFERENCES
dispatch_config,postgres,TRIGGER
dispatch_config,service_role,INSERT
dispatch_config,postgres,INSERT
dispatch_config,postgres,SELECT
dispatch_config,postgres,UPDATE
dispatch_config,postgres,DELETE
dispatch_config,service_role,SELECT
dispatch_config,anon,REFERENCES
distance_discounts,service_role,SELECT
distance_discounts,service_role,UPDATE
distance_discounts,service_role,INSERT
distance_discounts,authenticated,REFERENCES
distance_discounts,authenticated,TRUNCATE
distance_discounts,authenticated,TRIGGER
distance_discounts,service_role,DELETE
distance_discounts,anon,TRUNCATE
distance_discounts,anon,REFERENCES
distance_discounts,anon,TRIGGER
distance_discounts,postgres,TRIGGER
distance_discounts,anon,SELECT
distance_discounts,postgres,DELETE
distance_discounts,postgres,UPDATE
distance_discounts,postgres,TRUNCATE
distance_discounts,service_role,TRIGGER
distance_discounts,authenticated,SELECT
distance_discounts,postgres,INSERT
distance_discounts,service_role,TRUNCATE
distance_discounts,postgres,SELECT
distance_discounts,postgres,REFERENCES
distance_discounts,service_role,REFERENCES
intercity_requests,authenticated,TRUNCATE
intercity_requests,authenticated,REFERENCES
intercity_requests,authenticated,DELETE
intercity_requests,authenticated,TRIGGER
intercity_requests,authenticated,INSERT
intercity_requests,authenticated,SELECT
intercity_requests,anon,TRIGGER
intercity_requests,authenticated,UPDATE
intercity_requests,service_role,INSERT
intercity_requests,service_role,SELECT
intercity_requests,postgres,REFERENCES
intercity_requests,postgres,DELETE
intercity_requests,postgres,TRUNCATE
intercity_requests,postgres,TRIGGER
intercity_requests,postgres,SELECT
intercity_requests,postgres,UPDATE
intercity_requests,anon,TRUNCATE
intercity_requests,postgres,INSERT
intercity_requests,anon,REFERENCES
intercity_requests,service_role,UPDATE

id,name,owner,created_at,updated_at,public,avif_autodetection,file_size_limit,allowed_mime_types,owner_id,type
rider_kyc,rider_kyc,null,2026-05-11 12:00:21.117329+05:30,2026-05-11 12:00:21.117329+05:30,true,false,3145728,null,null,STANDARD
parcel_images,parcel_images,null,2026-05-21 13:20:19.022978+05:30,2026-05-21 13:20:19.022978+05:30,true,false,10485760,null,null,STANDARD