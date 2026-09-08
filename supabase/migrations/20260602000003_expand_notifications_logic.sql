-- =====================================================================
-- Migration: Expanded Notification Logic & Scheduler
-- Date: 2026-06-02
-- Description: Adds tracking columns, triggers for rating/reviews and 
--              COD settlements, schedules dormant checks, and updates 
--              order status triggers with rich OTP details.
-- =====================================================================

-- 1. Add tracking columns to public.riders
ALTER TABLE public.riders ADD COLUMN IF NOT EXISTS last_dormant_notification_sent_at timestamp with time zone;
ALTER TABLE public.riders ADD COLUMN IF NOT EXISTS last_sub_offline_notification_sent_at timestamp with time zone;

-- 2. Add tracking columns to public.rider_subscription_history
ALTER TABLE public.rider_subscription_history ADD COLUMN IF NOT EXISTS expire_warning_sent boolean DEFAULT false;


-- 3. Scheduled Dormant & Subscription Check Function
CREATE OR REPLACE FUNCTION public.check_dormant_riders()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_rider RECORD;
    v_sub RECORD;
    v_hour integer;
BEGIN
    -- Get current hour in IST timezone
    v_hour := extract(hour from now() at time zone 'Asia/Kolkata');

    -- 3.1. Morning Dormant Rider Check (8:00 AM to 11:00 AM IST)
    -- If rider is offline for >2 hours and hasn't been notified today
    IF v_hour >= 8 AND v_hour <= 11 THEN
        FOR v_rider IN 
            SELECT r.id, r.user_id 
            FROM public.riders r
            WHERE (r.account_status != 'online' OR r.account_status IS NULL)
              AND (r.updated_at IS NULL OR r.updated_at < now() - INTERVAL '2 hours')
              AND (r.last_dormant_notification_sent_at IS NULL OR r.last_dormant_notification_sent_at < date_trunc('day', now() at time zone 'Asia/Kolkata'))
        LOOP
            PERFORM public.send_push_notification_fnc(
                v_rider.user_id,
                'Go Online! Rides & Parcels Waiting 🚀',
                'Rides and parcels are waiting in your location. Go online now to start earning!',
                jsonb_build_object('type', 'go_online')
            );
            
            UPDATE public.riders 
            SET last_dormant_notification_sent_at = now() 
            WHERE id = v_rider.id;
        END LOOP;
    END IF;

    -- 3.2. Active Subscription Offline Check
    -- If subscription is active, and rider is offline for >2 hours, remind them of zero commission benefits
    FOR v_rider IN 
        SELECT r.id, r.user_id 
        FROM public.riders r
        INNER JOIN public.rider_subscription_history sub ON sub.rider_id = r.id
        WHERE (r.account_status != 'online' OR r.account_status IS NULL)
          AND sub.is_active = true 
          AND sub.expires_at > now()
          AND (r.updated_at IS NULL OR r.updated_at < now() - INTERVAL '2 hours')
          AND (r.last_sub_offline_notification_sent_at IS NULL OR r.last_sub_offline_notification_sent_at < now() - INTERVAL '24 hours')
    LOOP
        PERFORM public.send_push_notification_fnc(
            v_rider.user_id,
            'Your Subscription is Active! ⚡',
            'Your Waydrop MAX subscription is active. Go online and take rides now to avail 100% commission-free earnings!',
            jsonb_build_object('type', 'go_online_sub')
        );
        
        UPDATE public.riders 
        SET last_sub_offline_notification_sent_at = now() 
        WHERE id = v_rider.id;
    END LOOP;

    -- 3.3. Subscription Expiry Checker
    -- A) Mark expired subscriptions inactive & notify
    FOR v_sub IN 
        SELECT sub.id, sub.rider_id, r.user_id 
        FROM public.rider_subscription_history sub
        INNER JOIN public.riders r ON r.id = sub.rider_id
        WHERE sub.is_active = true 
          AND sub.expires_at <= now()
    LOOP
        UPDATE public.rider_subscription_history 
        SET is_active = false 
        WHERE id = v_sub.id;

        PERFORM public.send_push_notification_fnc(
            v_sub.user_id,
            'Waydrop MAX Subscription Expired ⚠️',
            'Your commission-free subscription has expired. Renew/extend now to keep earning without commissions!',
            jsonb_build_object('type', 'subscription_expired')
        );
    END LOOP;

    -- B) Notify subscriptions expiring in the next 24 hours
    FOR v_sub IN 
        SELECT sub.id, sub.rider_id, r.user_id, sub.expires_at 
        FROM public.rider_subscription_history sub
        INNER JOIN public.riders r ON r.id = sub.rider_id
        WHERE sub.is_active = true 
          AND sub.expires_at > now() 
          AND sub.expires_at <= now() + INTERVAL '24 hours'
          AND sub.expire_warning_sent = false
    LOOP
        UPDATE public.rider_subscription_history 
        SET expire_warning_sent = true 
        WHERE id = v_sub.id;

        PERFORM public.send_push_notification_fnc(
            v_sub.user_id,
            'Subscription Expiring Soon ⏰',
            'Your Waydrop MAX subscription expires in less than 24 hours (on ' || to_char(v_sub.expires_at at time zone 'Asia/Kolkata', 'HH:MI AM, DD Mon') || '). Extend now!',
            jsonb_build_object('type', 'subscription_expiring')
        );
    END LOOP;
