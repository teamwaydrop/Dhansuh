-- =====================================================================================
-- PHASE 14: WayDrop Rewards / Coupons system.
--
-- Every N completed rides (configurable, independently per passenger/rider) unlocks a
-- time-limited "reward cycle" that grants the owner read access to a merchant-offers
-- catalog (Restaurants, Shopping Malls, future categories). Cycles recur indefinitely --
-- ride counting never pauses while a cycle is active.
--
-- AUDIT SUMMARY (full read-only audit done before this migration, see conversation):
-- - No coupons/rewards/offers/merchants table existed anywhere in this schema. A
--   `promo_codes` table exists but is an unrelated fare discount-code system -- not
--   touched, not reused.
-- - Authoritative "completed ride" = orders.order_status IN ('completed','delivered').
--   That transition is already made exactly once per order by
--   complete_order_and_settle()'s compare-and-swap UPDATE (see
--   20260813000000_atomic_order_completion_settlement.sql and its successors) --
--   cancelled/expired/payment_pending orders are never counted.
-- - riders.total_completed_orders exists but is incremented inside
--   credit_rider_for_completed_order(), which runs from a nested call inside the same
--   transaction as the orders UPDATE -- reading it from a trigger fired by that same
--   UPDATE would race the increment. Sidestepped entirely by counting directly from
--   `orders` (qualifying_completed_ride_count below), which is self-consistent
--   regardless of that ordering and works identically for the user side (which has no
--   counter column of any kind).
-- - Reward-cycle creation is hooked as an INDEPENDENT trigger on orders (does not touch
--   on_order_status_update()/send_order_status_notifications_core() from
--   20260810000000_async_order_status_notifications.sql), following that same
--   migration's proven "thin trigger body wrapped in BEGIN...EXCEPTION WHEN OTHERS THEN
--   RAISE WARNING...END, RETURN NEW unconditional" shape so a reward-cycle failure can
--   never block ride completion, payment, or settlement.
-- - RLS/grant idiom copied from government_tax_ledger
--   (20260726000003_government_tax_due_schema.sql): SELECT-only policy scoped by an
--   auth.uid() ownership EXISTS join, GRANT SELECT TO authenticated, GRANT ALL TO
--   service_role, no write policy for anon/authenticated at all (default-deny; all
--   writes go through SECURITY DEFINER functions owned by the migration role).
-- - Per prior audit finding B8 (privileged SECURITY DEFINER functions left
--   PUBLIC-executable via PostgREST), every SECURITY DEFINER function below explicitly
--   REVOKEs EXECUTE FROM PUBLIC and grants only what's actually needed.
-- - Synthetic demo offers (Restaurant/123456789, Shopping Mall/abcdefgh) are NOT
--   inserted here -- they live in supabase/seed.sql, which `[db.seed]` in config.toml
--   only applies on a local `supabase db reset`, never on `supabase db push` to a
--   linked project. Production is never auto-seeded with demo merchant data.
-- =====================================================================================

