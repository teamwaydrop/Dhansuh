-- =============================================================================
-- Vehicle-specific, Supabase-configurable daily subscription pricing.
--
-- BUSINESS REQUIREMENT: the flat "₹40 for every verified vehicle" daily subscription price must
-- become independently configurable per vehicle_type (bike / auto / cab), changeable directly in
-- Supabase with zero Flutter/Edge-Function redeploy. The existing 30-day free trial
-- (activate_rider_free_trial(), 20260901000016_rider_free_trial.sql) and the flat weekly plan are
-- both completely out of scope and untouched by this migration.
--
-- DESIGN: extends the existing server-authoritative subscription_plans allowlist
-- (20260726000002_subscription_plan_allowlist.sql) rather than introducing a parallel pricing
-- system. create-payment/index.ts already resolves the real charge amount exclusively from this
-- table via a client-supplied `plan_id` (never a client-supplied amount) -- that pattern is
-- reused unchanged; only the plan rows themselves become vehicle-specific:
--   - The old flat 'daily' plan_id is DEACTIVATED (is_active=false), never deleted -- it stays a
--     valid FK target for any historical payments.plan_id='daily' row.
--   - Three new plan rows are added: 'daily_bike' / 'daily_auto' / 'daily_cab', each carrying its
--     own `vehicle_type` and seeded at the SAME ₹40 the flat plan already charged today, so this
--     migration itself changes NO partner's price -- an admin changes prices later by editing
--     these rows' `amount` column directly in Supabase.
--   - 'weekly' is untouched: vehicle_type stays NULL, unaffected by any of this.
--
-- A partial unique index enforces "at most one ACTIVE price per vehicle_type" at the database
-- level -- an admin can never accidentally leave two active bike prices live simultaneously.
--
-- Client apps may now also read active plan rows directly (new RLS SELECT policy, `is_active`
-- rows only) purely for PRICE DISPLAY -- create-payment/cashfree-webhook/verify-payment remain
-- the sole authority for the actual charge amount (service-role, bypasses RLS regardless).
-- =============================================================================

ALTER TABLE "public"."subscription_plans"
    ADD COLUMN IF NOT EXISTS "vehicle_type" "public"."vehicle_type_enum";

-- Enforce "exactly one active price per vehicle type" at the database level.
CREATE UNIQUE INDEX IF NOT EXISTS "uq_subscription_plans_active_vehicle_type"
    ON "public"."subscription_plans" ("vehicle_type")
    WHERE ("is_active" AND "vehicle_type" IS NOT NULL);

-- Deactivate (never delete) the old flat daily plan -- payments.plan_id still references it for
-- every historical daily-plan purchase made before this migration.
UPDATE "public"."subscription_plans"
SET "is_active" = false, "updated_at" = "now"()
WHERE "plan_id" = 'daily';

-- Seed the 3 vehicle-specific daily plans at the CURRENT ₹40 price -- no partner's price changes
-- as a result of this migration. An admin changes a vehicle's price later with a plain
-- `UPDATE public.subscription_plans SET amount = <new_price> WHERE plan_id = 'daily_<vehicle>';`
-- in Supabase -- no migration, Edge Function deploy, or APK rebuild required for that.
INSERT INTO "public"."subscription_plans" ("plan_id", "label", "amount", "duration_hours", "vehicle_type")
VALUES
    ('daily_bike', 'Bike - 1 Day Pass', 40, 24, 'bike'),
    ('daily_auto', 'Auto - 1 Day Pass', 40, 24, 'auto'),
    ('daily_cab', 'Cab - 1 Day Pass', 40, 24, 'cab')
ON CONFLICT ("plan_id") DO NOTHING;

-- The original migration deliberately added no RLS policies at all ("only service-role callers
-- ever need to read this table"). That's no longer true once Flutter needs to display the current
-- price per vehicle before purchase -- add a narrow, read-only, active-rows-only policy. This
-- exposes only price/label/duration for currently-active plans, nothing sensitive, and does not
-- change who may WRITE to this table (still service-role only, no INSERT/UPDATE/DELETE policy
-- exists for `authenticated`) or who is trusted for the actual charge amount (create-payment,
-- unchanged, still service-role, still ignores any client-supplied amount).
CREATE POLICY "Authenticated can view active subscription plans" ON "public"."subscription_plans"
    FOR SELECT TO "authenticated"
    USING ("is_active" = true);

GRANT SELECT ON TABLE "public"."subscription_plans" TO "authenticated";