END;
$$;


-- 4. Enable pg_cron schedule if pg_cron is enabled
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
        -- Run the dormant and expiry checks every hour
        PERFORM cron.schedule(
            'rider-dormant-and-expiry-checks',
            '0 * * * *', -- At minute 0 of every hour
            'SELECT public.check_dormant_riders();'
        );
    END IF;
END $$;


-- 5. Trigger for Rider Reviews (Rating Notification)
CREATE OR REPLACE FUNCTION public.on_rider_review_insert()
RETURNS TRIGGER AS $$
DECLARE
    v_rider_user_id uuid := NULL;
    v_title text := 'New Review Received';
    v_body text := '';
BEGIN
    SELECT user_id INTO v_rider_user_id FROM public.riders WHERE id = NEW.rider_id;

    IF v_rider_user_id IS NOT NULL THEN
        IF NEW.rating = 5 THEN
            v_title := 'You''ve been rated 5-Star! 🌟';
            v_body := 'Excellent job! A passenger rated you 5 stars. Keep up the amazing work!';
        ELSE
            v_title := 'New Rating Received ⭐';
            v_body := 'You received a new ' || NEW.rating::text || '-star rating from your recent ride.';
        END IF;

        IF NEW.comment IS NOT NULL AND NEW.comment != '' THEN
            v_body := v_body || ' Feedback: "' || substring(NEW.comment from 1 for 40) || '..."';
        END IF;

        PERFORM public.send_push_notification_fnc(
            v_rider_user_id,
            v_title,
            v_body,
            jsonb_build_object(
                'type', 'new_rating',
                'rating', NEW.rating,
                'review_id', NEW.id
            )
        );
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS trigger_rider_review_insert ON public.rider_reviews;
CREATE TRIGGER trigger_rider_review_insert
AFTER INSERT ON public.rider_reviews
FOR EACH ROW
EXECUTE FUNCTION public.on_rider_review_insert();


-- 6. Trigger for COD Settlement limit checks on wallet balance
CREATE OR REPLACE FUNCTION public.on_rider_wallet_balance_update()
RETURNS TRIGGER AS $$
BEGIN
    -- If wallet balance drops below -500 (meaning they owe more than 500 rupees cash collected)
    -- And it was not below -500 before (to avoid spamming on subsequent updates)
    IF NEW.wallet_balance < -500 AND (OLD.wallet_balance IS NULL OR OLD.wallet_balance >= -500) THEN
        PERFORM public.send_push_notification_fnc(
            NEW.user_id,
            'COD Settlement Required 💳',
            'Your cash collections exceed the allowed limit. Please pay your COD settlement of ₹' || ABS(NEW.wallet_balance)::text || ' to continue receiving ride requests.',
            jsonb_build_object(
                'type', 'cod_settlement',
                'balance', NEW.wallet_balance
            )
        );
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS trigger_rider_wallet_balance_update ON public.riders;
CREATE TRIGGER trigger_rider_wallet_balance_update
AFTER UPDATE OF wallet_balance ON public.riders
FOR EACH ROW
EXECUTE FUNCTION public.on_rider_wallet_balance_update();


-- 7. Redefine public.on_order_status_update with dynamic, detail-rich messages (OTPs, Drop-off Alerts)
CREATE OR REPLACE FUNCTION public.on_order_status_update()
RETURNS TRIGGER AS $$
DECLARE
    v_rider_user_id uuid := NULL;
    v_title text := '';
    v_body text := '';
    v_otp text := '';