-- =====================================================================================
-- 1. reward_config -- single active row of admin-configurable thresholds, mirroring the
--    production_config / subscription_plans convention exactly (config_code UNIQUE +
--    is_active boolean, service_role-only writes, admin edits via Supabase Studio --
--    there is no in-app Flutter admin CRUD anywhere in this codebase today, confirmed by
--    audit, so this migration does not invent one).
-- =====================================================================================
CREATE TABLE IF NOT EXISTS public.reward_config (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    config_code text NOT NULL UNIQUE DEFAULT 'default',
    is_active boolean NOT NULL DEFAULT true,

    -- PASSENGER (user) rewards
    user_rewards_enabled boolean NOT NULL DEFAULT true,
    user_required_rides integer NOT NULL DEFAULT 3 CHECK (user_required_rides > 0),
    user_offer_validity_days integer NOT NULL DEFAULT 7 CHECK (user_offer_validity_days > 0),
    user_default_discount_type text NOT NULL DEFAULT 'percentage'
        CHECK (user_default_discount_type IN ('percentage', 'flat')),
    user_default_discount_value numeric NOT NULL DEFAULT 10 CHECK (user_default_discount_value > 0),

    -- RIDER (partner) rewards
    partner_rewards_enabled boolean NOT NULL DEFAULT true,
    partner_required_rides integer NOT NULL DEFAULT 10 CHECK (partner_required_rides > 0),
    partner_offer_validity_days integer NOT NULL DEFAULT 3 CHECK (partner_offer_validity_days > 0),
    partner_default_discount_type text NOT NULL DEFAULT 'percentage'
        CHECK (partner_default_discount_type IN ('percentage', 'flat')),
    partner_default_discount_value numeric NOT NULL DEFAULT 10 CHECK (partner_default_discount_value > 0),

    updated_by_admin_id uuid REFERENCES public.admins(id) ON DELETE SET NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_reward_config_active
    ON public.reward_config (is_active)
    WHERE (is_active);

INSERT INTO public.reward_config (config_code)
VALUES ('default')
ON CONFLICT (config_code) DO NOTHING;

DROP TRIGGER IF EXISTS set_updated_at ON public.reward_config;
CREATE TRIGGER set_updated_at
BEFORE UPDATE ON public.reward_config
FOR EACH ROW
EXECUTE FUNCTION public.update_updated_at_column();

ALTER TABLE public.reward_config ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Anyone can view active reward config"
    ON public.reward_config
    FOR SELECT
    TO authenticated
    USING (is_active = true);

GRANT SELECT ON public.reward_config TO authenticated;
GRANT ALL ON public.reward_config TO service_role;


-- =====================================================================================
-- 2. reward_cycles -- one row per unlocked reward cycle. owner_type/owner_id is a
--    polymorphic reference (users.id for 'user', riders.id for 'rider') rather than two
--    nullable FK columns, since a cycle belongs to exactly one owner and never both --
--    kept as a plain indexed uuid (no FK) because Postgres can't FK one column to two
--    different tables; ownership is enforced entirely by the RLS policy below, not by a
--    foreign key.
--
--    qualifying_rides_threshold/discount_type/discount_value are SNAPSHOTS of
--    reward_config at the moment this cycle unlocked, so a later admin change to the
--    thresholds never retroactively rewrites a cycle that already unlocked. NOTE: for
--    the actual merchant offers a user browses once unlocked, the per-offer
--    discount_type/discount_value on reward_offers is what's ever displayed/authoritative
--    (see section 4) -- this cycle-level discount snapshot is informational only
--    (audit/analytics: "what was the configured default discount when this cycle
--    unlocked"), never read by the offers UI.
-- =====================================================================================
CREATE TABLE IF NOT EXISTS public.reward_cycles (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_type text NOT NULL CHECK (owner_type IN ('user', 'rider')),
    owner_id uuid NOT NULL,
    cycle_number integer NOT NULL CHECK (cycle_number > 0),
    qualifying_rides_threshold integer NOT NULL CHECK (qualifying_rides_threshold > 0),
    discount_type text NOT NULL CHECK (discount_type IN ('percentage', 'flat')),
    discount_value numeric NOT NULL CHECK (discount_value > 0),
    unlocked_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL,
    status text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'expired', 'redeemed')),
    redeemed_at timestamptz,
    redeemed_offer_id uuid,
    created_at timestamptz NOT NULL DEFAULT now(),

    -- The idempotency guard: the same owner can never get the same cycle number twice,
    -- no matter how many times the completion trigger fires/retries for the ride(s)
    -- that crossed the threshold.
    CONSTRAINT uq_reward_cycles_owner_cycle UNIQUE (owner_type, owner_id, cycle_number)
);

CREATE INDEX IF NOT EXISTS idx_reward_cycles_owner
    ON public.reward_cycles (owner_type, owner_id, status);

ALTER TABLE public.reward_cycles ENABLE ROW LEVEL SECURITY;

-- Same shape as government_tax_ledger_read_own (20260726000003): ownership EXISTS join
-- keyed off auth.uid(), no write policy at all for anon/authenticated (default-deny --
-- every write happens inside evaluate_reward_cycle(), a SECURITY DEFINER function owned
-- by the migration role, which bypasses RLS the same way every other privileged writer
-- in this schema does).
CREATE POLICY "reward_cycles_read_own"
    ON public.reward_cycles
    FOR SELECT
    TO authenticated
    USING (
        (owner_type = 'user' AND owner_id = auth.uid())
        OR (
            owner_type = 'rider'
            AND EXISTS (
                SELECT 1 FROM public.riders r
                WHERE r.id = reward_cycles.owner_id
                  AND r.user_id = auth.uid()
            )
        )
    );

