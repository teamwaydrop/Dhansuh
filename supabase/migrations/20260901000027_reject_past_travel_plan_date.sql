-- Migration: Issue 3 -- a Traveller could create an intercity travel plan for a date/time already
-- in the past (real example: current time 8:30 PM, travel plan created for 8:10 PM the same day).
--
-- ROOT CAUSE: post_travel_plan_screen.dart creates a travel plan via a DIRECT client-side
-- `supabase.from('rider_travel_plans').insert(...)` -- there is no edge function/RPC in this path
-- at all, and rider_travel_plans has no CHECK constraint or trigger validating travel_date. The
-- only client-side guard was the date picker's `firstDate: DateTime.now()`, which restricts the
-- DATE but not the TIME -- picking "today" and then a time earlier than the current time was never
-- rejected anywhere. A companion client-side fix (post_travel_plan_screen.dart's
-- _submitTravelPlan()) now also rejects this before ever attempting the insert, but per this
-- project's standard (validate server-side whenever creation doesn't go through an edge function),
-- the database itself must not trust the client.
--
-- FIX: a BEFORE INSERT trigger on rider_travel_plans rejects any row whose travel_date is not
-- strictly in the future at the moment of insert. Compared as absolute timestamptz instants (no new
-- timezone model -- travel_date is already stored as `timestamp with time zone`, and the client
-- already sends it via `.toUtc()`), so "today + 1 minute future" is allowed and "today + current
-- time" / "today + past time" / "an earlier date" are all rejected identically regardless of the
-- caller's local timezone. Scoped to INSERT only -- no existing UPDATE workflow in this codebase
-- ever changes travel_date after creation (grepped: none), so this cannot block any other
-- legitimate write (status changes, cancellations, seat/booking updates, etc. never touch this
-- column). Uses NOW() (the transaction start time), consistent with every other business-logic
-- trigger in this schema.
CREATE OR REPLACE FUNCTION public.reject_past_travel_plan_date()
RETURNS trigger AS $$
BEGIN
    IF NEW.travel_date <= NOW() THEN
        RAISE EXCEPTION 'Travel plan date/time must be in the future'
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public;

DROP TRIGGER IF EXISTS trigger_reject_past_travel_plan_date ON public.rider_travel_plans;
CREATE TRIGGER trigger_reject_past_travel_plan_date
BEFORE INSERT ON public.rider_travel_plans
FOR EACH ROW
EXECUTE FUNCTION public.reject_past_travel_plan_date();
