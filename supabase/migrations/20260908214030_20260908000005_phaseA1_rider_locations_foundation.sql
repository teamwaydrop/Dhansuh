-- =============================================================================
-- PHASE A — STAGE A1: rider_locations foundation (ADDITIVE, reversible)
--
-- Ref: docs/PERF_phaseA_rider_locations_readonly_audit.md
--
-- WHAT A1 DOES (and ONLY this):
--   1. Creates public.rider_locations — a one-row-per-rider high-frequency GPS
--      table (rider_id PK, FK -> riders.id ON DELETE CASCADE).
--   2. REPLICA IDENTITY DEFAULT (NOT FULL — the future realtime reader
--      consumes payload.newRecord only; FULL would re-inflate WAL/decode cost).
--   3. RLS: deny-by-default + ONE SELECT policy backed by a STABLE SECURITY
--      DEFINER predicate can_read_rider_location() (Option D from the audit):
--        - a rider may read their own location row; OR
--        - an authenticated passenger may read a rider's location row ONLY while
--          they have an ACTIVE order assigned to that rider.
--      A random authenticated user CANNOT read arbitrary rider coordinates.
--   4. Adds public.rider_locations to the supabase_realtime publication
--      (guarded, same convention as 20260530000002_enable_realtime.sql).
--   5. Backfills one row per existing rider from riders.current_*.
--   6. Adds a lightweight DB bridge trigger riders -> rider_locations so the
--      new table stays fresh for EVERY rider (any app version) during the
--      rollout, WITHOUT changing the current Flutter writer (that is Stage A3).
--
-- WHAT A1 DOES NOT DO (explicit compatibility guarantees):
--   * Does NOT alter/drop riders.current_lat / current_lng / current_heading /
--     last_location_updated_at / last_active_at (they remain the mirror).
--   * Does NOT change riders' REPLICA IDENTITY (stays FULL).
--   * Does NOT change the Flutter GPS writer (location_cache_service.dart keeps
--     writing riders).
--   * Does NOT change dispatch / find_nearby_riders / nearby-search — they keep
--     reading riders.
--   * Does NOT change get-live-order-status, the near-destination trigger,
--     go-online / go-offline, dormancy (check_dormant_riders), or
--     riders.updated_at behaviour.
--   * Does NOT change fare / payment / wallet / tax / completion logic.
--   * Does NOT touch existing triggers, functions, cron jobs, or RLS policies
--     on any existing table.
--
-- The ONLY new runtime behaviour after A1: a riders location UPDATE also
-- performs one simple upsert into rider_locations (via the bridge trigger).
--
-- ROLLBACK: see the commented block at the end of this file.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. TABLE  (types match the existing public.riders columns exactly:
--    current_lat / current_lng / current_heading = double precision, nullable;
--    last_location_updated_at / last_active_at    = timestamptz,      nullable;
--    created_at / updated_at                      = timestamptz DEFAULT now(),
--                                                   nullable — mirrors riders.)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.rider_locations (
    rider_id                 uuid PRIMARY KEY
                             REFERENCES public.riders(id) ON DELETE CASCADE,
    current_lat              double precision,
    current_lng              double precision,
    current_heading          double precision,
    last_location_updated_at timestamptz,
    last_active_at            timestamptz,
    created_at               timestamptz DEFAULT now(),
    updated_at               timestamptz DEFAULT now()
);

COMMENT ON TABLE public.rider_locations IS
    'Phase A: one row per rider, high-frequency GPS. riders.current_lat/lng '
    'remain as a low-frequency compatibility mirror. Populated in A1 by the '
    'bridge trigger trg_riders_gps_bridge_to_rider_locations; the Flutter '
    'writer moves here in A3. REPLICA IDENTITY DEFAULT on purpose.';

-- -----------------------------------------------------------------------------
-- 2. REPLICA IDENTITY — DEFAULT (explicit; it is also the CREATE-TABLE default).
--    The single future realtime consumer (realtime_order_controller
--    ._subscribeRider) reads payload.newRecord only, never payload.oldRecord,
--    so PK-only old-tuple identity is sufficient and keeps the WAL/decode
--    payload minimal for the high-frequency stream.
-- -----------------------------------------------------------------------------
ALTER TABLE public.rider_locations REPLICA IDENTITY DEFAULT;

