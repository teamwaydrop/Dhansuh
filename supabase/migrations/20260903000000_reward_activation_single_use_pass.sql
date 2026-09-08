-- =====================================================================================
-- PHASE 14 (cont.): reward-cycle activation, 5-minute pass, single-use-per-cycle rule.
--
-- Extends the existing reward_cycles table (unlocked_at/expires_at/status/redeemed_at/
-- redeemed_offer_id already existed as unused-for-now columns from the original
-- migration, added specifically for this) rather than introducing a separate
-- redemptions table -- reward_cycles already models exactly one row per cycle with a
-- 'redeemed' status, which is the correct place for "has this cycle been consumed."
--
-- Activation atomicity: activate_reward_offer() does a single
-- `UPDATE ... WHERE id=? AND status='active' AND expires_at>=now()` compare-and-swap,
-- the same idiom already used by complete_order_and_settle() elsewhere in this schema.
-- Postgres row-level locking serializes concurrent UPDATEs on the same row, so two
-- simultaneous activation attempts for the same cycle can never both succeed -- no
-- advisory lock needed (matches this codebase's established idiom, per the original
-- Phase 14 audit: no pg_advisory_xact_lock usage anywhere in this repo).
--
-- reward_offers.discount_type/discount_value stay the sole authoritative discount
-- source (unchanged) -- activate_reward_offer reads them fresh from the offer row at
-- activation time, never from reward_config's default.
-- =====================================================================================

-- 1. reward_cycles: two new nullable columns for the live activation/pass state.
ALTER TABLE public.reward_cycles
    ADD COLUMN IF NOT EXISTS activation_expires_at timestamptz,
    ADD COLUMN IF NOT EXISTS pass_closed_at timestamptz;

-- FK integrity for the offer chosen at activation (bare uuid before this point).
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'reward_cycles_redeemed_offer_id_fkey'
    ) THEN
        ALTER TABLE public.reward_cycles
            ADD CONSTRAINT reward_cycles_redeemed_offer_id_fkey
            FOREIGN KEY (redeemed_offer_id) REFERENCES public.reward_offers(id) ON DELETE SET NULL;
    END IF;
END $$;

-- 2. reward_config: the 5-minute activation window, centralized/configurable per
-- Phase 14 requirement -- never hardcoded in Flutter or in more than one function.
ALTER TABLE public.reward_config
    ADD COLUMN IF NOT EXISTS activation_window_minutes integer NOT NULL DEFAULT 5
        CHECK (activation_window_minutes > 0);


-- =====================================================================================
-- 3. get_reward_status: extended (not redesigned) to also report the cycle id a client
--    should activate against (`current_cycle_id` -- the active, unexpired cycle
--    expiring soonest, so a cycle is never left to lapse unused while a newer one sits
--    available) and the configurable activation window, so Flutter never hardcodes "5
--    minutes" anywhere. Every previously-returned field is unchanged.
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
    v_current_cycle_id uuid;
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
            'id', rc.id,
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

    -- The cycle a client should activate against: whichever active, unexpired cycle
    -- expires soonest (use-it-or-lose-it first), independent of the others -- cycles
    -- remain independent as originally designed; consuming this one never affects any
    -- other still-active cycle.
    SELECT rc.id INTO v_current_cycle_id
    FROM public.reward_cycles rc
    WHERE rc.owner_type = p_owner_type
      AND rc.owner_id = v_owner_id
      AND rc.status = 'active'
      AND rc.expires_at >= now()
    ORDER BY rc.expires_at ASC
    LIMIT 1;

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
        'active_cycles', v_active_cycles,
        'current_cycle_id', v_current_cycle_id,
        'activation_window_minutes', v_config.activation_window_minutes
    );
END;
$function$;