GRANT SELECT ON public.reward_cycles TO authenticated;
GRANT ALL ON public.reward_cycles TO service_role;


-- =====================================================================================
-- 3. reward_offer_categories -- lets an admin add "Restaurants" / "Shopping Malls" /
--    any future category purely via a Studio row insert, with zero Flutter changes (the
--    Rewards screen renders its category cards from this table, never a hardcoded list).
--    default_discount_type/value are ONLY a creation-time convenience for a new offer
--    row (see the reward_offers BEFORE INSERT trigger below) -- never read again once an
--    offer has its own configured discount, and never read directly by the display UI.
-- =====================================================================================
CREATE TABLE IF NOT EXISTS public.reward_offer_categories (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code text NOT NULL UNIQUE,
    display_name text NOT NULL,
    sort_order integer NOT NULL DEFAULT 0,
    is_active boolean NOT NULL DEFAULT true,
    default_discount_type text NOT NULL DEFAULT 'percentage'
        CHECK (default_discount_type IN ('percentage', 'flat')),
    default_discount_value numeric CHECK (default_discount_value IS NULL OR default_discount_value > 0),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

DROP TRIGGER IF EXISTS set_updated_at ON public.reward_offer_categories;
CREATE TRIGGER set_updated_at
BEFORE UPDATE ON public.reward_offer_categories
FOR EACH ROW
EXECUTE FUNCTION public.update_updated_at_column();

ALTER TABLE public.reward_offer_categories ENABLE ROW LEVEL SECURITY;

-- Category names/existence are not sensitive on their own (no coupon codes live here),
-- so categories are visible to any authenticated user regardless of unlock state --
-- only the actual offers underneath (section 4) are gated by an active reward cycle.
CREATE POLICY "reward_offer_categories_read_active"
    ON public.reward_offer_categories
    FOR SELECT
    TO authenticated
    USING (is_active = true);

GRANT SELECT ON public.reward_offer_categories TO authenticated;
GRANT ALL ON public.reward_offer_categories TO service_role;

-- Real launch categories (structural taxonomy, not demo data) + one inactive future
-- placeholder an admin can flip on later without any code change.
INSERT INTO public.reward_offer_categories (code, display_name, sort_order, is_active, default_discount_type, default_discount_value)
VALUES
    ('restaurants', 'Restaurants', 1, true, 'percentage', 10),
    ('shopping_malls', 'Shopping Malls', 2, true, 'percentage', 10),
    ('more_offers', 'More Offers', 3, false, 'percentage', NULL)
ON CONFLICT (code) DO NOTHING;


-- =====================================================================================
-- 4. reward_offers -- the merchant/offer catalog. discount_type/discount_value are
--    AUTHORITATIVE per offer row -- never derived from the category at display or
--    redemption time. Two merchants in the same category (or the same merchant twice)
--    can carry entirely different discounts.
--
--    v1 is deliberately display-only (per audit: no existing merchant-validation/QR
--    infra to build real redemption verification on). redemption_instructions is always
--    shown to the user as "use at merchant" copy -- the app never claims to verify
--    in-store usage. reward_cycles.redeemed_at/redeemed_offer_id exist so a future
--    "mark as used"/QR-verified redemption flow can be added without another schema
--    migration, but nothing writes them yet.
-- =====================================================================================
CREATE TABLE IF NOT EXISTS public.reward_offers (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    category_id uuid NOT NULL REFERENCES public.reward_offer_categories(id) ON DELETE RESTRICT,
    merchant_name text NOT NULL,
    title text NOT NULL,
    description text,
    discount_type text NOT NULL CHECK (discount_type IN ('percentage', 'flat')),
    discount_value numeric NOT NULL CHECK (discount_value > 0),
    coupon_code text,
    redemption_instructions text NOT NULL DEFAULT 'Show this offer to the merchant at billing to redeem.',
    terms text,
    valid_from timestamptz,
    valid_until timestamptz,
    image_url text,
    address text,
    phone text,
    is_active boolean NOT NULL DEFAULT true,
    sort_order integer NOT NULL DEFAULT 0,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_reward_offers_category
    ON public.reward_offers (category_id, is_active, sort_order);

DROP TRIGGER IF EXISTS set_updated_at ON public.reward_offers;
CREATE TRIGGER set_updated_at
BEFORE UPDATE ON public.reward_offers
FOR EACH ROW
EXECUTE FUNCTION public.update_updated_at_column();

-- Creation-time-only discount fallback: fills discount_type/discount_value from the
-- category's default ONLY when the new row doesn't specify its own (both are NOT NULL
-- columns, so this only matters for callers/tools that explicitly pass NULL and rely on
-- the category default rather than the column's own lack of a DEFAULT). This trigger is
-- BEFORE INSERT only -- it never fires on UPDATE, so once an offer exists with its own
-- discount, this trigger can never touch it again, and an admin's per-merchant override
-- is permanent.
CREATE OR REPLACE FUNCTION public.fill_reward_offer_discount_default()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public'
AS $function$
DECLARE
    v_default_type text;
    v_default_value numeric;
BEGIN
    IF NEW.discount_type IS NULL OR NEW.discount_value IS NULL THEN
        SELECT default_discount_type, default_discount_value
        INTO v_default_type, v_default_value
        FROM public.reward_offer_categories
        WHERE id = NEW.category_id;

        NEW.discount_type := COALESCE(NEW.discount_type, v_default_type, 'percentage');
        NEW.discount_value := COALESCE(NEW.discount_value, v_default_value);
    END IF;
    RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS fill_discount_default ON public.reward_offers;
CREATE TRIGGER fill_discount_default
BEFORE INSERT ON public.reward_offers
FOR EACH ROW
EXECUTE FUNCTION public.fill_reward_offer_discount_default();

ALTER TABLE public.reward_offers ENABLE ROW LEVEL SECURITY;

-- Per Phase 14 design decision: offers (including coupon codes) are gated by an active,
-- unexpired reward cycle -- a user/rider who has never unlocked a reward cannot read
-- offer rows at all via direct API access, not just via the app's UI navigation.
CREATE POLICY "reward_offers_read_when_unlocked"
    ON public.reward_offers
    FOR SELECT
    TO authenticated
    USING (
        is_active = true
        AND (valid_from IS NULL OR valid_from <= now())
        AND (valid_until IS NULL OR valid_until >= now())
        AND EXISTS (
            SELECT 1 FROM public.reward_cycles rc
            WHERE rc.status = 'active'
              AND rc.expires_at >= now()
              AND (
                  (rc.owner_type = 'user' AND rc.owner_id = auth.uid())
                  OR (
                      rc.owner_type = 'rider'
                      AND EXISTS (
                          SELECT 1 FROM public.riders r
                          WHERE r.id = rc.owner_id
                            AND r.user_id = auth.uid()
                      )
                  )
              )
        )
    );

GRANT SELECT ON public.reward_offers TO authenticated;
GRANT ALL ON public.reward_offers TO service_role;

-- Categories also need SELECT on reward_offer_categories to resolve the FK-joined
-- category display_name, already granted above.


-- =====================================================================================
-- 5. qualifying_completed_ride_count -- the single authoritative count. Always counts
--    directly from `orders`, never from a side-counter, so it's self-consistent
--    regardless of trigger/settlement ordering. Not exposed to PUBLIC -- only called
--    from evaluate_reward_cycle() and get_reward_status() below, both of which resolve
--    owner_id from auth.uid() themselves before calling this, so a client can never pass
--    an arbitrary owner_id even indirectly.
-- =====================================================================================
CREATE OR REPLACE FUNCTION public.qualifying_completed_ride_count(
    p_owner_type text,
    p_owner_id uuid
)
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
    SELECT CASE
        WHEN p_owner_type = 'rider' THEN (
            SELECT count(*)::integer FROM public.orders
            WHERE rider_id = p_owner_id
              AND order_status IN ('completed', 'delivered')
        )
        WHEN p_owner_type = 'user' THEN (
            SELECT count(*)::integer FROM public.orders
            WHERE user_id = p_owner_id
              AND order_status IN ('completed', 'delivered')
        )
        ELSE 0
    END;
$function$;

REVOKE ALL ON FUNCTION public.qualifying_completed_ride_count(text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.qualifying_completed_ride_count(text, uuid) TO service_role;


-- =====================================================================================
-- 6. evaluate_reward_cycle -- computes the current cycle number for one owner and
--    creates the reward_cycles row for it if missing. Called only from the trigger
--    below (never directly by a client -- REVOKEd from PUBLIC). ON CONFLICT DO NOTHING
--    on the (owner_type, owner_id, cycle_number) unique constraint makes this safe
--    against concurrent/retried invocations: whichever call arrives first creates the
--    row, every other call is a no-op.
-- =====================================================================================
CREATE OR REPLACE FUNCTION public.evaluate_reward_cycle(
    p_owner_type text,
    p_owner_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_config record;
    v_enabled boolean;
    v_required_rides integer;
    v_validity_days integer;
    v_discount_type text;
    v_discount_value numeric;
    v_count integer;
    v_cycle_number integer;
BEGIN
    SELECT * INTO v_config FROM public.reward_config WHERE is_active = true LIMIT 1;
    IF NOT FOUND THEN
        RETURN;
    END IF;

    IF p_owner_type = 'user' THEN
        v_enabled := v_config.user_rewards_enabled;
        v_required_rides := v_config.user_required_rides;
        v_validity_days := v_config.user_offer_validity_days;
        v_discount_type := v_config.user_default_discount_type;
        v_discount_value := v_config.user_default_discount_value;
    ELSIF p_owner_type = 'rider' THEN
        v_enabled := v_config.partner_rewards_enabled;
        v_required_rides := v_config.partner_required_rides;
        v_validity_days := v_config.partner_offer_validity_days;
        v_discount_type := v_config.partner_default_discount_type;
        v_discount_value := v_config.partner_default_discount_value;
    ELSE
        RETURN;
    END IF;

    IF NOT v_enabled THEN
        RETURN;
    END IF;

    v_count := public.qualifying_completed_ride_count(p_owner_type, p_owner_id);
    v_cycle_number := v_count / v_required_rides; -- integer division = floor for positive ints

    IF v_cycle_number < 1 THEN
        RETURN;
    END IF;

    INSERT INTO public.reward_cycles (
        owner_type, owner_id, cycle_number, qualifying_rides_threshold,
        discount_type, discount_value, unlocked_at, expires_at, status
    )
    VALUES (
        p_owner_type, p_owner_id, v_cycle_number, v_required_rides,
        v_discount_type, v_discount_value, now(), now() + make_interval(days => v_validity_days), 'active'
    )
    ON CONFLICT (owner_type, owner_id, cycle_number) DO NOTHING;
END;
$function$;

REVOKE ALL ON FUNCTION public.evaluate_reward_cycle(text, uuid) FROM PUBLIC;
-- No GRANT to authenticated/anon/service_role at all: this function is only ever
-- invoked from inside trg_reward_cycle_on_order_completion() below, a same-migration
-- SECURITY DEFINER trigger function owned by the same (postgres) role, which always has
-- implicit EXECUTE on functions it owns -- exactly like every other internal-only
-- helper function in this schema.


-- =====================================================================================
-- 7. Trigger: after an order transitions to completed/delivered, best-effort evaluate a
--    reward cycle for the passenger and (if any) the rider. Independent of, and does not
--    modify, on_order_status_update()/send_order_status_notifications_core() -- this is
--    a second, separate AFTER UPDATE trigger on the same column, exactly as Postgres
--    supports and as this schema already does for other unrelated concerns. Shape
--    (thin body, BEGIN...EXCEPTION WHEN OTHERS THEN RAISE WARNING...END, RETURN NEW
--    unconditional) is copied verbatim from 20260810000000_async_order_status_notifications.sql.
-- =====================================================================================
CREATE OR REPLACE FUNCTION public.trg_reward_cycle_on_order_completion()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
    IF OLD.order_status IS DISTINCT FROM NEW.order_status
       AND NEW.order_status IN ('completed', 'delivered') THEN
        BEGIN
            PERFORM public.evaluate_reward_cycle('user', NEW.user_id);
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING 'trg_reward_cycle_on_order_completion: passenger reward evaluation failed for order %: %', NEW.id, SQLERRM;
        END;

        IF NEW.rider_id IS NOT NULL THEN
            BEGIN
                PERFORM public.evaluate_reward_cycle('rider', NEW.rider_id);
            EXCEPTION WHEN OTHERS THEN
                RAISE WARNING 'trg_reward_cycle_on_order_completion: rider reward evaluation failed for order %: %', NEW.id, SQLERRM;
            END;
        END IF;
    END IF;

    RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_reward_cycle_after_completion ON public.orders;
CREATE TRIGGER trg_reward_cycle_after_completion
AFTER UPDATE OF order_status ON public.orders
FOR EACH ROW
EXECUTE FUNCTION public.trg_reward_cycle_on_order_completion();


-- =====================================================================================
-- 8. get_reward_status -- the single read RPC the Flutter client calls. Resolves
--    owner_id from auth.uid() itself (never accepts a client-supplied owner_id), so a
--    client can only ever ask about their own progress. SECURITY DEFINER because the
--    'rider' branch needs to read reward_cycles for a riders.id that isn't auth.uid()
--    itself; still self-authorizing throughout (every lookup is keyed off auth.uid(),
--    matching the B8-remediation idiom).
-- =====================================================================================
CREATE OR REPLACE FUNCTION public.get_reward_status(p_owner_type text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_config record;
    v_owner_id uuid;
    v_enabled boolean;
    v_required_rides integer;
    v_validity_days integer;
    v_discount_type text;
    v_discount_value numeric;
    v_count integer;
    v_cycle_number integer;
    v_progress integer;
    v_active_cycles jsonb;
    v_active_count integer;
BEGIN
    IF p_owner_type NOT IN ('user', 'rider') THEN
        RETURN jsonb_build_object('enabled', false);
    END IF;

    IF p_owner_type = 'user' THEN
        v_owner_id := auth.uid();
    ELSE
        SELECT id INTO v_owner_id FROM public.riders WHERE user_id = auth.uid() LIMIT 1;
    END IF;

    IF v_owner_id IS NULL THEN
        RETURN jsonb_build_object('enabled', false);
    END IF;

    SELECT * INTO v_config FROM public.reward_config WHERE is_active = true LIMIT 1;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('enabled', false);
    END IF;

    IF p_owner_type = 'user' THEN
        v_enabled := v_config.user_rewards_enabled;
        v_required_rides := v_config.user_required_rides;
        v_validity_days := v_config.user_offer_validity_days;
        v_discount_type := v_config.user_default_discount_type;
        v_discount_value := v_config.user_default_discount_value;
    ELSE
        v_enabled := v_config.partner_rewards_enabled;
        v_required_rides := v_config.partner_required_rides;
        v_validity_days := v_config.partner_offer_validity_days;
        v_discount_type := v_config.partner_default_discount_type;
        v_discount_value := v_config.partner_default_discount_value;
    END IF;

    IF NOT v_enabled THEN
        RETURN jsonb_build_object('enabled', false);
    END IF;

    v_count := public.qualifying_completed_ride_count(p_owner_type, v_owner_id);
    v_cycle_number := v_count / v_required_rides;
    v_progress := v_count % v_required_rides;

    SELECT
        coalesce(jsonb_agg(jsonb_build_object(
            'cycle_number', rc.cycle_number,
            'unlocked_at', rc.unlocked_at,
            'expires_at', rc.expires_at,
            'days_remaining', greatest(0, ceil(extract(epoch FROM (rc.expires_at - now())) / 86400.0))
        ) ORDER BY rc.cycle_number DESC), '[]'::jsonb),
        count(*)::integer
    INTO v_active_cycles, v_active_count
    FROM public.reward_cycles rc
    WHERE rc.owner_type = p_owner_type
      AND rc.owner_id = v_owner_id
      AND rc.status = 'active'
      AND rc.expires_at >= now();

    RETURN jsonb_build_object(
        'enabled', true,
        'required_rides', v_required_rides,
        'offer_validity_days', v_validity_days,
        'default_discount_type', v_discount_type,
        'default_discount_value', v_discount_value,
        'qualifying_ride_count', v_count,
        'current_cycle_number', v_cycle_number,
        'progress_within_cycle', v_progress,
        'rides_remaining', CASE WHEN v_progress = 0 THEN 0 ELSE v_required_rides - v_progress END,
        'active_cycle_count', v_active_count,
        'active_cycles', v_active_cycles
    );
END;
$function$;

REVOKE ALL ON FUNCTION public.get_reward_status(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_reward_status(text) TO authenticated;
