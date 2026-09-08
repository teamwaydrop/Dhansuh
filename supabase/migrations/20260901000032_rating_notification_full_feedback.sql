-- =====================================================================
-- FIX: rating notification "Feedback:" clause silently truncated the written
-- feedback to 40 characters and unconditionally appended "..." even when the
-- comment was shorter than 40 characters.
-- =====================================================================
-- ROOT CAUSE (confirmed against the live production function body via
-- pg_get_functiondef, byte-for-byte match with 20260729000002's definition,
-- and reproduced live against a real production row: a 9-character comment
-- "too bad 😔", stored in full in rider_reviews.comment, produced the
-- notification body 'Feedback: "too bad 😔..."' -- a false-truncation
-- ellipsis appended to a comment that was never actually cut off):
--
--   v_body := v_body || ' Feedback: "' || substring(NEW.comment from 1 for 40) || '..."';
--
-- This is the ONLY truncation point in the whole path (rating screen -> INSERT
-- rider_reviews -> this trigger -> send_push_notification_fnc -> public.notifications
-- -> deliver_push_notification_http_fnc -> send-push-notification Edge Function
-- -> FCM). rider_reviews.comment itself was never truncated -- only the string
-- built for the notification's own body was.
--
-- FIX: build the Feedback clause from the complete, untruncated NEW.comment when
-- present, and use an explicit "No written feedback provided." fallback when it
-- is NULL/empty, instead of silently omitting the clause. Everything else in the
-- function -- both rated_by direction branches, recipient resolution, title
-- wording, the self-notify defense-in-depth guard, notification_type, and the
-- payload shape -- is reproduced byte-for-byte unchanged from
-- 20260729000002_fix_rating_notification_direction.sql.
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

    -- Issue: rating feedback not clear in notifications -- the complete feedback is included
    -- verbatim (no substring, no forced ellipsis), and an explicit fallback is shown instead of
    -- silently omitting the clause when no feedback was written.
    IF NEW.comment IS NOT NULL AND NEW.comment != '' THEN
        v_body := v_body || ' Feedback: "' || NEW.comment || '"';
    ELSE
        v_body := v_body || ' Feedback: "No written feedback provided."';
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
