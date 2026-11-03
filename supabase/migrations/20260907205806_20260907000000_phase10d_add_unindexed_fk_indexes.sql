-- Migration: add covering indexes for 43 unindexed foreign keys.
-- Date: 2026-09-07
-- Source: PHASE 10B Supabase Performance Diagnostics (§6b), advisor `unindexed_foreign_keys`
--         (INFO x43). Cross-verified 2026-09-07 against live pg_constraint / pg_indexes on
--         project yvwpchffctiagevpqgwy -- every constraint below has NO btree index whose
--         leading column(s) match its referencing column(s), and none of the index names
--         created here collide with an existing index.
--
-- ============================================================================================
-- WHY
-- ============================================================================================
-- An un-indexed FK referencing column forces a sequential scan of the child table on every
-- DELETE / key-UPDATE of the parent row (the FK's ON DELETE / ON UPDATE action check), and
-- also on any application join that filters the child by that column. It additionally makes
-- PostgREST resource embedding (`orders?select=...,rider_reviews(...)`) scan instead of seek.
--
-- ============================================================================================
-- WHY PLAIN `CREATE INDEX` (not CONCURRENTLY)
-- ============================================================================================
-- Every target table is tiny (largest is `orders` at ~1,100 rows; most are < 100). A plain
-- build takes single-digit milliseconds and the ACCESS EXCLUSIVE lock it holds is momentary.
-- `CREATE INDEX CONCURRENTLY` cannot run inside a transaction block, and both `supabase db
-- push` and the MCP `apply_migration` path wrap each migration in one -- so CONCURRENTLY here
-- would abort the migration. `IF NOT EXISTS` keeps this file idempotent and safe to re-run.
--
-- This migration is purely additive: no table data, no constraints, no policies, no functions
-- are touched. It is reversible in seconds (`DROP INDEX`).
-- ============================================================================================

-- deleted_user_archive
CREATE INDEX IF NOT EXISTS idx_deleted_user_archive_deletion_request_id
  ON public.deleted_user_archive (deletion_request_id);

-- dispatch_config
CREATE INDEX IF NOT EXISTS idx_dispatch_config_updated_by_admin_id
  ON public.dispatch_config (updated_by_admin_id);

-- intercity_requests
CREATE INDEX IF NOT EXISTS idx_intercity_requests_route_id
  ON public.intercity_requests (route_id);
CREATE INDEX IF NOT EXISTS idx_intercity_requests_sender_id
  ON public.intercity_requests (sender_id);
CREATE INDEX IF NOT EXISTS idx_intercity_requests_traveller_id
  ON public.intercity_requests (traveller_id);

-- notification_failures
CREATE INDEX IF NOT EXISTS idx_notification_failures_notification_id
  ON public.notification_failures (notification_id);

-- order_chat_messages
CREATE INDEX IF NOT EXISTS idx_order_chat_messages_rider_id
  ON public.order_chat_messages (rider_id);
CREATE INDEX IF NOT EXISTS idx_order_chat_messages_sender_id
  ON public.order_chat_messages (sender_id);
CREATE INDEX IF NOT EXISTS idx_order_chat_messages_user_id
  ON public.order_chat_messages (user_id);

-- order_declarations
CREATE INDEX IF NOT EXISTS idx_order_declarations_order_id
  ON public.order_declarations (order_id);
CREATE INDEX IF NOT EXISTS idx_order_declarations_user_id
  ON public.order_declarations (user_id);

-- order_parcel_photos
CREATE INDEX IF NOT EXISTS idx_order_parcel_photos_order_id
  ON public.order_parcel_photos (order_id);
CREATE INDEX IF NOT EXISTS idx_order_parcel_photos_rider_id
  ON public.order_parcel_photos (rider_id);

-- order_status_history
CREATE INDEX IF NOT EXISTS idx_order_status_history_changed_by_admin_id
  ON public.order_status_history (changed_by_admin_id);
CREATE INDEX IF NOT EXISTS idx_order_status_history_changed_by_rider_id
  ON public.order_status_history (changed_by_rider_id);
CREATE INDEX IF NOT EXISTS idx_order_status_history_changed_by_user_id
  ON public.order_status_history (changed_by_user_id);

-- order_verifications
CREATE INDEX IF NOT EXISTS idx_order_verifications_created_by
  ON public.order_verifications (created_by);
CREATE INDEX IF NOT EXISTS idx_order_verifications_order_id
  ON public.order_verifications (order_id);

-- orders
CREATE INDEX IF NOT EXISTS idx_orders_created_device_record_id
  ON public.orders (created_device_record_id);

-- parcel_compliance_reports
CREATE INDEX IF NOT EXISTS idx_parcel_compliance_reports_generated_by
  ON public.parcel_compliance_reports (generated_by);
CREATE INDEX IF NOT EXISTS idx_parcel_compliance_reports_order_id
  ON public.parcel_compliance_reports (order_id);

-- parcel_security_logs
CREATE INDEX IF NOT EXISTS idx_parcel_security_logs_order_id
  ON public.parcel_security_logs (order_id);
CREATE INDEX IF NOT EXISTS idx_parcel_security_logs_rider_id
  ON public.parcel_security_logs (rider_id);
CREATE INDEX IF NOT EXISTS idx_parcel_security_logs_sender_user_id
  ON public.parcel_security_logs (sender_user_id);

-- payment_disputes
CREATE INDEX IF NOT EXISTS idx_payment_disputes_raised_by
  ON public.payment_disputes (raised_by);
CREATE INDEX IF NOT EXISTS idx_payment_disputes_resolved_by
  ON public.payment_disputes (resolved_by);

-- police_sos_logs
CREATE INDEX IF NOT EXISTS idx_police_sos_logs_order_id
  ON public.police_sos_logs (order_id);
CREATE INDEX IF NOT EXISTS idx_police_sos_logs_rider_id
  ON public.police_sos_logs (rider_id);

-- pricing_config
CREATE INDEX IF NOT EXISTS idx_pricing_config_approved_by_admin_id
  ON public.pricing_config (approved_by_admin_id);
CREATE INDEX IF NOT EXISTS idx_pricing_config_created_by_admin_id
  ON public.pricing_config (created_by_admin_id);
CREATE INDEX IF NOT EXISTS idx_pricing_config_pricing_zone_id
  ON public.pricing_config (pricing_zone_id);

-- production_config
CREATE INDEX IF NOT EXISTS idx_production_config_updated_by_admin_id
  ON public.production_config (updated_by_admin_id);

-- promo_code_users
CREATE INDEX IF NOT EXISTS idx_promo_code_users_user_id
  ON public.promo_code_users (user_id);

-- reward_config
CREATE INDEX IF NOT EXISTS idx_reward_config_updated_by_admin_id
  ON public.reward_config (updated_by_admin_id);

-- reward_cycles
CREATE INDEX IF NOT EXISTS idx_reward_cycles_redeemed_offer_id
  ON public.reward_cycles (redeemed_offer_id);

-- rider_travel_plans
CREATE INDEX IF NOT EXISTS idx_rider_travel_plans_rider_id
  ON public.rider_travel_plans (rider_id);

-- rider_vehicles
CREATE INDEX IF NOT EXISTS idx_rider_vehicles_reviewed_by
  ON public.rider_vehicles (reviewed_by);

-- trip_share_tokens
CREATE INDEX IF NOT EXISTS idx_trip_share_tokens_order_id
  ON public.trip_share_tokens (order_id);

-- user_device_tokens
CREATE INDEX IF NOT EXISTS idx_user_device_tokens_user_device_id
  ON public.user_device_tokens (user_device_id);

-- user_devices
CREATE INDEX IF NOT EXISTS idx_user_devices_user_id
  ON public.user_devices (user_id);

-- user_promo_usages
CREATE INDEX IF NOT EXISTS idx_user_promo_usages_order_id
  ON public.user_promo_usages (order_id);
CREATE INDEX IF NOT EXISTS idx_user_promo_usages_promo_code_id
  ON public.user_promo_usages (promo_code_id);

-- wallet_transactions
CREATE INDEX IF NOT EXISTS idx_wallet_transactions_rider_id
  ON public.wallet_transactions (rider_id);
