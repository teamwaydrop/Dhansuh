-- =====================================================================
-- PHASE 1: Production control system -- app version control, maintenance
-- mode, and remote feature flags.
-- =====================================================================
-- AUDIT SUMMARY (see conversation report for the full read-only audit):
-- A `public.feature_flags` table existed once (20260616000005_feature_flags.sql)
-- but was deliberately dropped (20260702000000_drop_feature_flags.sql,
-- "remote feature flags are no longer used") and its Flutter counterpart
-- (lib/core/services/session/feature_flag_service.dart) is dead code today --
-- init() never fetches, fetchFlags() is a no-op, and isEnabled() is called
-- from nowhere in lib/. There is no existing app-version-check, maintenance-
-- mode, or remote-config mechanism anywhere else in the codebase (confirmed
-- by a full repo search). This migration does not resurrect the old table --
-- it is a new, minimal, single-table design scoped to Phase 1.
--
-- This table is exclusively for OPERATIONAL controls (version gate,
-- maintenance switch, feature kill switches). It must never duplicate or
-- replace subscription_plans (pricing stays there -- see migration 33,
-- 20260901000033_vehicle_specific_subscription_pricing.sql) and must never
-- store secrets (Cashfree keys, service-role keys, etc. remain Edge Function
-- secrets only).
--
-- SHAPE: mirrors the existing dispatch_config/pricing_config convention
-- (config_code UNIQUE + is_active boolean, service_role-only writes) rather
-- than inventing a new pattern. Named boolean columns are used for the 7
-- Phase-1-required flags (typed, discoverable, indexable) plus one jsonb
-- escape hatch (extra_flags) so a future simple on/off value can be added
-- without a new migration -- exactly as requested. A flag/value that needs
-- real structure, an FK, or an index should still get a real migration and
-- column, same as everywhere else in this schema.
-- =====================================================================

CREATE TABLE IF NOT EXISTS public.production_config (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    config_code text NOT NULL UNIQUE DEFAULT 'default',
    is_active boolean NOT NULL DEFAULT true,

    -- ---------------------------------------------------------------
    -- APP VERSION CONTROL
    -- ---------------------------------------------------------------
    -- Compared against PackageInfo.fromPlatform().version (the pubspec
    -- "version" -- e.g. "1.0.0", NOT the build number) by
    -- ProductionConfigService on the Flutter side. Seeded to the current
    -- shipped version (see pubspec.yaml `version: 1.0.0+51`) so applying
    -- this migration changes zero current user-facing behavior -- nobody is
    -- blocked and no update banner appears until an admin deliberately
    -- raises these values later.
    minimum_android_version text NOT NULL DEFAULT '1.0.0',
    latest_android_version text NOT NULL DEFAULT '1.0.0',
    force_update boolean NOT NULL DEFAULT false,
    update_message text NOT NULL DEFAULT 'A new version of WayDrop is available. Please update to continue.',

    -- ---------------------------------------------------------------
    -- MAINTENANCE MODE
    -- ---------------------------------------------------------------
    maintenance_mode boolean NOT NULL DEFAULT false,
    maintenance_message text NOT NULL DEFAULT 'WayDrop is currently undergoing scheduled maintenance. Please check back shortly.',

    -- ---------------------------------------------------------------
    -- REMOTE FEATURE FLAGS (Phase 1 set). Every default is `true` --
    -- deploying this migration must not disable anything that currently
    -- works. Enforced both client-side (FeatureFlags, UI-level) and, for the
    -- critical write operations, server-side (see create-order,
    -- create-payment, send-push-notification -- audited as the safest
    -- central enforcement points; full detail in the conversation report).
    -- ---------------------------------------------------------------
    local_rides_enabled boolean NOT NULL DEFAULT true,
    ride_booking_enabled boolean NOT NULL DEFAULT true,
    intercity_enabled boolean NOT NULL DEFAULT true,
    parcel_enabled boolean NOT NULL DEFAULT true,
    payments_enabled boolean NOT NULL DEFAULT true,
    subscriptions_enabled boolean NOT NULL DEFAULT true,
    notifications_enabled boolean NOT NULL DEFAULT true,

    -- Escape hatch for a future simple boolean/string/number config value
    -- that does not warrant its own migration + column yet. Never used for
    -- anything requiring FK integrity, an index, or NOT NULL/type
    -- enforcement -- those still get a real column via a real migration.
    extra_flags jsonb NOT NULL DEFAULT '{}'::jsonb,

    updated_by_admin_id uuid REFERENCES public.admins(id) ON DELETE SET NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

-- At most one active config row at a time -- the client always reads
-- `.eq('is_active', true)`. Mirrors migration 33's
-- uq_subscription_plans_active_vehicle_type pattern. Multiple inactive rows
-- (e.g. a historical/superseded config) remain allowed, matching
-- dispatch_config/pricing_config's own versioned-row convention.
CREATE UNIQUE INDEX IF NOT EXISTS uq_production_config_active
    ON public.production_config (is_active)
    WHERE (is_active);

INSERT INTO public.production_config (config_code)
VALUES ('default')
ON CONFLICT (config_code) DO NOTHING;

-- Reuses the existing generic updated_at trigger function (introduced in
-- 20260530000001_rider_withdrawals.sql), not a new one.
DROP TRIGGER IF EXISTS set_updated_at ON public.production_config;
CREATE TRIGGER set_updated_at
BEFORE UPDATE ON public.production_config
FOR EACH ROW
EXECUTE FUNCTION public.update_updated_at_column();

-- ---------------------------------------------------------------
-- RLS: read-only for ordinary clients, no write path for anyone but
-- service_role. Mirrors migration 33's subscription_plans policy exactly.
-- `anon` is included (not just `authenticated`) because maintenance_mode/
-- force_update must be checkable by AppStartScreen before a user is even
-- logged in -- an unauthenticated client is Supabase's `anon` role.
-- ---------------------------------------------------------------
ALTER TABLE public.production_config ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Anyone can view active production config"
    ON public.production_config
    FOR SELECT
    TO anon, authenticated
    USING (is_active = true);

-- No INSERT/UPDATE/DELETE policy is created for anon/authenticated -- with
-- RLS enabled, the absence of a policy is a default-deny, so normal users
-- can never modify this table via the client (PostgREST). service_role
-- bypasses RLS entirely (used by any future admin tooling/Edge Function),
-- which is the only intended write path in Phase 1 -- there is no Flutter
-- admin UI for this table yet (see report Part 6/20 for the documented
-- follow-up).
GRANT SELECT ON public.production_config TO anon, authenticated;
GRANT ALL ON public.production_config TO service_role;