BEGIN
    -- Check if status actually changed
    IF OLD.order_status IS DISTINCT FROM NEW.order_status THEN
        -- 1. Notify Passenger (NEW.user_id) for status updates
        IF NEW.order_status = 'accepted' THEN
            v_title := 'Order Accepted 🚗';
            v_body := 'A rider has accepted your order and is on the way!';
        ELSIF NEW.order_status = 'rider_arrived' THEN
            v_otp := COALESCE(NEW.pickup_otp, '');
            IF NEW.order_type = 'ride' THEN
                v_title := 'Your Rider has Arrived! 👋';
                v_body := 'Your rider has arrived. Share OTP ' || v_otp || ' with the rider to start your trip.';
            ELSE
                v_title := 'Rider at Pickup Location 📦';
                v_body := 'Your rider has arrived at the pickup location. Share OTP ' || v_otp || ' to start the delivery.';
            END IF;
        ELSIF NEW.order_status = 'picked_up' OR NEW.order_status = 'ongoing' THEN
            v_title := 'Trip on the Way 🗺️';
            v_body := 'Your trip has started. Track your rider''s live location on the map.';
        ELSIF NEW.order_status = 'rider_at_drop' THEN
            v_otp := COALESCE(NEW.delivery_otp, '');
            v_title := 'Rider Reached Drop-off 📍';
            v_body := 'Your rider has reached the drop-off point. Please share OTP ' || v_otp || ' with the receiver to complete the delivery.';
        ELSIF NEW.order_status = 'completed' OR NEW.order_status = 'delivered' THEN
            v_title := 'Order Delivered Successfully 🎉';
            v_body := 'Your order has been completed. Rate your experience and thank the rider!';
        ELSIF NEW.order_status = 'cancelled' THEN
            v_title := 'Order Cancelled ❌';
            v_body := 'Your order has been cancelled.';
        ELSE
            v_title := 'Order Status Update ℹ️';
            v_body := 'There is a new update on your order. Status is now: ' || NEW.order_status;
        END IF;

        -- Send to passenger
        IF v_title != '' AND v_body != '' AND NEW.user_id IS NOT NULL THEN
            PERFORM public.send_push_notification_fnc(
                NEW.user_id,
                v_title,
                v_body,
                jsonb_build_object(
                    'type', 'order_status',
                    'order_id', NEW.id,
                    'status', NEW.order_status
                )
            );
        END IF;

        -- 2. Notify Rider if order was cancelled
        IF NEW.order_status = 'cancelled' AND NEW.rider_id IS NOT NULL THEN
            SELECT user_id INTO v_rider_user_id FROM public.riders WHERE id = NEW.rider_id;
            
            IF v_rider_user_id IS NOT NULL THEN
                PERFORM public.send_push_notification_fnc(
                    v_rider_user_id,
                    'Order Cancelled ❌',
                    'The order you accepted has been cancelled by the customer.',
                    jsonb_build_object(
                        'type', 'order_status',
                        'order_id', NEW.id,
                        'status', 'cancelled'
                    )
                );
            END IF;
        END IF;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- 8. Admin Push Broadcast and City Filtering Function
CREATE OR REPLACE FUNCTION public.send_admin_push_notification(
    p_recipient_type text, -- 'all', 'users', 'riders'
    p_city text,           -- NULL or city name
    p_title text,
    p_body text,
    p_data jsonb DEFAULT '{}'::jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_user_id uuid;
BEGIN
    IF p_recipient_type = 'riders' THEN
        FOR v_user_id IN 
            SELECT DISTINCT r.user_id 
            FROM public.riders r
            WHERE p_city IS NULL OR EXISTS (
                SELECT 1 FROM public.orders o 
                WHERE o.rider_id = r.id AND (o.pickup_city = p_city OR o.destination_city = p_city)
                LIMIT 1
            )
        LOOP
            PERFORM public.send_push_notification_fnc(v_user_id, p_title, p_body, p_data);
        END LOOP;
        
    ELSIF p_recipient_type = 'users' THEN
        FOR v_user_id IN 
            SELECT DISTINCT u.id 
            FROM public.users u
            WHERE (p_city IS NULL OR EXISTS (
                SELECT 1 FROM public.orders o 
                WHERE o.user_id = u.id AND (o.pickup_city = p_city OR o.destination_city = p_city)
                LIMIT 1
            ))
            AND NOT EXISTS (SELECT 1 FROM public.riders r WHERE r.user_id = u.id)
        LOOP
            PERFORM public.send_push_notification_fnc(v_user_id, p_title, p_body, p_data);
        END LOOP;
        
    ELSE
        FOR v_user_id IN 
            SELECT id FROM public.users u
            WHERE p_city IS NULL OR EXISTS (
                SELECT 1 FROM public.orders o 
                WHERE o.user_id = u.id AND (o.pickup_city = p_city OR o.destination_city = p_city)
                LIMIT 1
            )
        LOOP
            PERFORM public.send_push_notification_fnc(v_user_id, p_title, p_body, p_data);
        END LOOP;
    END IF;
END;
$$;
