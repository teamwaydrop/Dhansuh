-- =============================================================================
-- GOVERNMENT TAX DUE: schema (additive only).
--
-- New, independent financial system tracking amounts WayDrop needs to recover from a Drop
-- Partner for configured business tax obligations on completed services -- entirely separate
-- from rider earnings, wallet_balance, cod_pending_amount, Cashfree PG settlement, commission,
-- and subscription revenue. NOT a legally-verified GST determination -- these are
-- WayDrop-business-configured tax rates pending CA/accounting confirmation.
--
-- See migration 20260726000004_government_tax_due_functions.sql for the RPCs that read/write
-- this schema (kept in a separate migration so the new payment_for_enum value below is never
-- referenced in the same transaction it's added in -- Postgres does not allow using a freshly
-- ALTER TYPE ... ADD VALUE'd enum label within that same transaction).
-- =============================================================================

-- =====================================================================
-- 1. New Cashfree payment purpose for repaying Government Tax Due. Deliberately distinct from
--    'subscription' (activates a commission-free plan) and the fare payment_for values (settle a
--    specific order) -- this one settles the rider's overall tax-due balance, not tied to a
--    single order and never activating anything else.
-- =====================================================================
ALTER TYPE "public"."payment_for_enum" ADD VALUE IF NOT EXISTS 'tax_due';

-- =====================================================================
-- 2. Server-authoritative tax rate configuration, versioned by effective_from so a later rate
--    change never recalculates historical ledger entries (those store their own applied rate).
--    service_category is a WayDrop-defined classification, not a raw orders.order_type value --
--    see apply_order_government_tax() in the next migration for the order_type -> category
--    mapping (deliberately NOT auto-classifying 'intercity_ride': see that function's comment).
-- =====================================================================
CREATE TABLE IF NOT EXISTS "public"."tax_rate_config" (
    "id" "uuid" DEFAULT "gen_random_uuid"() PRIMARY KEY,
    "service_category" "text" NOT NULL,
    "rate_percent" numeric NOT NULL CHECK ("rate_percent" >= 0 AND "rate_percent" <= 100),
    "effective_from" timestamp with time zone DEFAULT "now"() NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);

CREATE INDEX IF NOT EXISTS "idx_tax_rate_config_category_active"
    ON "public"."tax_rate_config" USING "btree" ("service_category", "is_active", "effective_from" DESC);

-- Initial WayDrop business-configured rates (pending CA/accounting confirmation) --
-- 'local_passenger_ride' covers 'ride' and 'ride_sharing' (both local, non-intercity passenger
-- transport products); 'parcel_delivery' covers every parcel/delivery order_type including
-- intercity_parcel (it is a parcel, just travelling intercity). 'intercity_ride' is deliberately
-- NOT seeded here -- see apply_order_government_tax()'s comment on why that classification is
-- unresolved and must not silently default to either rate.
INSERT INTO "public"."tax_rate_config" ("service_category", "rate_percent")
VALUES
    ('local_passenger_ride', 5.0),
    ('parcel_delivery', 18.0)
ON CONFLICT DO NOTHING;

-- =====================================================================
-- 3. Server-authoritative blocking threshold configuration. Single-active-row pattern, same
--    posture as dispatch_config.
-- =====================================================================
CREATE TABLE IF NOT EXISTS "public"."government_tax_config" (
    "id" "uuid" DEFAULT "gen_random_uuid"() PRIMARY KEY,
    "threshold_amount" numeric NOT NULL CHECK ("threshold_amount" > 0),
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);

INSERT INTO "public"."government_tax_config" ("threshold_amount")
SELECT 100.0
WHERE NOT EXISTS (SELECT 1 FROM "public"."government_tax_config");

-- =====================================================================
-- 4. Auditable ledger. Every balance-affecting event is one row here; riders.government_tax_due_
--    balance (added below) is a cache derived from -- and kept in lockstep with, in the same
--    function call -- this ledger, never written to independently.
--
--    entry_type:
--      ORDER_TAX          -- a completed order's tax liability (+amount, increases balance)
--      ORDER_TAX_WITHHELD -- offsets an ORDER_TAX entry when the fare was Cashfree-collected and
--                            the tax was withheld from the rider's wallet credit instead of left
--                            outstanding (-amount, same magnitude as its ORDER_TAX pair -- net
--                            effect on balance is zero, but both rows exist for auditability: "tax
--                            was created, and how it was recovered").
--      TAX_PAYMENT        -- a confirmed Cashfree payment against the balance (-amount)
--      ADJUSTMENT         -- reserved for a future manual/admin correction path (not written by
--                            any function in this feature; included now so the CHECK constraint
--                            never needs a migration later for it)
-- =====================================================================
CREATE TABLE IF NOT EXISTS "public"."government_tax_ledger" (
    "id" "uuid" DEFAULT "gen_random_uuid"() PRIMARY KEY,
    "rider_id" "uuid" NOT NULL REFERENCES "public"."riders"("id") ON DELETE CASCADE,
    "order_id" "uuid" REFERENCES "public"."orders"("id") ON DELETE SET NULL,
    "payment_id" "uuid" REFERENCES "public"."payments"("id") ON DELETE SET NULL,
    "entry_type" "text" NOT NULL CHECK ("entry_type" IN ('ORDER_TAX', 'ORDER_TAX_WITHHELD', 'TAX_PAYMENT', 'ADJUSTMENT')),
    "service_category" "text",
    "taxable_base" numeric,
    "rate_percent" numeric,
    -- Signed: ORDER_TAX is positive (increases what's owed), ORDER_TAX_WITHHELD/TAX_PAYMENT are
    -- negative (reduce what's owed). Balance = SUM(amount) over a rider's entries.
    "amount" numeric NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);

CREATE INDEX IF NOT EXISTS "idx_government_tax_ledger_rider_id"
    ON "public"."government_tax_ledger" USING "btree" ("rider_id", "created_at" DESC);

-- Exactly one ORDER_TAX (and, independently, at most one ORDER_TAX_WITHHELD) entry per order --
-- the DB-level guarantee that duplicate completion requests/webhook deliveries/realtime replays
-- can never double-create a liability, regardless of any application-level idempotency check.
CREATE UNIQUE INDEX IF NOT EXISTS "idx_gov_tax_ledger_one_order_tax_per_order"
    ON "public"."government_tax_ledger" ("order_id")
    WHERE "entry_type" = 'ORDER_TAX';

CREATE UNIQUE INDEX IF NOT EXISTS "idx_gov_tax_ledger_one_withheld_per_order"
    ON "public"."government_tax_ledger" ("order_id")
    WHERE "entry_type" = 'ORDER_TAX_WITHHELD';

-- Exactly one TAX_PAYMENT ledger entry per Cashfree payment -- the DB-level guarantee that a
-- duplicate webhook delivery, or a webhook/verify-payment race on the same payment row, can never
-- apply the same payment's credit twice.
CREATE UNIQUE INDEX IF NOT EXISTS "idx_gov_tax_ledger_one_payment_per_payment_id"
    ON "public"."government_tax_ledger" ("payment_id")
    WHERE "entry_type" = 'TAX_PAYMENT';

-- =====================================================================
-- 5. Cached balance on riders -- performance only. Always written transactionally alongside the
--    ledger row that changes it (see apply_order_government_tax()/apply_government_tax_payment()
--    in the next migration), as an atomic `column = column + delta` update -- never a
--    read-modify-write -- so it cannot drift from SUM(government_tax_ledger.amount) even under
--    concurrent order completions/payments for the same rider.
-- =====================================================================
ALTER TABLE "public"."riders"
    ADD COLUMN IF NOT EXISTS "government_tax_due_balance" numeric NOT NULL DEFAULT 0;

CREATE INDEX IF NOT EXISTS "idx_riders_government_tax_due_balance"
    ON "public"."riders" USING "btree" ("government_tax_due_balance");

-- =====================================================================
-- 6. RLS. Riders may read their own ledger/config; nothing here is ever writable by an
--    'authenticated' role -- every mutation goes through a SECURITY DEFINER function (next
--    migration) executed by the service-role Edge Functions, exactly like the rest of this
--    project's financial tables (payments, wallet-affecting columns on riders, etc.).
-- =====================================================================
ALTER TABLE "public"."tax_rate_config" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."government_tax_config" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."government_tax_ledger" ENABLE ROW LEVEL SECURITY;

-- Any authenticated user may read the active rate/threshold configuration (needed so the Flutter
-- client can show e.g. "5%" without embedding it) -- these rows carry no personal/financial data
-- of any individual rider, only the business-wide configured rates/threshold.
DROP POLICY IF EXISTS "tax_rate_config_read_authenticated" ON "public"."tax_rate_config";
CREATE POLICY "tax_rate_config_read_authenticated" ON "public"."tax_rate_config"
    FOR SELECT TO "authenticated" USING (true);

DROP POLICY IF EXISTS "government_tax_config_read_authenticated" ON "public"."government_tax_config";
CREATE POLICY "government_tax_config_read_authenticated" ON "public"."government_tax_config"
    FOR SELECT TO "authenticated" USING (true);

-- A rider may read only their own ledger rows -- never another rider's, and never a passenger
-- (passengers have no riders-table row to match against here at all).
DROP POLICY IF EXISTS "government_tax_ledger_read_own" ON "public"."government_tax_ledger";
CREATE POLICY "government_tax_ledger_read_own" ON "public"."government_tax_ledger"
    FOR SELECT TO "authenticated"
    USING (
        EXISTS (
            SELECT 1 FROM "public"."riders" r
            WHERE r."id" = "government_tax_ledger"."rider_id"
              AND r."user_id" = auth.uid()
        )
    );

-- No INSERT/UPDATE/DELETE policies for 'authenticated' on any of these three tables -- with RLS
-- enabled and no policy for those commands, every such attempt from a client is rejected outright.
-- Only service_role (which bypasses RLS entirely) can write, and only ever does so via the
-- SECURITY DEFINER functions in the next migration.

GRANT SELECT ON "public"."tax_rate_config" TO "authenticated";
GRANT SELECT ON "public"."government_tax_config" TO "authenticated";
GRANT SELECT ON "public"."government_tax_ledger" TO "authenticated";
GRANT ALL ON "public"."tax_rate_config" TO "service_role";
GRANT ALL ON "public"."government_tax_config" TO "service_role";
GRANT ALL ON "public"."government_tax_ledger" TO "service_role";
