-- =============================================================================
-- BASELINE MIGRATION PROPOSAL (NOT YET APPLIED ANYWHERE)
-- =============================================================================
-- Purpose:
--   supabase/migrations/ only contains changes made SINCE 2026-05-30. A large
--   part of the schema in production (supabase/migrations_baseline_wip/
--   prod_schema_dump.sql) predates that history and was never captured as a
--   migration. This file reconstructs ONLY those foundational objects so that
--   `supabase migrations up` on a fresh database reproduces production.
--
-- How this file was produced:
--   Every enum, table, function, trigger, policy, index, and constraint in
--   prod_schema_dump.sql was diffed by name against every file in
--   supabase/migrations/. Anything already created (or later altered/renamed)
--   by an existing migration was left out. See the accompanying summary for
--   the full list of what was excluded and why.
--
-- Ordering notes (read before editing):
--   1. `order_type_enum` and `payment_for_enum` ARE included below even
--      though a later migration also creates them, because
--      20260603000003_update_order_type_enum.sql and
--      20260612000006_update_payment_for_enum.sql each DROP and recreate
--      these types with the same final values captured here. The orders/
--      payments tables need *a* valid type to be created against; the later
--      migrations safely redo the swap.
--   2. `rider_assignments.assignment_status` / `order_assignment_logs.assignment_status`
--      are typed as `assignment_status_enum` (the ORIGINAL, now-orphaned
--      type), not `intercity_assignment_status_enum`. Migration
--      20260601000011_add_accepted_by_user_to_enum.sql creates
--      intercity_assignment_status_enum for the first time and switches both
--      columns to it. Using the final type here would make that migration's
--      `CREATE TYPE` fail (type not yet existing at this point in history).
--   3. `orders.created_device_record_id` (and its FK to user_devices) is
--      intentionally OMITTED. user_devices does not exist until
--      20260612000003_compliance_adjustments.sql, which adds this exact
--      column via `ADD COLUMN IF NOT EXISTS ... REFERENCES public.user_devices`.
--      Including it here would break table creation (user_devices doesn't
--      exist yet) and, even if reordered, would make that later ADD COLUMN a
--      silent no-op that skips creating the FK.
--   4. `pricing_zones` omits the chk_latitude / chk_longitude /
--      chk_radius_positive CHECK constraints. They are inline in the prod
--      dump, but 20260612000000_pricing_zones_geofence_constraints.sql adds
--      them again via plain ADD CONSTRAINT (no DROP IF EXISTS guard), so
--      including them here would make that migration fail with
--      "constraint already exists".
--   5. 5 of the 23 missing policies (on rider_payout_accounts,
--      rider_withdrawals, rider_withdrawal_events) are NOT in this file -
--      those tables don't exist yet at this point in history. See the
--      companion file 20260716000010_baseline_foundational_policies_late.sql.
--   6. `rider_assignments.assignment_status` / `order_assignment_logs.assignment_status`
--      have NO DEFAULT here (only NOT NULL), even though the final dump shows
--      DEFAULT 'sent'. 20260601000011_add_accepted_by_user_to_enum.sql does
--      `ALTER COLUMN assignment_status TYPE intercity_assignment_status_enum`;
--      Postgres tries to auto-cast the column's existing DEFAULT expression
--      to the new type, and there is no cast between two unrelated enum
--      types, so a DEFAULT here makes that ALTER COLUMN TYPE fail. Verified
--      by replaying this file + supabase/migrations/*.sql against a real
--      Postgres 17 instance.
--   7. `orders` omits the `check_intercity_parcel_weight` CHECK constraint
--      (inline in the prod dump). 20260603000003_update_order_type_enum.sql
--      converts orders.order_type to text and back to a freshly-created enum;
--      Postgres re-validates every CHECK constraint against the column's new
--      type as part of that ALTER, and "order_type <> 'x'::order_type_enum"
--      has no defined operator once order_type is text, so keeping this
--      constraint here makes that migration fail. It's safely (re)added by
--      20260617000001_intercity_workflow_updates.sql, which DROPs it first.
--
-- This migration must run BEFORE every file currently in supabase/migrations/
-- (the earliest of which is 20260530000000_rider_payout_accounts.sql), which
-- is why its timestamp prefix is earlier than all of them. It has not been
-- moved into supabase/migrations/ or applied anywhere; review it first.
-- =============================================================================


-- =============================================================================
-- 1. ENUM TYPES (17)
-- =============================================================================

CREATE TYPE "public"."activation_status_enum" AS ENUM (
    'inactive',
    'profile_pending',
    'active',
    'suspended'
);

CREATE TYPE "public"."assignment_status_enum" AS ENUM (
    'sent',
    'viewed',
    'accepted',
    'rejected',
    'timed_out',
    'expired',
    'cancelled'
);

CREATE TYPE "public"."cancelled_by_enum" AS ENUM (
    'user',
    'rider',
    'admin',
    'system'
);

CREATE TYPE "public"."kyc_status_enum" AS ENUM (
    'pending',
    'under_review',
    'approved',
    'rejected',
    'resubmitted'
);

CREATE TYPE "public"."order_status_enum" AS ENUM (
    'created',
    'searching',
    'accepted',
    'rider_arrived',
    'picked_up',
    'ongoing',
    'rider_at_drop',
    'completed',
    'delivered',
    'cancelled',
    'expired'
);

-- Included for dependency ordering only: recreated (DROP + CREATE) by
-- 20260603000003_update_order_type_enum.sql with this same final value list.
CREATE TYPE "public"."order_type_enum" AS ENUM (
    'ride',
    'intercity_ride',
    'ride_sharing',
    'local_parcel',
    'intercity_parcel',
    'batch_delivery',
    'food_delivery',
    'grocery_delivery'
);

CREATE TYPE "public"."parcel_type_enum" AS ENUM (
    'documents',
    'electronics',
    'food',
    'clothes',
    'fragile',
    'others'
);

-- Included for dependency ordering only: recreated (DROP + CREATE) by
-- 20260612000006_update_payment_for_enum.sql with this same final value list.
CREATE TYPE "public"."payment_for_enum" AS ENUM (
    'ride_order',
    'parcel_order',
    'wallet_topup',
    'subscription',
    'withdrawal',
    'refund',
    'cod_settlement',
    'ride_boost',
    'intercity_ride_boost',
    'intercity_parcel_boost',
    'intercity_ride_order',
    'intercity_parcel_order',
    'ride_sharing'
);

CREATE TYPE "public"."payment_method_enum" AS ENUM (
    'upi',
    'card',
    'wallet',
    'netbanking',
    'cash',
    'cod',
    'cashfree'
);

CREATE TYPE "public"."payment_mode_enum" AS ENUM (
    'cash',
    'online',
    'wallet'
);

CREATE TYPE "public"."payment_status_enum" AS ENUM (
    'pending',
    'paid',
    'failed',
    'refunded',
    'partial_refund',
    'cash_collected',
    'cash_pending_settlement'
);

CREATE TYPE "public"."preferred_mode_enum" AS ENUM (
    'user',
    'rider'
);

CREATE TYPE "public"."pricing_city_tier_enum" AS ENUM (
    'tier_1',
    'tier_2'
);

CREATE TYPE "public"."pricing_service_type_enum" AS ENUM (
    'ride',
    'local_parcel',
    'intercity_parcel',
    'intercity_ride',
    'ride_sharing'
);

CREATE TYPE "public"."rider_account_status_enum" AS ENUM (
    'online',
    'offline',
    'busy',
    'blocked'
);

CREATE TYPE "public"."subscription_status_enum" AS ENUM (
    'active',
    'expired',
    'cancelled',
    'pending'
);

CREATE TYPE "public"."vehicle_type_enum" AS ENUM (
    'bike',
    'auto',
    'cab'
);


-- =============================================================================
-- 2. TABLES (16)
-- =============================================================================

CREATE TABLE IF NOT EXISTS "public"."admins" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "admin_code" "text" NOT NULL,
    "name" "text" NOT NULL,
    "phone" "text" NOT NULL,
    "email" "text" NOT NULL,
    "password_hash" "text" NOT NULL,
    "role" "text" NOT NULL,
    "permissions" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "is_active" boolean DEFAULT true,
    "is_account_locked" boolean DEFAULT false,
    "last_login_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"()
);

CREATE TABLE IF NOT EXISTS "public"."admin_logs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "admin_id" "uuid" NOT NULL,
    "action_type" "text" NOT NULL,
    "target_type" "text" NOT NULL,
    "target_id" "uuid" NOT NULL,
    "description" "text",
    "metadata" "jsonb" DEFAULT '{}'::"jsonb",
    "ip_address" "text",
    "user_agent" "text",
    "created_at" timestamp with time zone DEFAULT "now"()
);

CREATE TABLE IF NOT EXISTS "public"."dispatch_config" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "config_code" "text" NOT NULL,
    "round_1_radius_km" numeric DEFAULT 3 NOT NULL,
    "round_1_batch_size" integer DEFAULT 3 NOT NULL,
    "round_2_radius_km" numeric DEFAULT 6 NOT NULL,
    "round_2_batch_size" integer DEFAULT 5 NOT NULL,
    "round_3_radius_km" numeric DEFAULT 10 NOT NULL,
    "round_3_batch_size" integer DEFAULT 8 NOT NULL,
    "rider_response_timeout_sec" integer DEFAULT 25 NOT NULL,
    "max_search_duration_sec" integer DEFAULT 900 NOT NULL,
    "reject_cooldown_sec" integer DEFAULT 600 NOT NULL,
    "timeout_cooldown_sec" integer DEFAULT 120 NOT NULL,
    "rider_location_stale_sec" integer DEFAULT 30 NOT NULL,
    "max_active_orders_per_rider" integer DEFAULT 1 NOT NULL,
    "allow_round_3" boolean DEFAULT true,
    "allow_boosted_priority" boolean DEFAULT true,
    "is_active" boolean DEFAULT true,
    "updated_by_admin_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "round_2_trigger_if_no_riders_sec" integer DEFAULT 60,
    "round_2_trigger_after_sec" integer DEFAULT 300,
    "round_3_trigger_after_sec" integer DEFAULT 600
);

CREATE TABLE IF NOT EXISTS "public"."distance_discounts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "km_5_discount" numeric(5,2) DEFAULT 0 NOT NULL,
    "km_10_discount" numeric(5,2) DEFAULT 0 NOT NULL,
    "km_15_discount" numeric(5,2) DEFAULT 0 NOT NULL,
    "km_20_discount" numeric(5,2) DEFAULT 0 NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "km_10_discount_range" CHECK ((("km_10_discount" >= (0)::numeric) AND ("km_10_discount" <= (100)::numeric))),
    CONSTRAINT "km_15_discount_range" CHECK ((("km_15_discount" >= (0)::numeric) AND ("km_15_discount" <= (100)::numeric))),
    CONSTRAINT "km_20_discount_range" CHECK ((("km_20_discount" >= (0)::numeric) AND ("km_20_discount" <= (100)::numeric))),
    CONSTRAINT "km_5_discount_range" CHECK ((("km_5_discount" >= (0)::numeric) AND ("km_5_discount" <= (100)::numeric)))
);

CREATE TABLE IF NOT EXISTS "public"."users" (
    "id" "uuid" NOT NULL,
    "phone" "text",
    "created_at" timestamp with time zone DEFAULT "timezone"('utc'::"text", "now"()),
    "full_name" "text",
    "email" "text",
    "profile_completed" boolean DEFAULT false,
    "onboarding_completed" boolean DEFAULT false,
    "preferred_mode" "public"."preferred_mode_enum" DEFAULT 'user'::"public"."preferred_mode_enum",
    "last_active_mode" "public"."preferred_mode_enum" DEFAULT 'user'::"public"."preferred_mode_enum",
    "role" "text" DEFAULT 'user'::"text",
    "pref_order_notifications" boolean DEFAULT true NOT NULL,
    "pref_chat_notifications" boolean DEFAULT true NOT NULL,
    "pref_rating_notifications" boolean DEFAULT true NOT NULL,
    "pref_admin_notifications" boolean DEFAULT true NOT NULL,
    "user_code" "text",
    "order_notification_mode" "text" DEFAULT 'important_only'::"text" NOT NULL,
    CONSTRAINT "users_order_notification_mode_check" CHECK (("order_notification_mode" = ANY (ARRAY['all'::"text", 'important_only'::"text", 'tracking_silent'::"text"])))
);

ALTER TABLE ONLY "public"."users" REPLICA IDENTITY FULL;

CREATE TABLE IF NOT EXISTS "public"."rider_kyc" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "full_name" "text" NOT NULL,
    "father_name" "text" NOT NULL,
    "vehicle_type" "public"."vehicle_type_enum" NOT NULL,
    "aadhaar_number" "text" NOT NULL,
    "pan_number" "text" NOT NULL,
    "driving_license_number" "text" NOT NULL,
    "vehicle_number" "text" NOT NULL,
    "rider_image" "text" NOT NULL,
    "aadhaar_front_image" "text" NOT NULL,
    "aadhaar_back_image" "text" NOT NULL,
    "pan_front_image" "text" NOT NULL,
    "pan_back_image" "text" NOT NULL,
    "license_front_image" "text" NOT NULL,
    "license_back_image" "text" NOT NULL,
    "vehicle_image" "text" NOT NULL,
    "kyc_status" "public"."kyc_status_enum" DEFAULT 'pending'::"public"."kyc_status_enum" NOT NULL,
    "activation_status" "public"."activation_status_enum" DEFAULT 'inactive'::"public"."activation_status_enum" NOT NULL,
    "handled_by_admin_id" "uuid",
    "approved_at" timestamp with time zone,
    "rejected_at" timestamp with time zone,
    "rejection_reason" "text",
    "activated_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "rejection_count" integer DEFAULT 0,
    "blocked_until" timestamp with time zone,
    "date_of_birth" "date" NOT NULL,
    "VECHILE_RC_front_image" "text",
    "VECHILE_RC_back_image" "text",
    CONSTRAINT "aadhaar_length_check" CHECK (("length"("aadhaar_number") = 12)),
    CONSTRAINT "pan_format_check" CHECK (("pan_number" ~ '^[A-Z]{5}[0-9]{4}[A-Z]{1}$'::"text")),
    CONSTRAINT "rider_minimum_age_check" CHECK (("date_of_birth" <= (CURRENT_DATE - '18 years'::interval)))
);

ALTER TABLE ONLY "public"."rider_kyc" REPLICA IDENTITY FULL;

CREATE TABLE IF NOT EXISTS "public"."riders" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "kyc_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "rating" numeric DEFAULT 5,
    "total_orders" integer DEFAULT 0,
    "total_completed_orders" integer DEFAULT 0,
    "total_cancelled_orders" integer DEFAULT 0,
    "total_earnings" numeric DEFAULT 0,
    "today_earnings" numeric DEFAULT 0,
    "wallet_balance" numeric DEFAULT 0,
    "cod_pending_amount" numeric DEFAULT 0,
    "cod_limit" numeric DEFAULT '500'::numeric,
    "account_status" "public"."rider_account_status_enum" DEFAULT 'offline'::"public"."rider_account_status_enum" NOT NULL,
    "current_lat" double precision,
    "current_lng" double precision,
    "current_heading" double precision,
    "last_location_updated_at" timestamp with time zone,
    "last_active_at" timestamp with time zone,
    "subscription_active" boolean DEFAULT false,
    "subscription_expires_at" timestamp with time zone,
    "commission_waiver_active" boolean DEFAULT false,
    "is_verified" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "last_dormant_notification_sent_at" timestamp with time zone,
    "last_sub_offline_notification_sent_at" timestamp with time zone
);

ALTER TABLE ONLY "public"."riders" REPLICA IDENTITY FULL;

CREATE TABLE IF NOT EXISTS "public"."pricing_zones" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "zone_code" "text" NOT NULL,
    "zone_name" "text" NOT NULL,
    "zone_type" "text" NOT NULL,
    "cities" "text"[] NOT NULL,
    "is_active" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "center_lat" double precision,
    "center_lng" double precision,
    "radius_km" double precision,
    "zone_shape" "text" DEFAULT 'radius'::"text" NOT NULL
    -- chk_latitude / chk_longitude / chk_radius_positive intentionally omitted,
    -- see note (4) at the top of this file.
);

CREATE TABLE IF NOT EXISTS "public"."pricing_config" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "pricing_code" "text" NOT NULL,
    "service_type" "text" NOT NULL,
    "vehicle_type" "text",
    "city_tier" "text",
    "pricing_zone_id" "uuid",
    "commission_percentage" numeric NOT NULL,
    "gst_percentage" numeric DEFAULT 5 NOT NULL,
    "cancellation_fee" numeric DEFAULT 0,
    "waiting_charge_per_min" numeric DEFAULT 0,
    "subscription_commission_waiver" boolean DEFAULT true,
    "max_boost_percentage" numeric DEFAULT 50,
    "pricing_rules" "jsonb" NOT NULL,
    "future_rules" "jsonb" DEFAULT '{}'::"jsonb",
    "approval_status" "text" DEFAULT 'approved'::"text" NOT NULL,
    "approved_by_admin_id" "uuid",
    "approved_at" timestamp with time zone,
    "rejection_reason" "text",
    "is_active" boolean DEFAULT true,
    "effective_from" timestamp with time zone DEFAULT "now"(),
    "effective_until" timestamp with time zone,
    "created_by_admin_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "chk_boost_percentage" CHECK ((("max_boost_percentage" >= (0)::numeric) AND ("max_boost_percentage" <= (500)::numeric))),
    CONSTRAINT "chk_commission_percentage" CHECK ((("commission_percentage" >= (0)::numeric) AND ("commission_percentage" <= (100)::numeric))),
    CONSTRAINT "chk_gst_percentage" CHECK ((("gst_percentage" >= (0)::numeric) AND ("gst_percentage" <= (100)::numeric)))
);

CREATE TABLE IF NOT EXISTS "public"."orders" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "order_code" "text" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "rider_id" "uuid",
    "order_type" "public"."order_type_enum" NOT NULL,
    "vehicle_type" "public"."vehicle_type_enum",
    "order_status" "public"."order_status_enum" DEFAULT 'created'::"public"."order_status_enum" NOT NULL,
    "pricing_config_id" "uuid",
    "distance_meters" integer NOT NULL,
    "distance_km" numeric NOT NULL,
    "estimated_duration_min" integer,
    "actual_duration_min" integer,
    "time_taken_seconds" integer,
    "pickup_address" "text" NOT NULL,
    "pickup_lat" double precision NOT NULL,
    "pickup_lng" double precision NOT NULL,
    "destination_address" "text" NOT NULL,
    "destination_lat" double precision NOT NULL,
    "destination_lng" double precision NOT NULL,
    "actual_fare" numeric NOT NULL,
    "current_fare" numeric NOT NULL,
    "final_fare" numeric,
    "base_fare" numeric DEFAULT 0,
    "distance_fare" numeric DEFAULT 0,
    "time_fare" numeric DEFAULT 0,
    "waiting_charge" numeric DEFAULT 0,
    "platform_fee" numeric DEFAULT 0,
    "gst_percentage" numeric DEFAULT 0,
    "gst_amount" numeric DEFAULT 0,
    "commission_percentage" numeric DEFAULT 0,
    "commission_amount" numeric DEFAULT 0,
    "rider_earning" numeric DEFAULT 0,
    "boost_amount" numeric DEFAULT 0,
    "subscription_commission_waived" boolean DEFAULT false,
    "pricing_snapshot" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "payment_mode" "public"."payment_mode_enum" NOT NULL,
    "payment_status" "public"."payment_status_enum" DEFAULT 'pending'::"public"."payment_status_enum" NOT NULL,
    "payment_id" "uuid",
    "pickup_otp" "text",
    "delivery_otp" "text",
    "search_expires_at" timestamp with time zone,
    "cancelled_by" "public"."cancelled_by_enum",
    "cancel_reason" "text",
    "parcel_type" "public"."parcel_type_enum",
    "receiver_name" "text",
    "receiver_phone" "text",
    "weight_category" "text",
    "actual_weight_kg" numeric,
    "parcel_images" "text"[],
    "special_instructions" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "accepted_at" timestamp with time zone,
    "rider_arrived_at" timestamp with time zone,
    "picked_up_at" timestamp with time zone,
    "rider_at_drop_at" timestamp with time zone,
    "completed_at" timestamp with time zone,
    "cancelled_at" timestamp with time zone,
    "pickup_otp_attempts" integer DEFAULT 0,
    "delivery_otp_attempts" integer DEFAULT 0,
    "boost_company_earning" numeric DEFAULT 0,
    "boost_rider_earning" numeric DEFAULT 0,
    "boost_percentage" numeric DEFAULT 0,
    "dispatch_attempts" integer DEFAULT 0,
    "boost_round" integer DEFAULT 0,
    "current_search_radius_km" numeric DEFAULT 3,
    "last_dispatched_at" timestamp with time zone,
    "rider_rejections_count" integer DEFAULT 0,
    "redispatch_count" integer DEFAULT 0,
    "pickup_city" "text",
    "destination_city" "text",
    "travel_date" timestamp with time zone,
    "dispatch_state" "jsonb" DEFAULT '{}'::"jsonb",
    "created_ip_address" "inet",
    "created_lat" double precision,
    "created_lng" double precision,
    "sender_declaration_accepted" boolean DEFAULT false,
    "sender_declaration_accepted_at" timestamp with time zone,
    "pickup_verification_completed" boolean DEFAULT false,
    "pickup_verification_completed_at" timestamp with time zone,
    "compliance_flagged" boolean DEFAULT false,
    "compliance_notes" "text",
    "created_device_ref" "text",
    "created_device_model" "text",
    "created_device_brand" "text",
    "created_os_version" "text",
    "created_app_version" "text",
    "compliance_status" "text" DEFAULT 'pending'::"text",
    "compliance_score" integer DEFAULT 100,
    "compliance_retention_until" timestamp with time zone,
    "parcel_declared_value" numeric,
    "high_risk_parcel" boolean DEFAULT false,
    "dispatch_worker_running" boolean DEFAULT false,
    "dispatch_worker_started_at" timestamp with time zone,
    -- "created_device_record_id" intentionally omitted here, see note (3) at
    -- the top of this file: 20260612000003_compliance_adjustments.sql adds
    -- it (column + FK to user_devices) once user_devices exists.
    -- "check_intercity_parcel_weight" intentionally omitted here, see note (7):
    -- it references "order_type", and 20260603000003_update_order_type_enum.sql
    -- converts that column to text and back before this constraint would
    -- otherwise be added by 20260617000001_intercity_workflow_updates.sql.
    CONSTRAINT "chk_actual_fare" CHECK (("actual_fare" >= (0)::numeric)),
    CONSTRAINT "chk_commission_percentage" CHECK ((("commission_percentage" >= (0)::numeric) AND ("commission_percentage" <= (100)::numeric))),
    CONSTRAINT "chk_current_fare" CHECK (("current_fare" >= (0)::numeric)),
    CONSTRAINT "chk_distance_km" CHECK (("distance_km" >= (0)::numeric)),
    CONSTRAINT "chk_distance_meters" CHECK (("distance_meters" >= 0)),
    CONSTRAINT "chk_final_fare" CHECK ((("final_fare" IS NULL) OR ("final_fare" >= (0)::numeric))),
    CONSTRAINT "chk_gst_percentage" CHECK ((("gst_percentage" >= (0)::numeric) AND ("gst_percentage" <= (100)::numeric))),
    CONSTRAINT "orders_compliance_status_check" CHECK (("compliance_status" = ANY (ARRAY['pending'::"text", 'verified'::"text", 'flagged'::"text", 'investigating'::"text"])))
);

ALTER TABLE ONLY "public"."orders" REPLICA IDENTITY FULL;

CREATE TABLE IF NOT EXISTS "public"."order_assignment_logs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "order_id" "uuid" NOT NULL,
    "rider_id" "uuid" NOT NULL,
    "assignment_status" "public"."assignment_status_enum" NOT NULL,
    "assignment_round" integer DEFAULT 1,
    "rider_distance_km" numeric,
    "estimated_pickup_time_min" integer,
    "sent_at" timestamp with time zone DEFAULT "now"(),
    "viewed_at" timestamp with time zone,
    "responded_at" timestamp with time zone,
    "rejection_reason" "text",
    "metadata" "jsonb" DEFAULT '{}'::"jsonb",
    "created_at" timestamp with time zone DEFAULT "now"()
);

CREATE TABLE IF NOT EXISTS "public"."order_status_history" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "order_id" "uuid" NOT NULL,
    "previous_status" "text",
    "new_status" "text" NOT NULL,
    "changed_by" "text" NOT NULL,
    "changed_by_user_id" "uuid",
    "changed_by_rider_id" "uuid",
    "changed_by_admin_id" "uuid",
    "notes" "text",
    "metadata" "jsonb" DEFAULT '{}'::"jsonb",
    "created_at" timestamp with time zone DEFAULT "now"()
);

CREATE TABLE IF NOT EXISTS "public"."payments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "payment_code" "text" NOT NULL,
    "user_id" "uuid",
    "rider_id" "uuid",
    "payment_for" "public"."payment_for_enum" NOT NULL,
    "reference_id" "uuid",
    "amount" numeric NOT NULL,
    "gst_amount" numeric DEFAULT 0,
    "platform_fee" numeric DEFAULT 0,
    "discount_amount" numeric DEFAULT 0,
    "final_amount" numeric NOT NULL,
    "payment_method" "public"."payment_method_enum" NOT NULL,
    "payment_gateway" "text",
    "gateway_transaction_id" "text",
    "gateway_order_id" "text",
    "payment_status" "public"."payment_status_enum" DEFAULT 'pending'::"public"."payment_status_enum" NOT NULL,
    "paid_at" timestamp with time zone,
    "refunded_at" timestamp with time zone,
    "refund_reason" "text",
    "metadata" "jsonb" DEFAULT '{}'::"jsonb",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "rider_earning" numeric DEFAULT 0,
    "company_earning" numeric DEFAULT 0,
    "webhook_received" boolean DEFAULT false,
    "webhook_payload" "jsonb",
    "failure_reason" "text",
    "settlement_reference" "text",
    "payment_source" "text"
);

ALTER TABLE ONLY "public"."payments" REPLICA IDENTITY FULL;

CREATE TABLE IF NOT EXISTS "public"."pricing_change_logs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "pricing_config_id" "uuid" NOT NULL,
    "changed_by_admin_id" "uuid" NOT NULL,
    "old_data" "jsonb" NOT NULL,
    "new_data" "jsonb" NOT NULL,
    "change_reason" "text",
    "created_at" timestamp with time zone DEFAULT "now"()
);

CREATE TABLE IF NOT EXISTS "public"."rider_assignments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "order_id" "uuid" NOT NULL,
    "rider_id" "uuid" NOT NULL,
    "assignment_round" integer DEFAULT 1 NOT NULL,
    "assignment_status" "public"."assignment_status_enum" NOT NULL,
    "distance_km" numeric,
    "estimated_earnings" numeric,
    "sent_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "viewed_at" timestamp with time zone,
    "responded_at" timestamp with time zone,
    "expires_at" timestamp with time zone NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "last_seen_at" timestamp with time zone,
    "last_response_at" timestamp with time zone,
    "response_type" "text",
    "hidden_until" timestamp with time zone,
    "last_seen_fare" numeric
);

ALTER TABLE ONLY "public"."rider_assignments" REPLICA IDENTITY FULL;

CREATE TABLE IF NOT EXISTS "public"."rider_subscription_history" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "rider_id" "uuid" NOT NULL,
    "amount" numeric NOT NULL,
    "payment_status" "text" NOT NULL,
    "payment_id" "uuid",
    "starts_at" timestamp with time zone NOT NULL,
    "expires_at" timestamp with time zone NOT NULL,
    "is_active" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "expire_warning_sent" boolean DEFAULT false
);


-- =============================================================================
-- 3. PRIMARY KEY / UNIQUE CONSTRAINTS
-- =============================================================================

ALTER TABLE ONLY "public"."admin_logs" ADD CONSTRAINT "admin_logs_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."admins" ADD CONSTRAINT "admins_admin_code_key" UNIQUE ("admin_code");
ALTER TABLE ONLY "public"."admins" ADD CONSTRAINT "admins_email_key" UNIQUE ("email");
ALTER TABLE ONLY "public"."admins" ADD CONSTRAINT "admins_phone_key" UNIQUE ("phone");
ALTER TABLE ONLY "public"."admins" ADD CONSTRAINT "admins_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."dispatch_config" ADD CONSTRAINT "dispatch_config_config_code_key" UNIQUE ("config_code");
ALTER TABLE ONLY "public"."dispatch_config" ADD CONSTRAINT "dispatch_config_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."distance_discounts" ADD CONSTRAINT "distance_discounts_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."order_assignment_logs" ADD CONSTRAINT "order_assignment_logs_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."order_assignment_logs" ADD CONSTRAINT "unique_order_rider_assignment" UNIQUE ("order_id", "rider_id", "assignment_round");
ALTER TABLE ONLY "public"."order_status_history" ADD CONSTRAINT "order_status_history_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."orders" ADD CONSTRAINT "orders_order_code_key" UNIQUE ("order_code");
ALTER TABLE ONLY "public"."orders" ADD CONSTRAINT "orders_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."payments" ADD CONSTRAINT "payments_payment_code_key" UNIQUE ("payment_code");
ALTER TABLE ONLY "public"."payments" ADD CONSTRAINT "payments_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."pricing_change_logs" ADD CONSTRAINT "pricing_change_logs_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."pricing_config" ADD CONSTRAINT "pricing_config_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."pricing_config" ADD CONSTRAINT "pricing_config_pricing_code_key" UNIQUE ("pricing_code");
ALTER TABLE ONLY "public"."pricing_zones" ADD CONSTRAINT "pricing_zones_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."pricing_zones" ADD CONSTRAINT "pricing_zones_zone_code_key" UNIQUE ("zone_code");
ALTER TABLE ONLY "public"."rider_assignments" ADD CONSTRAINT "rider_assignments_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."rider_kyc" ADD CONSTRAINT "rider_kyc_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."rider_subscription_history" ADD CONSTRAINT "rider_subscription_history_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."riders" ADD CONSTRAINT "riders_kyc_id_key" UNIQUE ("kyc_id");
ALTER TABLE ONLY "public"."riders" ADD CONSTRAINT "riders_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."riders" ADD CONSTRAINT "riders_user_id_key" UNIQUE ("user_id");
ALTER TABLE ONLY "public"."users" ADD CONSTRAINT "users_phone_key" UNIQUE ("phone");
ALTER TABLE ONLY "public"."users" ADD CONSTRAINT "users_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."users" ADD CONSTRAINT "users_user_code_key" UNIQUE ("user_code");


-- =============================================================================
-- 4. FOREIGN KEY CONSTRAINTS
-- =============================================================================
-- NOTE: "orders_created_device_record_id_fkey" is intentionally absent, see
-- note (3) at the top of this file.

ALTER TABLE ONLY "public"."admin_logs" ADD CONSTRAINT "admin_logs_admin_id_fkey" FOREIGN KEY ("admin_id") REFERENCES "public"."admins"("id") ON DELETE CASCADE;
ALTER TABLE ONLY "public"."dispatch_config" ADD CONSTRAINT "dispatch_config_updated_by_admin_id_fkey" FOREIGN KEY ("updated_by_admin_id") REFERENCES "public"."admins"("id") ON DELETE SET NULL;
ALTER TABLE ONLY "public"."order_assignment_logs" ADD CONSTRAINT "order_assignment_logs_order_id_fkey" FOREIGN KEY ("order_id") REFERENCES "public"."orders"("id") ON DELETE CASCADE;
ALTER TABLE ONLY "public"."order_assignment_logs" ADD CONSTRAINT "order_assignment_logs_rider_id_fkey" FOREIGN KEY ("rider_id") REFERENCES "public"."riders"("id") ON DELETE CASCADE;
ALTER TABLE ONLY "public"."order_status_history" ADD CONSTRAINT "order_status_history_changed_by_admin_id_fkey" FOREIGN KEY ("changed_by_admin_id") REFERENCES "public"."admins"("id") ON DELETE SET NULL;
ALTER TABLE ONLY "public"."order_status_history" ADD CONSTRAINT "order_status_history_changed_by_rider_id_fkey" FOREIGN KEY ("changed_by_rider_id") REFERENCES "public"."riders"("id") ON DELETE SET NULL;
ALTER TABLE ONLY "public"."order_status_history" ADD CONSTRAINT "order_status_history_changed_by_user_id_fkey" FOREIGN KEY ("changed_by_user_id") REFERENCES "public"."users"("id") ON DELETE SET NULL;
ALTER TABLE ONLY "public"."order_status_history" ADD CONSTRAINT "order_status_history_order_id_fkey" FOREIGN KEY ("order_id") REFERENCES "public"."orders"("id") ON DELETE CASCADE;
ALTER TABLE ONLY "public"."orders" ADD CONSTRAINT "orders_payment_id_fkey" FOREIGN KEY ("payment_id") REFERENCES "public"."payments"("id") ON DELETE SET NULL;
ALTER TABLE ONLY "public"."orders" ADD CONSTRAINT "orders_pricing_config_id_fkey" FOREIGN KEY ("pricing_config_id") REFERENCES "public"."pricing_config"("id") ON DELETE SET NULL;
ALTER TABLE ONLY "public"."orders" ADD CONSTRAINT "orders_rider_id_fkey" FOREIGN KEY ("rider_id") REFERENCES "public"."riders"("id") ON DELETE SET NULL;
ALTER TABLE ONLY "public"."orders" ADD CONSTRAINT "orders_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE RESTRICT;
ALTER TABLE ONLY "public"."payments" ADD CONSTRAINT "payments_rider_id_fkey" FOREIGN KEY ("rider_id") REFERENCES "public"."riders"("id") ON DELETE SET NULL;
ALTER TABLE ONLY "public"."payments" ADD CONSTRAINT "payments_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE SET NULL;
ALTER TABLE ONLY "public"."pricing_change_logs" ADD CONSTRAINT "pricing_change_logs_changed_by_admin_id_fkey" FOREIGN KEY ("changed_by_admin_id") REFERENCES "public"."admins"("id") ON DELETE RESTRICT;
ALTER TABLE ONLY "public"."pricing_change_logs" ADD CONSTRAINT "pricing_change_logs_pricing_config_id_fkey" FOREIGN KEY ("pricing_config_id") REFERENCES "public"."pricing_config"("id") ON DELETE CASCADE;
ALTER TABLE ONLY "public"."pricing_config" ADD CONSTRAINT "pricing_config_approved_by_admin_id_fkey" FOREIGN KEY ("approved_by_admin_id") REFERENCES "public"."admins"("id") ON DELETE SET NULL;
ALTER TABLE ONLY "public"."pricing_config" ADD CONSTRAINT "pricing_config_created_by_admin_id_fkey" FOREIGN KEY ("created_by_admin_id") REFERENCES "public"."admins"("id") ON DELETE RESTRICT;
ALTER TABLE ONLY "public"."pricing_config" ADD CONSTRAINT "pricing_config_pricing_zone_id_fkey" FOREIGN KEY ("pricing_zone_id") REFERENCES "public"."pricing_zones"("id") ON DELETE SET NULL;
ALTER TABLE ONLY "public"."rider_assignments" ADD CONSTRAINT "rider_assignments_order_id_fkey" FOREIGN KEY ("order_id") REFERENCES "public"."orders"("id") ON DELETE CASCADE;
ALTER TABLE ONLY "public"."rider_assignments" ADD CONSTRAINT "rider_assignments_rider_id_fkey" FOREIGN KEY ("rider_id") REFERENCES "public"."riders"("id") ON DELETE CASCADE;
ALTER TABLE ONLY "public"."rider_kyc" ADD CONSTRAINT "rider_kyc_handled_by_admin_id_fkey" FOREIGN KEY ("handled_by_admin_id") REFERENCES "public"."admins"("id");
ALTER TABLE ONLY "public"."rider_kyc" ADD CONSTRAINT "rider_kyc_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;
ALTER TABLE ONLY "public"."rider_subscription_history" ADD CONSTRAINT "rider_subscription_history_payment_id_fkey" FOREIGN KEY ("payment_id") REFERENCES "public"."payments"("id") ON DELETE SET NULL;
ALTER TABLE ONLY "public"."rider_subscription_history" ADD CONSTRAINT "rider_subscription_history_rider_id_fkey" FOREIGN KEY ("rider_id") REFERENCES "public"."riders"("id") ON DELETE CASCADE;
ALTER TABLE ONLY "public"."riders" ADD CONSTRAINT "riders_kyc_id_fkey" FOREIGN KEY ("kyc_id") REFERENCES "public"."rider_kyc"("id") ON DELETE CASCADE;
ALTER TABLE ONLY "public"."riders" ADD CONSTRAINT "riders_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;
ALTER TABLE ONLY "public"."users" ADD CONSTRAINT "users_id_fkey" FOREIGN KEY ("id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;


-- =============================================================================
-- 5. INDEXES
-- =============================================================================

CREATE INDEX "idx_admin_logs_action_type" ON "public"."admin_logs" USING "btree" ("action_type");
CREATE INDEX "idx_admin_logs_admin_id" ON "public"."admin_logs" USING "btree" ("admin_id");
CREATE INDEX "idx_admin_logs_created_at" ON "public"."admin_logs" USING "btree" ("created_at" DESC);
CREATE INDEX "idx_admin_logs_target_id" ON "public"."admin_logs" USING "btree" ("target_id");
CREATE UNIQUE INDEX "idx_distance_discounts_active" ON "public"."distance_discounts" USING "btree" ("is_active") WHERE ("is_active" = true);
CREATE INDEX "idx_order_assignment_logs_assignment_round" ON "public"."order_assignment_logs" USING "btree" ("assignment_round");
CREATE INDEX "idx_order_assignment_logs_assignment_status" ON "public"."order_assignment_logs" USING "btree" ("assignment_status");
CREATE INDEX "idx_order_assignment_logs_order_id" ON "public"."order_assignment_logs" USING "btree" ("order_id");
CREATE INDEX "idx_order_assignment_logs_rider_id" ON "public"."order_assignment_logs" USING "btree" ("rider_id");
CREATE INDEX "idx_order_assignment_logs_sent_at" ON "public"."order_assignment_logs" USING "btree" ("sent_at" DESC);
CREATE INDEX "idx_order_status_history_created_at" ON "public"."order_status_history" USING "btree" ("created_at" DESC);
CREATE INDEX "idx_order_status_history_new_status" ON "public"."order_status_history" USING "btree" ("new_status");
CREATE INDEX "idx_order_status_history_order_id" ON "public"."order_status_history" USING "btree" ("order_id");
CREATE INDEX "idx_orders_created_at" ON "public"."orders" USING "btree" ("created_at" DESC);
CREATE INDEX "idx_orders_destination_location" ON "public"."orders" USING "btree" ("destination_lat", "destination_lng");
CREATE INDEX "idx_orders_order_code" ON "public"."orders" USING "btree" ("order_code");
CREATE INDEX "idx_orders_order_status" ON "public"."orders" USING "btree" ("order_status");
CREATE INDEX "idx_orders_order_type" ON "public"."orders" USING "btree" ("order_type");
CREATE INDEX "idx_orders_payment_id" ON "public"."orders" USING "btree" ("payment_id");
CREATE INDEX "idx_orders_payment_status" ON "public"."orders" USING "btree" ("payment_status");
CREATE INDEX "idx_orders_pickup_location" ON "public"."orders" USING "btree" ("pickup_lat", "pickup_lng");
CREATE INDEX "idx_orders_pricing_config_id" ON "public"."orders" USING "btree" ("pricing_config_id");
CREATE INDEX "idx_orders_rider_id" ON "public"."orders" USING "btree" ("rider_id");
CREATE INDEX "idx_orders_search_expires_at" ON "public"."orders" USING "btree" ("search_expires_at");
CREATE INDEX "idx_orders_user_id" ON "public"."orders" USING "btree" ("user_id");
CREATE INDEX "idx_orders_vehicle_type" ON "public"."orders" USING "btree" ("vehicle_type");
CREATE INDEX "idx_payments_created_at" ON "public"."payments" USING "btree" ("created_at" DESC);
CREATE INDEX "idx_payments_payment_status" ON "public"."payments" USING "btree" ("payment_status");
CREATE INDEX "idx_payments_reference_id" ON "public"."payments" USING "btree" ("reference_id");
CREATE INDEX "idx_payments_rider_id" ON "public"."payments" USING "btree" ("rider_id");
CREATE INDEX "idx_payments_user_id" ON "public"."payments" USING "btree" ("user_id");
CREATE INDEX "idx_pricing_change_logs_changed_by_admin_id" ON "public"."pricing_change_logs" USING "btree" ("changed_by_admin_id");
CREATE INDEX "idx_pricing_change_logs_created_at" ON "public"."pricing_change_logs" USING "btree" ("created_at" DESC);
CREATE INDEX "idx_pricing_change_logs_pricing_config_id" ON "public"."pricing_change_logs" USING "btree" ("pricing_config_id");
CREATE INDEX "idx_pricing_config_approval_status" ON "public"."pricing_config" USING "btree" ("approval_status");
CREATE INDEX "idx_pricing_config_city_tier" ON "public"."pricing_config" USING "btree" ("city_tier");
CREATE INDEX "idx_pricing_config_created_at" ON "public"."pricing_config" USING "btree" ("created_at" DESC);
CREATE INDEX "idx_pricing_config_is_active" ON "public"."pricing_config" USING "btree" ("is_active");
CREATE INDEX "idx_pricing_config_service_type" ON "public"."pricing_config" USING "btree" ("service_type");
CREATE INDEX "idx_pricing_config_vehicle_type" ON "public"."pricing_config" USING "btree" ("vehicle_type");
CREATE INDEX "idx_rider_assignments_expires_at" ON "public"."rider_assignments" USING "btree" ("expires_at" DESC);
CREATE INDEX "idx_rider_assignments_order_id" ON "public"."rider_assignments" USING "btree" ("order_id");
CREATE INDEX "idx_rider_assignments_rider_id" ON "public"."rider_assignments" USING "btree" ("rider_id");
CREATE INDEX "idx_rider_assignments_round" ON "public"."rider_assignments" USING "btree" ("assignment_round");
CREATE INDEX "idx_rider_assignments_status" ON "public"."rider_assignments" USING "btree" ("assignment_status");
CREATE INDEX "idx_rider_kyc_activation_status" ON "public"."rider_kyc" USING "btree" ("activation_status");
CREATE INDEX "idx_rider_kyc_created_at" ON "public"."rider_kyc" USING "btree" ("created_at" DESC);
CREATE INDEX "idx_rider_kyc_handled_by_admin_id" ON "public"."rider_kyc" USING "btree" ("handled_by_admin_id");
CREATE INDEX "idx_rider_kyc_kyc_status" ON "public"."rider_kyc" USING "btree" ("kyc_status");
CREATE INDEX "idx_rider_kyc_user_id" ON "public"."rider_kyc" USING "btree" ("user_id");
CREATE INDEX "idx_rider_subscription_created_at" ON "public"."rider_subscription_history" USING "btree" ("created_at" DESC);
CREATE INDEX "idx_rider_subscription_expires_at" ON "public"."rider_subscription_history" USING "btree" ("expires_at" DESC);
CREATE INDEX "idx_rider_subscription_is_active" ON "public"."rider_subscription_history" USING "btree" ("is_active");
CREATE INDEX "idx_rider_subscription_payment_id" ON "public"."rider_subscription_history" USING "btree" ("payment_id");
CREATE INDEX "idx_rider_subscription_rider_id" ON "public"."rider_subscription_history" USING "btree" ("rider_id");
CREATE INDEX "idx_riders_account_status" ON "public"."riders" USING "btree" ("account_status");
CREATE INDEX "idx_riders_created_at" ON "public"."riders" USING "btree" ("created_at" DESC);
CREATE INDEX "idx_riders_current_lat" ON "public"."riders" USING "btree" ("current_lat");
CREATE INDEX "idx_riders_current_lng" ON "public"."riders" USING "btree" ("current_lng");
CREATE INDEX "idx_riders_kyc_id" ON "public"."riders" USING "btree" ("kyc_id");
CREATE INDEX "idx_riders_location_updated" ON "public"."riders" USING "btree" ("last_location_updated_at" DESC);
CREATE INDEX "idx_riders_subscription_active" ON "public"."riders" USING "btree" ("subscription_active");
CREATE INDEX "idx_riders_user_id" ON "public"."riders" USING "btree" ("user_id");
CREATE UNIQUE INDEX "idx_unique_gateway_txn" ON "public"."payments" USING "btree" ("gateway_transaction_id");
CREATE UNIQUE INDEX "idx_unique_pending_payment" ON "public"."payments" USING "btree" ("user_id", "payment_for", "reference_id") WHERE ("payment_status" = 'pending'::"public"."payment_status_enum");
CREATE UNIQUE INDEX "idx_unique_subscription_payment" ON "public"."rider_subscription_history" USING "btree" ("payment_id");
CREATE UNIQUE INDEX "unique_active_pricing_config" ON "public"."pricing_config" USING "btree" ("service_type", COALESCE("vehicle_type", ''::"text"), COALESCE(("pricing_zone_id")::"text", ''::"text")) WHERE ("is_active" = true);


-- =============================================================================
-- 6. FUNCTIONS
-- =============================================================================

CREATE OR REPLACE FUNCTION "public"."cancel_order"("p_order_id" "uuid", "p_cancelled_by" "text", "p_cancel_reason" "text" DEFAULT NULL::"text", "p_rider_id" "uuid" DEFAULT NULL::"uuid", "p_user_id" "uuid" DEFAULT NULL::"uuid", "p_admin_id" "uuid" DEFAULT NULL::"uuid") RETURNS json
    LANGUAGE "plpgsql"
    AS $$
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
$$;

CREATE OR REPLACE FUNCTION "public"."reject_order"("p_order_id" "uuid", "p_rider_id" "uuid", "p_rejection_reason" "text" DEFAULT NULL::"text") RETURNS json
    LANGUAGE "plpgsql"
    AS $$
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
$$;

CREATE OR REPLACE FUNCTION "public"."timeout_assignment"("p_order_id" "uuid", "p_rider_id" "uuid") RETURNS json
    LANGUAGE "plpgsql"
    AS $$
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
$$;

CREATE OR REPLACE FUNCTION "public"."create_rider_profile_on_activation"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
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
$$;


-- =============================================================================
-- 7. TRIGGERS
-- =============================================================================

CREATE OR REPLACE TRIGGER "trigger_create_rider_profile" AFTER UPDATE OF "kyc_status", "activation_status" ON "public"."rider_kyc" FOR EACH ROW WHEN ((("new"."kyc_status" = 'approved'::"public"."kyc_status_enum") AND ("new"."activation_status" = 'active'::"public"."activation_status_enum"))) EXECUTE FUNCTION "public"."create_rider_profile_on_activation"();


-- =============================================================================
-- 8. ROW LEVEL SECURITY
-- =============================================================================

ALTER TABLE "public"."admin_logs" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."admins" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."dispatch_config" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."distance_discounts" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."order_assignment_logs" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."order_status_history" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."orders" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."payments" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."pricing_change_logs" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."pricing_config" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."pricing_zones" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."rider_assignments" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."rider_kyc" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."rider_subscription_history" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."riders" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."users" ENABLE ROW LEVEL SECURITY;


-- =============================================================================
-- 9. POLICIES
-- =============================================================================

CREATE POLICY "Public read distance_discounts" ON "public"."distance_discounts" FOR SELECT TO "authenticated", "anon" USING (true);

CREATE POLICY "Authenticated can insert rider assignments" ON "public"."rider_assignments" FOR INSERT TO "authenticated" WITH CHECK (true);

CREATE POLICY "Riders can insert own KYC" ON "public"."rider_kyc" FOR INSERT WITH CHECK (("auth"."uid"() = "user_id"));

CREATE POLICY "Riders can update own assignments" ON "public"."rider_assignments" FOR UPDATE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."riders" "r"
  WHERE (("r"."id" = "rider_assignments"."rider_id") AND ("r"."user_id" = "auth"."uid"()))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."riders" "r"
  WHERE (("r"."id" = "rider_assignments"."rider_id") AND ("r"."user_id" = "auth"."uid"())))));

CREATE POLICY "Riders can update own rider profile" ON "public"."riders" FOR UPDATE USING (("auth"."uid"() = "user_id"));

CREATE POLICY "Riders can view own KYC" ON "public"."rider_kyc" FOR SELECT USING (("auth"."uid"() = "user_id"));

CREATE POLICY "Riders can view own assignments" ON "public"."rider_assignments" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."riders" "r"
  WHERE (("r"."id" = "rider_assignments"."rider_id") AND ("r"."user_id" = "auth"."uid"())))));

CREATE POLICY "Riders can view own rider profile" ON "public"."riders" FOR SELECT USING (("auth"."uid"() = "user_id"));

CREATE POLICY "Users can insert own profile" ON "public"."users" FOR INSERT TO "authenticated" WITH CHECK (("auth"."uid"() = "id"));

CREATE POLICY "Users can update own profile" ON "public"."users" FOR UPDATE TO "authenticated" USING (("auth"."uid"() = "id"));

CREATE POLICY "Users can create own kyc" ON "public"."rider_kyc" FOR INSERT TO "authenticated" WITH CHECK (("auth"."uid"() = "user_id"));

CREATE POLICY "Users can update own kyc" ON "public"."rider_kyc" FOR UPDATE TO "authenticated" USING (("auth"."uid"() = "user_id"));

CREATE POLICY "Users can view own kyc" ON "public"."rider_kyc" FOR SELECT TO "authenticated" USING (("auth"."uid"() = "user_id"));

CREATE POLICY "Users can view own profile" ON "public"."users" FOR SELECT TO "authenticated" USING (("auth"."uid"() = "id"));

CREATE POLICY "Users can view own rider profile" ON "public"."riders" FOR SELECT TO "authenticated" USING (("auth"."uid"() = "user_id"));

CREATE POLICY "rider_can_view_assigned_orders" ON "public"."orders" FOR SELECT TO "authenticated" USING (("rider_id" IN ( SELECT "riders"."id"
   FROM "public"."riders"
  WHERE ("riders"."user_id" = "auth"."uid"()))));

CREATE POLICY "user_can_update_own_order" ON "public"."orders" FOR UPDATE TO "authenticated" USING ((("auth"."uid"() = "user_id") AND ("order_status" = 'searching'::"public"."order_status_enum"))) WITH CHECK (("auth"."uid"() = "user_id"));

CREATE POLICY "user_can_view_own_orders" ON "public"."orders" FOR SELECT TO "authenticated" USING (("auth"."uid"() = "user_id"));


-- =============================================================================
-- 10. GRANTS
-- =============================================================================

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."admin_logs" TO "anon";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."admin_logs" TO "authenticated";
GRANT SELECT,INSERT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."admin_logs" TO "service_role";

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."admins" TO "anon";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."admins" TO "authenticated";
GRANT SELECT,INSERT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN,UPDATE ON TABLE "public"."admins" TO "service_role";

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."dispatch_config" TO "anon";
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."dispatch_config" TO "authenticated";
GRANT ALL ON TABLE "public"."dispatch_config" TO "service_role";

GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."distance_discounts" TO "anon";
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."distance_discounts" TO "authenticated";
GRANT ALL ON TABLE "public"."distance_discounts" TO "service_role";

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."order_assignment_logs" TO "anon";
GRANT SELECT,INSERT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN,UPDATE ON TABLE "public"."order_assignment_logs" TO "authenticated";
GRANT ALL ON TABLE "public"."order_assignment_logs" TO "service_role";

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."order_status_history" TO "anon";
GRANT SELECT,INSERT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."order_status_history" TO "authenticated";
GRANT ALL ON TABLE "public"."order_status_history" TO "service_role";

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."orders" TO "anon";
GRANT SELECT,INSERT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN,UPDATE ON TABLE "public"."orders" TO "authenticated";
GRANT ALL ON TABLE "public"."orders" TO "service_role";

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."payments" TO "anon";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."payments" TO "authenticated";
GRANT ALL ON TABLE "public"."payments" TO "service_role";

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."pricing_change_logs" TO "anon";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."pricing_change_logs" TO "authenticated";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."pricing_change_logs" TO "service_role";

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."pricing_config" TO "anon";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."pricing_config" TO "authenticated";
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN,UPDATE ON TABLE "public"."pricing_config" TO "service_role";

GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."pricing_zones" TO "anon";
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."pricing_zones" TO "authenticated";
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."pricing_zones" TO "service_role";

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."rider_assignments" TO "anon";
GRANT SELECT,INSERT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN,UPDATE ON TABLE "public"."rider_assignments" TO "authenticated";
GRANT ALL ON TABLE "public"."rider_assignments" TO "service_role";

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."rider_kyc" TO "anon";
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."rider_kyc" TO "authenticated";
GRANT ALL ON TABLE "public"."rider_kyc" TO "service_role";

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."rider_subscription_history" TO "anon";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."rider_subscription_history" TO "authenticated";
GRANT ALL ON TABLE "public"."rider_subscription_history" TO "service_role";

GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."riders" TO "anon";
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN,UPDATE ON TABLE "public"."riders" TO "authenticated";
GRANT ALL ON TABLE "public"."riders" TO "service_role";

GRANT SELECT ON TABLE "public"."users" TO "anon";
GRANT SELECT,INSERT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN,UPDATE ON TABLE "public"."users" TO "authenticated";
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."users" TO "service_role";
