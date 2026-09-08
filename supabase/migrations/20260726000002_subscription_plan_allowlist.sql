-- =============================================================================
-- SECURITY FIX: server-authoritative subscription plan allowlist
--
-- Prior architecture: create-payment/index.ts trusted the client-supplied `amount`
-- verbatim for payment_for = 'subscription' (the order-fare branch already correctly
-- recomputes the fare server-side, but the subscription branch did not). Both
-- cashfree-webhook and verify-payment then computed subscription_expires_at from
-- `payments.metadata.days`, also entirely client-supplied at create-payment time and
-- never cross-checked against the amount actually paid. A tampered client could
-- request e.g. amount=1 with metadata.days=999 and, after a genuine ₹1 Cashfree
-- payment, receive a 999-day zero-commission subscription.
--
-- Fix: the plan (amount + duration) now lives here, server-side, as an allowlist.
-- create-payment looks up the plan by `plan_id` (the only subscription-related field
-- the client may specify) and derives the real order_amount from this table --
-- client `amount`/`metadata.days` are no longer trusted for subscriptions at all.
-- cashfree-webhook/verify-payment derive duration_hours from `payments.plan_id`
-- (persisted at creation time, from THIS table), never from client metadata.
-- =============================================================================

CREATE TABLE IF NOT EXISTS "public"."subscription_plans" (
    "plan_id" "text" PRIMARY KEY,
    "label" "text" NOT NULL,
    "amount" numeric NOT NULL CHECK ("amount" > 0),
    "duration_hours" integer NOT NULL CHECK ("duration_hours" > 0),
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);

ALTER TABLE "public"."subscription_plans" ENABLE ROW LEVEL SECURITY;
-- No policies: only service-role callers (create-payment, cashfree-webhook,
-- verify-payment) ever need to read this table, same posture as dispatch_config.

INSERT INTO "public"."subscription_plans" ("plan_id", "label", "amount", "duration_hours")
VALUES
    ('daily', '1 Day Pass', 40, 24),
    ('weekly', '7 Days (1 Week)', 280, 168)
ON CONFLICT ("plan_id") DO NOTHING;

-- Persist which allowlisted plan a subscription payment was created for, so
-- cashfree-webhook/verify-payment can derive the authoritative duration_hours from
-- THIS table via the payment row itself, instead of trusting client metadata.
ALTER TABLE "public"."payments"
    ADD COLUMN IF NOT EXISTS "plan_id" "text" REFERENCES "public"."subscription_plans"("plan_id");

CREATE INDEX IF NOT EXISTS "idx_payments_plan_id" ON "public"."payments" USING "btree" ("plan_id")
    WHERE "plan_id" IS NOT NULL;
