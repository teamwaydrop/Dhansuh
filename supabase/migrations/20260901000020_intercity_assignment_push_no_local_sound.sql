-- Migration: stop intercity rider_assignments matches from triggering the local incoming-ride
-- push sound in the background/killed-app case.
-- Date: 2026-08-21
--
-- BUG: when an intercity parcel (or intercity ride, matched via a rider-initiated manual offer)
-- passenger books and a traveller gets matched, the traveller's phone plays the LOCAL
-- incoming-ride sound as if it were a local dispatch. The in-app/foreground path (RiderHomeTab's
-- realtime rider_assignments listener) was already fixed in the Flutter client to gate this sound
-- on the matched order's order_type. This migration fixes the remaining backend/background path:
--
-- public.on_rider_assignment_change() (20260602000002) fires a push notification with
-- `type: 'order_assignment'` for EVERY rider_assignments row that transitions to
-- assignment_status = 'sent' -- local dispatch AND intercity manual offers alike, with no
-- order_type check at all. send-push-notification/index.ts treats any type === 'order_assignment'
-- push as the local-ride alert and forces the order_nearby_sound channel/sound on both Android and
-- iOS (see that function's `isOrderAssignment` branches). This means a backgrounded or
-- fully-killed traveller app would still get the local ride sound for an intercity match via this
-- push, even after the foreground Flutter fix.
--
-- FIX: on_rider_assignment_change() now looks up the matched order's order_type and sends
-- `type: 'intercity_order_assignment'` instead of `'order_assignment'` when it is intercity_ride
-- or intercity_parcel. send-push-notification/index.ts needs no change: any type other than
-- 'order_assignment' already falls through to its default branch (default sound,
-- high_importance_channel) -- the exact same path intercity_request notifications already use, so
-- an intercity match remains audible via the OS's default notification sound, just never the
-- local order_nearby_sound. Local ride ('ride') and local parcel ('local_parcel') matches are
-- completely unaffected -- they still send 'order_assignment' and keep the existing sound.

CREATE OR REPLACE FUNCTION public.on_rider_assignment_change()
RETURNS TRIGGER AS $$
DECLARE
    v_rider_user_id uuid := NULL;
    v_order_type text := NULL;
    v_notification_type text := 'order_assignment';
BEGIN
    -- Notify when status is set or updated to 'sent'
    IF NEW.assignment_status = 'sent' AND (TG_OP = 'INSERT' OR OLD.assignment_status IS DISTINCT FROM 'sent') THEN
        SELECT user_id INTO v_rider_user_id FROM public.riders WHERE id = NEW.rider_id;

        IF v_rider_user_id IS NOT NULL THEN
            SELECT order_type::text INTO v_order_type FROM public.orders WHERE id = NEW.order_id;

            IF v_order_type IN ('intercity_ride', 'intercity_parcel') THEN
                v_notification_type := 'intercity_order_assignment';
            END IF;

            PERFORM public.send_push_notification_fnc(
                v_rider_user_id,
                'New Order Request',
                'You have a new order request nearby!',
                jsonb_build_object(
                    'type', v_notification_type,
                    'order_id', NEW.order_id,
                    'assignment_id', NEW.id
                )
            );
        END IF;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;