-- -----------------------------------------------------------------------------
-- 3. INDEXES
--    NONE beyond the rider_id primary key.
--    Justification (A1/A2/A3 access patterns only):
--      * bridge trigger  : upsert  WHERE rider_id = ?   -> PK
--      * A2 get-live-order-status : SELECT WHERE rider_id = order.rider_id -> PK
--      * A3 realtime subscribe    : filter rider_id = <id>                -> PK
--      * RLS EXISTS(orders ...)   : driven by orders(rider_id) index
--                                   (idx_orders_rider_id already exists),
--                                   NOT by a rider_locations index.
--    A last_location_updated_at index only becomes relevant if dispatch/
--    nearby-search is later repointed at this table (Stage A6) — deliberately
--    NOT added speculatively here.
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- 4. RLS  (Option D — deny-by-default; ONE SELECT policy backed by a
--    SECURITY DEFINER predicate; no client write path)
--
--    - authenticated is granted SELECT ONLY (needed so the RLS SELECT policy
--      below is even reachable -- Postgres checks the table GRANT before RLS).
--      It is NOT granted INSERT/UPDATE/DELETE, and there is no write policy, so
--      clients can never write rider_locations (write path is Stage A3).
--      service_role is granted ALL (A2 get-live-order-status reads it directly;
--      this project's convention for RLS-protected tables, e.g.
--      20260902000000_waydrop_rewards_system.sql). Writes in A1 happen only via
--      the SECURITY DEFINER bridge trigger (section 7, runs as the table owner
--      -> RLS-exempt).
--
--    - The read predicate is wrapped in a STABLE SECURITY DEFINER function so
--      the per-row check is ONE bounded indexed probe (idx_orders_rider_id /
--      riders_pkey) instead of re-evaluating the 6 permissive SELECT policies
--      on public.orders + the 4 on public.riders inside the RLS expression on
--      every realtime GPS event. It leaks nothing: it only tells the CALLER
--      whether THEY themselves own/are-tracking that rider — a fact the caller
--      can already derive from their own visible rider/order rows.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.can_read_rider_location(p_rider_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
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
$function$;

-- Callable only by the authenticated role (the policy runs as the querying
-- user). anon never reaches it (the policy is TO authenticated). service_role
-- bypasses RLS entirely and never needs it.
REVOKE ALL ON FUNCTION public.can_read_rider_location(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.can_read_rider_location(uuid) TO authenticated;

ALTER TABLE public.rider_locations ENABLE ROW LEVEL SECURITY;
-- (No FORCE ROW LEVEL SECURITY: the owner / SECURITY DEFINER bridge must bypass.)

GRANT SELECT ON public.rider_locations TO authenticated;
GRANT ALL ON public.rider_locations TO service_role;

DROP POLICY IF EXISTS "Allow owner rider or active-order passenger to view rider location" ON public.rider_locations;
CREATE POLICY "Allow owner rider or active-order passenger to view rider location"
    ON public.rider_locations
    FOR SELECT
    TO authenticated
    USING ( public.can_read_rider_location(rider_locations.rider_id) );

-- -----------------------------------------------------------------------------
-- 5. REALTIME PUBLICATION — add public.rider_locations, only if not already a
--    member. Same guarded pattern as 20260530000002_enable_realtime.sql, but
--    this migration NEVER touches the other 20 published tables and NEVER
--    changes any table's REPLICA IDENTITY except setting rider_locations to
--    DEFAULT (done in section 2).
-- -----------------------------------------------------------------------------
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime') THEN
        IF NOT EXISTS (
            SELECT 1 FROM pg_publication_tables
            WHERE pubname = 'supabase_realtime'
              AND schemaname = 'public'
              AND tablename  = 'rider_locations'
        ) THEN
            ALTER PUBLICATION supabase_realtime ADD TABLE public.rider_locations;
        END IF;
    END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 6. BACKFILL — one row per existing rider, copying the current mirror values
--    verbatim (NULL coordinates included: a rider with no GPS fix yet is still
--    a valid dispatch candidate under find_nearby_riders' `IS NULL` branch, and
--    a stable "row always exists" invariant simplifies the A2 fallback logic).
--    Idempotent: ON CONFLICT DO NOTHING.
-- -----------------------------------------------------------------------------
INSERT INTO public.rider_locations
    (rider_id, current_lat, current_lng, current_heading,
     last_location_updated_at, last_active_at, created_at, updated_at)
SELECT
    r.id, r.current_lat, r.current_lng, r.current_heading,
    r.last_location_updated_at, r.last_active_at, now(), now()
FROM public.riders r
ON CONFLICT (rider_id) DO NOTHING;

-- -----------------------------------------------------------------------------
-- 7. BRIDGE  riders -> rider_locations   (rollout coverage; removed in A6)
--
--    Fires ONLY when an UPDATE names current_lat / current_lng in its SET list
--    (so a plain account_status / wallet / profile update never triggers it),
--    and the WHEN clause skips the upsert entirely if no mirrored location
--    value actually changed.
--
--    The function does ONE upsert into rider_locations and NOTHING else:
--    no UPDATE of riders (=> no recursion), no SELECT, no loop, no network /
--    HTTP / vault access. rider_locations has no triggers in A1, so a bridge
--    upsert cannot re-fire anything.
--
--    SECURITY DEFINER is REQUIRED: the trigger runs in the rider's own
--    (authenticated) transaction, which is granted only SELECT on
--    rider_locations (no INSERT/UPDATE) and, with no write policy, is blocked by
--    RLS anyway. Running as the owner (migration role) bypasses both. search_path
--    pinned, all objects schema-qualified. It is a trigger function
--    (RETURNS trigger) so it is not directly callable and PostgREST does not
--    expose it.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.sync_riders_gps_to_rider_locations()
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
$function$;

DROP TRIGGER IF EXISTS trg_riders_gps_bridge_to_rider_locations ON public.riders;
CREATE TRIGGER trg_riders_gps_bridge_to_rider_locations
AFTER UPDATE OF current_lat, current_lng ON public.riders
FOR EACH ROW
WHEN (
        OLD.current_lat              IS DISTINCT FROM NEW.current_lat
     OR OLD.current_lng              IS DISTINCT FROM NEW.current_lng
     OR OLD.current_heading          IS DISTINCT FROM NEW.current_heading
     OR OLD.last_location_updated_at IS DISTINCT FROM NEW.last_location_updated_at
     OR OLD.last_active_at           IS DISTINCT FROM NEW.last_active_at
)
EXECUTE FUNCTION public.sync_riders_gps_to_rider_locations();


-- =============================================================================
-- ROLLBACK (run manually if needed — removes ONLY A1 objects; touches no
--           existing column, trigger, function, policy, or cron job):
--
--   DROP TRIGGER IF EXISTS trg_riders_gps_bridge_to_rider_locations ON public.riders;
--   DROP FUNCTION IF EXISTS public.sync_riders_gps_to_rider_locations();
--
--   DO $$
--   BEGIN
--     IF EXISTS (
--       SELECT 1 FROM pg_publication_tables
--       WHERE pubname='supabase_realtime' AND schemaname='public' AND tablename='rider_locations'
--     ) THEN
--       ALTER PUBLICATION supabase_realtime DROP TABLE public.rider_locations;
--     END IF;
--   END $$;
--
--   DROP POLICY IF EXISTS "Allow owner rider or active-order passenger to view rider location" ON public.rider_locations;
--
--   DROP TABLE IF EXISTS public.rider_locations;   -- also drops its PK + FK + RLS
--
--   DROP FUNCTION IF EXISTS public.can_read_rider_location(uuid);   -- after the policy that uses it
--
-- (Order: bridge trigger before its function; publication membership before the
--  table; the policy before the RLS predicate function (DROP TABLE cascades the
--  policy, but the predicate function must be dropped after the policy no longer
--  references it). riders and every existing object are left exactly as they were.)
-- =============================================================================
