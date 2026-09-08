-- =====================================================================
-- FIX (Bug 2, proven root cause): check_payout_update_limit() consumes one of
-- the "2 payout-account updates per week" slots on every bank-detail CHANGE,
-- regardless of whether the subsequent Cashfree beneficiary registration ever
-- actually succeeds. create-rider-payout writes rider_payout_accounts with the
-- new bank details (status: 'pending') BEFORE calling Cashfree -- that write
-- alone consumes a weekly slot even when Cashfree then rejects the
-- registration (confirmed live: two currently-failing riders had already used
-- both of their weekly slots on failed attempts before ever getting a working
-- beneficiary).
--
-- FIX (counting logic only -- same 2-per-7-days rule, same trigger, same
-- table, same RAISE EXCEPTION mechanism): a slot is now consumed only when a
-- row's cashfree_beneficiary_status genuinely transitions to 'active' --
-- i.e. Cashfree has confirmed the beneficiary is really registered -- instead
-- of on every raw bank-detail write attempt. create-rider-payout always
-- inserts a new row as 'pending' first and only updates it to 'active' after
-- a real Cashfree success (or 'failed' otherwise), so this fires at exactly
-- the point a registration genuinely succeeds, whether that's the row's
-- first save or a later re-save.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.check_payout_update_limit()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_update_count integer;
BEGIN
    -- Only a genuine transition INTO 'active' (Cashfree-confirmed registration)
    -- counts as one payout-account update. A row inserted/updated as
    -- 'pending' or 'failed' consumes nothing.
    IF NEW.cashfree_beneficiary_status = 'active'::public.cashfree_beneficiary_status_enum
       AND (TG_OP = 'INSERT' OR OLD.cashfree_beneficiary_status IS DISTINCT FROM 'active'::public.cashfree_beneficiary_status_enum) THEN

        -- 1. Lock the user row to prevent race conditions on concurrent requests
        PERFORM 1 FROM public.users WHERE id = NEW.user_id FOR UPDATE;

        -- 2. Count successful registrations in the last 7 days (rolling window)
        SELECT COUNT(*) INTO v_update_count
        FROM public.rider_payout_updates_log
        WHERE user_id = NEW.user_id
          AND created_at > now() - INTERVAL '7 days';

        IF v_update_count >= 2 THEN
            RAISE EXCEPTION 'Maximum of 2 payout account updates allowed per week';
        END IF;

        -- 3. Log this successful registration event
        INSERT INTO public.rider_payout_updates_log (user_id)
        VALUES (NEW.user_id);

    END IF;

    RETURN NEW;
END;
$function$;
