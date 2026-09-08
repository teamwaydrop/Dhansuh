-- =====================================================================
-- FIX: Traveller-rates-Passenger notification went to the wrong side
-- =====================================================================
-- ROOT CAUSE (confirmed against the live function body): on_rider_review_insert() (most recently
-- redefined by 20260718000004_reapply_search_path_hardening_batch.sql, unchanged in substance
-- since 20260602000003_expand_notifications_logic.sql) was written BEFORE bidirectional ratings
-- existed. It unconditionally resolves the notification recipient as
-- `SELECT user_id FROM riders WHERE id = NEW.rider_id` -- i.e. always the TRAVELLER on the order,
-- regardless of who actually submitted the rating.
--
-- 20260717000007_intercity_bidirectional_ratings.sql later added rider_reviews.rated_by
-- ('user' = passenger rated traveller, 'rider' = traveller rated passenger) so a rider could also
-- rate a passenger, using the SAME table/columns (order_id, rider_id, user_id fixed per order,
-- never swapped for direction) -- but nothing ever updated on_rider_review_insert() to branch on
-- rated_by. So when a traveller rates a passenger (rated_by='rider'), the trigger still resolves
-- the recipient from NEW.rider_id -- the traveller's OWN user_id -- notifying the traveller about
-- their own rating submission, while the passenger (the actual intended recipient, NEW.user_id)
-- never gets notified at all. Passenger-rates-traveller (rated_by='user', the original/default
-- path) was never affected and continues to work correctly.
--
-- FIX: branch the recipient resolution on NEW.rated_by, deriving the recipient purely from the
-- order's own authoritative participant columns (never a client-supplied recipient id -- there
-- isn't one; the trigger always derives it itself from rider_reviews/riders). Also add a
-- defense-in-depth guard so the rating's own submitter (auth.uid(), enforced by the existing
-- rated_by-scoped RLS insert policies to always equal the true actor) can never be the recipient,
-- even if some future bug in the direction-resolution logic above were to send it to the wrong
-- person again.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.on_rider_review_insert()
RETURNS TRIGGER AS $$
DECLARE
    v_recipient_user_id uuid := NULL;
    v_title text;
    v_body text;
BEGIN
    IF NEW.rated_by = 'rider' THEN
        -- Traveller/Drop Partner rated the passenger -> the PASSENGER is the recipient. NEW.user_id
        -- is the order's passenger column directly -- never derived from anything client-supplied.
        v_recipient_user_id := NEW.user_id;

        IF NEW.rating = 5 THEN
            v_title := 'You''ve been rated 5-Star! 🌟';
            v_body := 'Your Drop Partner rated your trip 5 stars!';
        ELSE
            v_title := 'New Rating Received';
            v_body := 'Your Drop Partner rated your trip.';
        END IF;
    ELSE
        -- Passenger rated the traveller (rated_by = 'user', the original/default direction) -> the
        -- TRAVELLER is the recipient, resolved via riders.user_id from NEW.rider_id (unchanged from
        -- the original, correct behavior for this direction).
        SELECT user_id INTO v_recipient_user_id FROM public.riders WHERE id = NEW.rider_id;

        IF NEW.rating = 5 THEN
            v_title := 'You''ve been rated 5-Star! 🌟';
            v_body := 'Excellent job! Your passenger rated your trip 5 stars. Keep up the amazing work!';
        ELSE
            v_title := 'New Rating Received';
            v_body := 'Your passenger rated their trip with you.';
        END IF;
    END IF;

    IF NEW.comment IS NOT NULL AND NEW.comment != '' THEN
        v_body := v_body || ' Feedback: "' || substring(NEW.comment from 1 for 40) || '..."';
    END IF;

    -- Defense in depth: the rating's submitter must never be its own recipient. auth.uid() here is
    -- the actual authenticated inserter (enforced to match rated_by by the existing "Users/Riders
    -- can insert reviews for their own orders" RLS policies), so this can never fire for a
    -- legitimate insert -- it only guards against a future regression re-introducing self-notify.
    IF v_recipient_user_id IS NOT NULL AND v_recipient_user_id IS DISTINCT FROM auth.uid() THEN
        PERFORM public.send_push_notification_fnc(
            v_recipient_user_id,
            v_title,
            v_body,
            jsonb_build_object(
                'type', 'new_rating',
                'rating', NEW.rating,
                'review_id', NEW.id,
                'order_id', NEW.order_id,
                'rated_by', NEW.rated_by
            )
        );
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;