-- =====================================================================================
-- 4. activate_reward_offer -- the single server-authoritative activation entry point.
--    Self-authorizing (resolves owner_id from auth.uid(), never trusts a client-supplied
--    owner id). Validates cycle ownership/liveness and the offer's own independent
--    valid_from/valid_until window, then atomically consumes the cycle and opens the
--    5-minute pass in one UPDATE. Returns a jsonb result object (success/error shape,
--    matching get_reward_status's own convention) rather than raising, so an expected
--    "already consumed"/"expired" outcome is a normal Flutter-side branch, not a crash.
-- =====================================================================================
CREATE OR REPLACE FUNCTION public.activate_reward_offer(
    p_owner_type text,
    p_reward_cycle_id uuid,
    p_offer_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_owner_id uuid;
    v_config record;
    v_offer record;
    v_now timestamptz := now();
    v_expires_at timestamptz;
    v_updated record;
BEGIN
    IF p_owner_type NOT IN ('user', 'rider') THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_OWNER_TYPE');
    END IF;

    IF p_owner_type = 'user' THEN
        v_owner_id := auth.uid();
    ELSE
        SELECT id INTO v_owner_id FROM public.riders WHERE user_id = auth.uid() LIMIT 1;
    END IF;

    IF v_owner_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'OWNER_NOT_FOUND');
    END IF;

    SELECT * INTO v_config FROM public.reward_config WHERE is_active = true LIMIT 1;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'CONFIG_NOT_FOUND');
    END IF;

    -- Offer must exist, be active, and be within its OWN independent validity window --
    -- entirely separate from the reward cycle's own expiry (a cycle expiring later than
    -- the offer, or vice versa, are both handled here: whichever constraint is tighter
    -- wins, since both are checked).
    SELECT o.* INTO v_offer
    FROM public.reward_offers o
    WHERE o.id = p_offer_id
      AND o.is_active = true
      AND (o.valid_from IS NULL OR o.valid_from <= v_now)
      AND (o.valid_until IS NULL OR o.valid_until >= v_now);

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'OFFER_NOT_AVAILABLE');
    END IF;

    v_expires_at := v_now + make_interval(mins => v_config.activation_window_minutes);

    -- Atomic single-use claim: only a cycle that is still owned by this caller, still
    -- 'active', and not yet expired can be claimed. A retried/duplicate/concurrent call
    -- for the same cycle_id sees 0 rows matched (status is no longer 'active') and
    -- returns CYCLE_NOT_AVAILABLE -- exactly one activation can ever succeed per cycle.
    UPDATE public.reward_cycles
    SET status = 'redeemed',
        redeemed_at = v_now,
        redeemed_offer_id = p_offer_id,
        activation_expires_at = v_expires_at
    WHERE id = p_reward_cycle_id
      AND owner_type = p_owner_type
      AND owner_id = v_owner_id
      AND status = 'active'
      AND expires_at >= v_now
    RETURNING * INTO v_updated;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'CYCLE_NOT_AVAILABLE');
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'reward_cycle_id', v_updated.id,
        'merchant_name', v_offer.merchant_name,
        'offer_title', v_offer.title,
        'discount_type', v_offer.discount_type,
        'discount_value', v_offer.discount_value,
        'activated_at', v_updated.redeemed_at,
        'expires_at', v_updated.activation_expires_at
    );
END;
$function$;

REVOKE ALL ON FUNCTION public.activate_reward_offer(text, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.activate_reward_offer(text, uuid, uuid) TO authenticated;


-- =====================================================================================
-- 5. close_active_pass -- best-effort cleanup called when the client observes a
--    terminal UI event (back navigation off the pass, or the app backgrounding while the
--    pass is showing). NOT the security boundary -- the reward cycle was already
--    permanently consumed by activate_reward_offer's atomic UPDATE above regardless of
--    whether this ever gets called (network drop, force-kill, etc. all still leave the
--    cycle correctly consumed). This only marks the pass itself as explicitly closed so
--    it is never re-presented as still-live after the user has already left it.
-- =====================================================================================
CREATE OR REPLACE FUNCTION public.close_active_pass(
    p_owner_type text,
    p_reward_cycle_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_owner_id uuid;
BEGIN
    IF p_owner_type NOT IN ('user', 'rider') THEN
        RETURN;
    END IF;

    IF p_owner_type = 'user' THEN
        v_owner_id := auth.uid();
    ELSE
        SELECT id INTO v_owner_id FROM public.riders WHERE user_id = auth.uid() LIMIT 1;
    END IF;

    IF v_owner_id IS NULL THEN
        RETURN;
    END IF;

    UPDATE public.reward_cycles
    SET pass_closed_at = now()
    WHERE id = p_reward_cycle_id
      AND owner_type = p_owner_type
      AND owner_id = v_owner_id
      AND pass_closed_at IS NULL;
END;
$function$;

REVOKE ALL ON FUNCTION public.close_active_pass(text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.close_active_pass(text, uuid) TO authenticated;
