-- Migration: Issue 3 -- intercity chat let an image reach the database (and, on live inspection,
-- would have let a text message through too via a direct API call) before the traveller accepted
-- the Travel Together request.
--
-- ROOT CAUSE (confirmed via live RLS inspection, not assumed): the "Allow chat participants to
-- send messages" INSERT policy on order_chat_messages only checks that the caller is a genuine
-- participant (order owner, assigned rider, or accepted rider_assignment) -- it never checks
-- intercity_requests.status at all. The client's own pre-acceptance block
-- (_sendMessage()'s "Issue 6A fix", already live) is real but purely client-side; its own comment
-- claims it makes the block "airtight", which is true only as long as the app itself is the sole
-- caller. The image/attachment button (_handleImageAction()) never had this guard applied to it at
-- all, so it remained fully tappable and would insert a message row (image messages are mocked to
-- a placeholder URL client-side today, not yet a real Storage upload -- but the order_chat_messages
-- row itself is a real, persisted database write either way) regardless of request status.
--
-- FIX: a BEFORE INSERT trigger on order_chat_messages -- the same defense-in-depth pattern already
-- used elsewhere in this schema (e.g. prevent_local_ride_assignment_to_busy_rider) -- rejects any
-- message (text or image, any client, any future call site) tied to an order whose intercity
-- negotiation request is still 'request_sent', with a clean RAISE EXCEPTION message instead of a
-- generic RLS denial. Postgrest surfaces a RAISE EXCEPTION's message text directly in the error
-- response body, so the client's existing catch/SnackBar path shows this exact sentence instead of
-- a raw 42501/PostgrestException. Admin/support senders are exempt, matching the existing RLS
-- policy's own carve-out. Orders with no intercity_requests row (every local ride/parcel chat, and
-- intercity chats past the request-sent stage) are completely unaffected -- the EXISTS check only
-- ever matches a still-pending intercity negotiation.
--
-- This does not touch the existing INSERT/SELECT/UPDATE/DELETE RLS policies themselves (no
-- weakening, no rewrite) -- it is an additive guard that runs before them.

CREATE OR REPLACE FUNCTION public.prevent_chat_before_intercity_acceptance()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.order_id IS NULL THEN
        RETURN NEW;
    END IF;

    -- Admin/support messages are never blocked, matching the existing RLS policy's own carve-out.
    IF EXISTS (
        SELECT 1 FROM public.users
        WHERE id = auth.uid() AND role IN ('admin', 'support')
    ) THEN
        RETURN NEW;
    END IF;

    IF EXISTS (
        SELECT 1 FROM public.intercity_requests ir
        WHERE ir.parcel_id = NEW.order_id
          AND ir.status = 'request_sent'
    ) THEN
        RAISE EXCEPTION 'You can send messages after the request is accepted.';
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public;

DROP TRIGGER IF EXISTS trigger_prevent_chat_before_intercity_acceptance ON public.order_chat_messages;
CREATE TRIGGER trigger_prevent_chat_before_intercity_acceptance
BEFORE INSERT ON public.order_chat_messages
FOR EACH ROW
EXECUTE FUNCTION public.prevent_chat_before_intercity_acceptance();
