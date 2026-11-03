-- =============================================================================
-- PHASE 2 B-LITE — move the 3 NON-FINANCIAL completion side effects off the
-- synchronous critical-path transaction of complete_order_and_settle().
--
-- CONTEXT (from docs/PERF_phase2_implementation_dependency_audit.md, verified live):
--   complete_order_and_settle() is one atomic transaction (T1). Its step-1
--   `UPDATE orders SET order_status = <terminal>` fires 7 AFTER-triggers
--   synchronously inside T1. Three of them do NON-FINANCIAL work that has no
--   reason to run inside the completion transaction and lengthens how long T1
--   (and the row locks every concurrent/retried request queues behind) stays
--   open:
--
--     1. on_order_activity_tracking      -> handle_order_activity_tracking()
--          UPSERT public.rider_daily_activity  (rider stats: active_seconds,
--          completed_orders / cancelled_orders, earnings). NOT idempotent
--          (increments). Affects NO money -- rider wallet/earnings/tax live in
--          credit_rider_for_completed_order() + apply_order_government_tax(),
--          both untouched by this migration and still fully inside T1.
--     2. trg_reward_cycle_after_completion -> trg_reward_cycle_on_order_completion()
--          PERFORM evaluate_reward_cycle('user'|'rider', ...). Runs a COUNT over
--          public.orders per owner then INSERT ... ON CONFLICT DO NOTHING into
--          public.reward_cycles. Fully idempotent + self-healing (the next
--          completed ride re-evaluates from the full count). Loyalty only.
--     3. trigger_expire_trip_sharing_tokens -> expire_trip_sharing_tokens()
--          UPDATE public.trip_share_tokens SET is_revoked = true WHERE order_id.
--          Idempotent. Share links also carry their own expires_at.
--
--   Push notifications are ALREADY async (on_order_status_update only
--   net.http_post-enqueues); this migration does NOT touch that mechanism.
--
-- WHAT THIS MIGRATION DOES:
--   * Replaces the 3 triggers above with ONE thin trigger
--     (enqueue_order_completion_side_effects) that, on a real transition into a
--     terminal state:
--       (a) DURABLY records one order_completion_side_effects row -- this INSERT
--           is part of the completion transaction itself, NOT inside any
--           exception-catching sub-block, so it commits atomically with the ride
--           completion and cannot be rolled back by an enqueue failure; and
--       (b) BEST-EFFORT does ONE net.http_post enqueue (a fast local queue
--           insert) to the worker RPC, inside its own isolated BEGIN/EXCEPTION
--           so a vault/net.http_post failure only WARNs and leaves the (a) row
--           pending for the retry cron.
--   * The worker RPC (process_order_completion_side_effects) runs the identical
--     3 pieces of logic a moment AFTER T1 commits, in its own transaction, with
--     per-effect exception isolation and an idempotency guard for the one
--     non-idempotent effect (rider_daily_activity).
--   * A pg_cron backstop (retry-pending-order-completion-side-effects, every
--     5 min) re-invokes the worker in-database (no pg_net dependency) for any
--     row still `processed_at IS NULL AND attempts < 5` after a 2-minute grace
--     window -- covering a failed immediate enqueue, a failed pg_net HTTP
--     delivery, or a pg_net worker outage. Bounded at 5 total worker attempts
--     per order; after that the row stays visibly pending for manual review.
--   * The 3 original trigger FUNCTIONS are left in place, unused, so rollback is
--     just "recreate the 3 triggers" (see the rollback block at the bottom).
--
-- WHAT THIS MIGRATION DOES NOT TOUCH:
--   complete_order_and_settle(), fare calc, tax calc (apply_order_government_tax),
--   wallet crediting (credit_rider_for_completed_order), rider earnings,
--   order_status_history semantics, dispatch, GPS / rider location, REPLICA
--   IDENTITY, existing RLS policies, EXISTING cron schedules (this migration only
--   ADDS one new job, idempotently, and never alters jobs 1-7), the
--   push-notification pipeline, any Dart code.
--
-- TRANSACTION BOUNDARY (per completion):
--   BEFORE: T1 = order UPDATE + 7 triggers (incl. 3 rider_daily_activity /
--           reward-cycle-COUNT / trip_share_tokens writes + their lock
--           acquisitions) + rider_assignments settle + tax + wallet + history.
--   AFTER:  T1 = order UPDATE + 5 triggers (the 3 heavy ones replaced by ONE
--           durable INSERT into order_completion_side_effects + ONE net.http_post
--           enqueue + ONE vault decrypt) + rider_assignments settle + tax +
--           wallet + history.  The 3 side effects run in T2 (pg_net worker ->
--           PostgREST RPC), typically < 1 s later, or in a later retry-cron tick.
--
-- FAILURE / RETRY:
--   * Completion NEVER rolls back for a side-effect failure -- the immediate
--     enqueue (vault + net.http_post) is isolated in its own BEGIN/EXCEPTION and
--     only RAISEs a WARNING. This is strictly safer than today, where an
--     activity-tracking or token-revoke failure would abort completion.
--   * The order_completion_side_effects row is created OUTSIDE that
--     BEGIN/EXCEPTION, so it survives an enqueue failure. `processed_at IS NULL`
--     therefore RELIABLY means "side effects still owed".
--   * activity_effect_done / reward_effect_done / token_effect_done => which
--     pieces have committed; a retry re-runs ONLY what has not. attempts,
--     last_error => diagnostics. attempts is capped at 5 (the retry cron only
--     selects attempts < 5; the worker's claim increments it once per run).
--   * Duplicate delivery / concurrent workers: the worker's claim row-lock on
--     the order_completion_side_effects row + the *_done flags + the reward
--     ON CONFLICT + the token `is_revoked = false` filter make every extra run a
--     no-op. No double-apply of the non-idempotent activity increment.
--   * No error is silently swallowed: each failed effect -> RAISE WARNING +
--     last_error column; a failed immediate enqueue -> RAISE WARNING + pending row.
--
-- ROLLBACK: see the commented block at the end of this file.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. Dedup / observability / retry-state table.
--    Internal only: RLS enabled with NO policies -> anon/authenticated get zero
--    access; the SECURITY DEFINER functions below (owner rights) and service_role
--    (RLS bypass) are the only writers/readers. Not added to any publication.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.order_completion_side_effects (
    order_id             uuid PRIMARY KEY REFERENCES public.orders(id) ON DELETE CASCADE,
    terminal_status      text        NOT NULL,
    enqueued_at          timestamptz NOT NULL DEFAULT now(),
    attempts             integer     NOT NULL DEFAULT 0,
    activity_effect_done boolean      NOT NULL DEFAULT false,
    reward_effect_done   boolean      NOT NULL DEFAULT false,
    token_effect_done    boolean      NOT NULL DEFAULT false,
    processed_at         timestamptz,
    last_error           text
);

ALTER TABLE public.order_completion_side_effects ENABLE ROW LEVEL SECURITY;

COMMENT ON TABLE public.order_completion_side_effects IS
    'Phase 2 B-lite: one row per terminal order transition. Dedup anchor + '
    'observability + retry state for the async non-financial completion side '
    'effects (rider_daily_activity, reward cycle, trip-share-token revoke). '
    'processed_at IS NULL => pending/failed.';


-- -----------------------------------------------------------------------------
-- 2. Worker RPC -- runs the 3 side effects AFTER T1 has committed.
--    Logic for each effect is reproduced from the current trigger functions
--    (handle_order_activity_tracking / trg_reward_cycle_on_order_completion /
--    expire_trip_sharing_tokens), reading the already-committed orders row
--    instead of NEW.*. Per-effect subtransaction so one failure never blocks the
--    others or the row's finalization.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.process_order_completion_side_effects(p_order_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_rec       public.order_completion_side_effects%ROWTYPE;
    v_o         public.orders%ROWTYPE;
    v_date      date;
    v_trip_time integer := 0;
    v_earnings  numeric := 0.0;
    v_err       text := NULL;
BEGIN
    -- Claim: bump attempts, capture current flag state. No row => never enqueued.
    UPDATE public.order_completion_side_effects
       SET attempts = attempts + 1
     WHERE order_id = p_order_id
    RETURNING * INTO v_rec;

    IF NOT FOUND THEN
        RAISE WARNING 'process_order_completion_side_effects: no enqueue row for order % -- skipping', p_order_id;
        RETURN;
    END IF;

    -- Already fully processed (e.g. duplicate delivery) -> no-op.
    IF v_rec.processed_at IS NOT NULL THEN
        RETURN;
    END IF;

    SELECT * INTO v_o FROM public.orders WHERE id = p_order_id;
    IF NOT FOUND THEN
        UPDATE public.order_completion_side_effects
           SET processed_at = now(),
               last_error   = 'order row not found at processing time'
         WHERE order_id = p_order_id;
        RETURN;
    END IF;

    -- ---- Effect 1: rider_daily_activity (NON-IDEMPOTENT: gated by activity_effect_done) ----
    IF NOT v_rec.activity_effect_done THEN
        IF v_o.rider_id IS NOT NULL THEN
            BEGIN
                v_date := (COALESCE(v_o.completed_at, v_o.cancelled_at, now()) AT TIME ZONE 'Asia/Kolkata')::date;

                IF v_o.order_status IN ('completed', 'delivered') THEN
                    IF v_o.time_taken_seconds IS NOT NULL AND v_o.time_taken_seconds > 0 THEN
                        v_trip_time := v_o.time_taken_seconds;
                    ELSIF v_o.completed_at IS NOT NULL THEN
                        v_trip_time := GREATEST(0, EXTRACT(EPOCH FROM (
                            v_o.completed_at - COALESCE(v_o.picked_up_at, v_o.accepted_at, v_o.created_at)
                        ))::integer);
                    ELSE
                        v_trip_time := 0;
                    END IF;

                    v_earnings := COALESCE(v_o.rider_earning, 0.0);

                    INSERT INTO public.rider_daily_activity (rider_id, date, active_seconds, completed_orders, earnings)
                    VALUES (v_o.rider_id, v_date, v_trip_time, 1, v_earnings)
                    ON CONFLICT (rider_id, date) DO UPDATE
                    SET active_seconds   = rider_daily_activity.active_seconds + v_trip_time,
                        completed_orders = rider_daily_activity.completed_orders + 1,
                        earnings         = rider_daily_activity.earnings + v_earnings,
                        updated_at       = now();

                ELSIF v_o.order_status = 'cancelled' THEN
                    INSERT INTO public.rider_daily_activity (rider_id, date, cancelled_orders)
                    VALUES (v_o.rider_id, v_date, 1)
                    ON CONFLICT (rider_id, date) DO UPDATE
                    SET cancelled_orders = rider_daily_activity.cancelled_orders + 1,
                        updated_at       = now();
                END IF;

                UPDATE public.order_completion_side_effects
                   SET activity_effect_done = true
                 WHERE order_id = p_order_id;
            EXCEPTION WHEN OTHERS THEN
                v_err := format('activity: %s', SQLERRM);
                RAISE WARNING 'process_order_completion_side_effects[activity] order %: %', p_order_id, SQLERRM;
            END;
        ELSE
            -- Original trigger is a no-op when rider_id IS NULL -> nothing owed.
            UPDATE public.order_completion_side_effects
               SET activity_effect_done = true
             WHERE order_id = p_order_id;
        END IF;
    END IF;

    -- ---- Effect 2: reward cycle (idempotent; completed/delivered only) ----
    IF NOT v_rec.reward_effect_done THEN
        BEGIN
            IF v_o.order_status IN ('completed', 'delivered') THEN
                PERFORM public.evaluate_reward_cycle('user', v_o.user_id);
                IF v_o.rider_id IS NOT NULL THEN
                    PERFORM public.evaluate_reward_cycle('rider', v_o.rider_id);
                END IF;
            END IF;
            UPDATE public.order_completion_side_effects
               SET reward_effect_done = true
             WHERE order_id = p_order_id;
        EXCEPTION WHEN OTHERS THEN
            v_err := concat_ws(' | ', v_err, format('reward: %s', SQLERRM));
            RAISE WARNING 'process_order_completion_side_effects[reward] order %: %', p_order_id, SQLERRM;
        END;
    END IF;

    -- ---- Effect 3: trip-share-token revoke (idempotent) ----
    IF NOT v_rec.token_effect_done THEN
        BEGIN
            IF v_o.order_status IN ('completed', 'delivered', 'cancelled') THEN
                UPDATE public.trip_share_tokens
                   SET is_revoked = true
                 WHERE order_id = p_order_id
                   AND is_revoked = false;
            END IF;
            UPDATE public.order_completion_side_effects
               SET token_effect_done = true
             WHERE order_id = p_order_id;
        EXCEPTION WHEN OTHERS THEN
            v_err := concat_ws(' | ', v_err, format('token: %s', SQLERRM));
            RAISE WARNING 'process_order_completion_side_effects[token] order %: %', p_order_id, SQLERRM;
        END;
    END IF;

    -- Finalize. processed_at is set ONLY when all three effects have committed
    -- (the *_done reads below see the freshly-committed flag values).
    UPDATE public.order_completion_side_effects
       SET last_error  = v_err,
           processed_at = CASE
               WHEN activity_effect_done AND reward_effect_done AND token_effect_done
               THEN now() ELSE processed_at END
     WHERE order_id = p_order_id;
END;
$function$;

-- Lock down to the backend role only: the immediate-enqueue net.http_post
-- authenticates as service_role, and the retry cron runs it in-database. No
-- client role (anon / authenticated) may invoke it.
REVOKE ALL ON FUNCTION public.process_order_completion_side_effects(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.process_order_completion_side_effects(uuid) TO service_role;


-- -----------------------------------------------------------------------------
-- 3. The thin enqueue trigger.
--    (a) DURABLE tracking-row INSERT -- part of the completion transaction, NOT
--        inside the exception-catching block, so an enqueue failure cannot roll
--        it back.  (b) BEST-EFFORT immediate net.http_post enqueue -- isolated in
--        its own BEGIN/EXCEPTION (same shape as on_order_status_update(),
--        20260810000000). If (b) fails, (a) stays and the retry cron (section 5)
--        picks it up.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.enqueue_order_completion_side_effects()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_supabase_url text := 'https://yvwpchffctiagevpqgwy.supabase.co';
    v_service_role_key text;
BEGIN
    -- Only on a genuine transition INTO a terminal state. This is the union of
    -- the 3 replaced triggers' firing conditions; the worker RPC re-applies the
    -- per-effect narrowing (reward cycle only for completed/delivered, etc.).
    IF OLD.order_status IS DISTINCT FROM NEW.order_status
       AND NEW.order_status IN ('completed', 'delivered', 'cancelled') THEN

        -- (a) DURABLE tracking / dedup / "pending" row. Deliberately OUTSIDE the
        --     BEGIN/EXCEPTION below: it is part of the completion transaction and
        --     commits atomically with the ride completion, so `processed_at IS
        --     NULL` reliably means "side effects still owed". A single-row PK
        --     insert with a valid FK cannot fail with unique_violation
        --     (ON CONFLICT DO NOTHING); any other failure here is catastrophic
        --     (disk/corruption) and completion aborting alongside it is correct.
        --     A re-fired transition for the same order is a harmless no-op.
        INSERT INTO public.order_completion_side_effects (order_id, terminal_status)
        VALUES (NEW.id, NEW.order_status::text)
        ON CONFLICT (order_id) DO NOTHING;

        -- (b) BEST-EFFORT immediate enqueue. Isolated: a vault lookup or
        --     net.http_post failure only WARNs -- it can neither roll back the
        --     completion (per WHAT THIS MIGRATION DOES NOT TOUCH) nor remove the
        --     row from (a). The retry cron will re-drive it.
        BEGIN
            SELECT decrypted_secret INTO v_service_role_key
            FROM vault.decrypted_secrets
            WHERE name = 'supabase_service_role_key'
            LIMIT 1;

            IF v_service_role_key IS NOT NULL THEN
                PERFORM net.http_post(
                    url := v_supabase_url || '/rest/v1/rpc/process_order_completion_side_effects',
                    headers := jsonb_build_object(
                        'Content-Type', 'application/json',
                        'Authorization', 'Bearer ' || v_service_role_key,
                        'apikey', v_service_role_key
                    ),
                    body := jsonb_build_object('p_order_id', NEW.id),
                    timeout_milliseconds := 5000
                );
            ELSE
                RAISE WARNING 'enqueue_order_completion_side_effects: vault secret "supabase_service_role_key" is not configured -- order % left pending for the retry cron', NEW.id;
            END IF;
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING 'enqueue_order_completion_side_effects: immediate enqueue failed for order % (left pending for the retry cron): %', NEW.id, SQLERRM;
        END;
    END IF;

    RETURN NEW;
END;
$function$;


-- -----------------------------------------------------------------------------
-- 4. Swap the triggers. The 3 replaced trigger FUNCTIONS are intentionally left
--    in place (unused) so rollback is a 3-line trigger recreate.
-- -----------------------------------------------------------------------------
DROP TRIGGER IF EXISTS on_order_activity_tracking      ON public.orders;
DROP TRIGGER IF EXISTS trg_reward_cycle_after_completion ON public.orders;
DROP TRIGGER IF EXISTS trigger_expire_trip_sharing_tokens ON public.orders;

CREATE TRIGGER trg_order_completion_side_effects
AFTER UPDATE OF order_status ON public.orders
FOR EACH ROW
EXECUTE FUNCTION public.enqueue_order_completion_side_effects();


-- -----------------------------------------------------------------------------
-- 5. Retry backstop.
--    The immediate enqueue in section 3(b) can fail (vault, net.http_post), and
--    even a successful enqueue can fail LATER (pg_net HTTP delivery error, pg_net
--    worker outage). This sweep re-drives any still-pending row by calling the
--    SAME worker IN-DATABASE (PERFORM, no pg_net dependency), so it works even
--    when pg_net is the thing that is broken.
--
--    Concurrency / idempotency (unchanged from the worker's own guarantees):
--      - Selection is a plain read; the worker's claim UPDATE row-locks the
--        order_completion_side_effects row, so a concurrent immediate-worker or a
--        second overlapping sweep on the same order serialises and no-ops on the
--        already-committed *_done flags / processed_at.
--      - A transaction-scoped advisory lock (namespace 4735021, classifier 3 --
--        see 20260908000000_redispatch_cron_advisory_locks.sql for 1 and 2)
--        stops this job from running two overlapping sweeps against itself.
--      - attempts is bounded: only rows with attempts < 5 are selected; the
--        worker's claim increments attempts exactly once per invocation, so a
--        permanently-failing row reaches attempts = 5 and is then never selected
--        again (it stays visibly pending for manual review -- "not forever").
--      - processed_at IS NOT NULL rows (fully done) are never selected.
--      - 2-minute grace (enqueued_at) avoids racing an in-flight initial enqueue.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.retry_pending_order_completion_side_effects()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_order_id uuid;
BEGIN
    IF NOT pg_try_advisory_xact_lock(4735021, 3) THEN
        RAISE NOTICE 'retry_pending_order_completion_side_effects: previous sweep still running -- skipping this tick.';
        RETURN;
    END IF;

    FOR v_order_id IN
        SELECT order_id
        FROM public.order_completion_side_effects
        WHERE processed_at IS NULL
          AND attempts < 5
          AND enqueued_at < now() - INTERVAL '2 minutes'
        ORDER BY enqueued_at
        LIMIT 100
    LOOP
        BEGIN
            PERFORM public.process_order_completion_side_effects(v_order_id);
        EXCEPTION WHEN OTHERS THEN
            -- One order's failure must never abort the rest of the sweep. The
            -- worker already records last_error on the row; this is the outer guard.
            RAISE WARNING 'retry_pending_order_completion_side_effects: order % failed this pass: %', v_order_id, SQLERRM;
        END;
    END LOOP;
END;
$function$;

REVOKE ALL ON FUNCTION public.retry_pending_order_completion_side_effects() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.retry_pending_order_completion_side_effects() TO service_role;

-- Schedule it -- ONLY if pg_cron is installed AND a job of this exact name does
-- not already exist (same idempotency convention as
-- 20260807000000_schedule_missing_pg_cron_jobs.sql). Never touches jobs 1-7.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
        IF NOT EXISTS (
            SELECT 1 FROM cron.job WHERE jobname = 'retry-pending-order-completion-side-effects'
        ) THEN
            PERFORM cron.schedule(
                'retry-pending-order-completion-side-effects',
                '*/5 * * * *',  -- every 5 min; pending rows exist only on a pg_net delivery failure
                'SELECT public.retry_pending_order_completion_side_effects();'
            );
        END IF;
    END IF;
END $$;


-- =============================================================================
-- ROLLBACK (run manually if needed):
--
--   -- Section 5 (retry backstop):
--   SELECT cron.unschedule('retry-pending-order-completion-side-effects');
--   DROP FUNCTION IF EXISTS public.retry_pending_order_completion_side_effects();
--
--
--   DROP TRIGGER IF EXISTS trg_order_completion_side_effects ON public.orders;
--
--   CREATE TRIGGER on_order_activity_tracking
--     AFTER UPDATE OF order_status ON public.orders
--     FOR EACH ROW EXECUTE FUNCTION handle_order_activity_tracking();
--
--   CREATE TRIGGER trg_reward_cycle_after_completion
--     AFTER UPDATE OF order_status ON public.orders
--     FOR EACH ROW EXECUTE FUNCTION trg_reward_cycle_on_order_completion();
--
--   CREATE TRIGGER trigger_expire_trip_sharing_tokens
--     AFTER UPDATE OF order_status ON public.orders
--     FOR EACH ROW EXECUTE FUNCTION expire_trip_sharing_tokens();
--
--   DROP FUNCTION IF EXISTS public.enqueue_order_completion_side_effects();
--   DROP FUNCTION IF EXISTS public.process_order_completion_side_effects(uuid);
--   DROP TABLE IF EXISTS public.order_completion_side_effects;
--
-- (Safe at any time: nothing else depends on the new objects, and the 3 original
--  trigger functions were never dropped.)
-- =============================================================================
