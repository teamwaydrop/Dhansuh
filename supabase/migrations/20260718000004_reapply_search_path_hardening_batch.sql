-- Migration: reapply SET search_path = public to 13 SECURITY DEFINER/trigger functions from
-- 20260716000007_harden_security_definer_search_path.sql that never actually took effect live —
-- same drift pattern discovered and fixed for send_push_notification_fnc (20260718000002) and
-- accept_intercity_offer/intercity_requests RLS (20260718000003).
--
-- Found via a full-schema audit comparing every public-schema function's live pg_get_functiondef()
-- output against the last CREATE OR REPLACE for that name across all migration files, then diffing
-- just the function BODY (ignoring header-clause reordering, which pg_get_functiondef always
-- normalizes differently from the original source). All 13 below came back byte-identical in body
-- to their live counterparts once the search_path clause is stripped from both sides — this is a
-- pure hardening no-op, zero logic change, zero behavior change for any currently-working flow:
-- audit_rider_wallets, check_dormant_riders, check_payout_update_limit, get_rider_reliability_stats,
-- handle_order_activity_tracking, handle_rider_status_change, log_rider_withdrawal_event,
-- on_new_chat_message, on_notification_insert, on_rider_assignment_change, on_rider_review_insert,
-- on_rider_wallet_balance_update, send_admin_push_notification.
--
-- Deliberately EXCLUDED from this batch (found stale/missing during the same audit, but out of
-- scope for this release — see PR/report for details):
--   - assign_nearby_searching_orders_to_rider: live body differs by more than search_path (older
--     dispatch-matching logic, missing weight/vehicle-type awareness added later). This directly
--     drives Local City Ride dispatch, which is confirmed working today — upgrading its logic is
--     not required for the Travel Together fix and needs its own dedicated review/test pass.
--   - complete_withdrawal, fail_withdrawal, initiate_withdrawal, handle_promo_usage_changes,
--     validate_and_calculate_promo: live bodies differ by more than search_path in ways not
--     explained by any migration in this repo — unrelated financial/promo subsystems, need
--     dedicated review before touching.
--   - check_otp_lockout, log_otp_attempt, expire_trip_sharing_tokens, get_trip_share_token,
--     check_is_order_passenger_for_intercity, prevent_role_self_escalation: do not exist on the
--     live database at all (their migrations never took effect). Unrelated subsystems (OTP
--     lockout, trip-share links, RBAC) not covered by this session's verified-working list —
--     flagged for a dedicated follow-up rather than created blind here.

CREATE OR REPLACE FUNCTION public.audit_rider_wallets()
RETURNS jsonb AS $$
DECLARE
  v_discrepancy_count integer := 0;
  v_details jsonb;
BEGIN
  -- Find all riders where wallet_balance != sum of wallet_transactions
  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'rider_id', r.id,
    'wallet_balance', r.wallet_balance,
    'ledger_sum', coalesce(sum(t.amount), 0)
  )), '[]'::jsonb)
  INTO v_details
  FROM public.riders r
  LEFT JOIN public.wallet_transactions t ON t.rider_id = r.id
  GROUP BY r.id, r.wallet_balance
  HAVING r.wallet_balance != coalesce(sum(t.amount), 0);

  v_discrepancy_count := jsonb_array_length(v_details);

  -- Log the run results
  INSERT INTO public.wallet_audit_logs (discrepancies_found, details)
  VALUES (v_discrepancy_count, v_details);

  RETURN jsonb_build_object(
    'success', true,
    'discrepancies_found', v_discrepancy_count,
    'details', v_details
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

CREATE OR REPLACE FUNCTION public.check_dormant_riders()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
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

CREATE OR REPLACE FUNCTION public.check_payout_update_limit()
RETURNS TRIGGER AS $$
DECLARE
    v_update_count integer;
BEGIN
    -- Check if it's insert, or if it's update where rider-initiated fields changed
    IF (TG_OP = 'INSERT') OR 
       (TG_OP = 'UPDATE' AND (
           OLD.account_number IS DISTINCT FROM NEW.account_number OR
           OLD.ifsc_code IS DISTINCT FROM NEW.ifsc_code OR
           OLD.upi_vpa IS DISTINCT FROM NEW.upi_vpa OR
           OLD.beneficiary_name IS DISTINCT FROM NEW.beneficiary_name OR
           OLD.beneficiary_phone IS DISTINCT FROM NEW.beneficiary_phone OR
           OLD.beneficiary_email IS DISTINCT FROM NEW.beneficiary_email OR
           OLD.payout_method IS DISTINCT FROM NEW.payout_method
       )) THEN
       
        -- 1. Lock the user row to prevent race conditions on concurrent requests
        PERFORM 1 FROM public.users WHERE id = NEW.user_id FOR UPDATE;

        -- 2. Count updates in the last 7 days (rolling window)
        SELECT COUNT(*) INTO v_update_count
        FROM public.rider_payout_updates_log
        WHERE user_id = NEW.user_id
          AND created_at > now() - INTERVAL '7 days';

        IF v_update_count >= 2 THEN
            RAISE EXCEPTION 'Maximum of 2 payout account updates allowed per week';
        END IF;

        -- 3. Log this update event
        INSERT INTO public.rider_payout_updates_log (user_id)
        VALUES (NEW.user_id);
        
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

CREATE OR REPLACE FUNCTION public.get_rider_reliability_stats(p_rider_id UUID)
RETURNS TABLE (
    reliability_score INT,
    rating NUMERIC,
    completion_rate NUMERIC,
    on_time_rate NUMERIC,
    total_completed BIGINT,
    total_cancelled BIGINT,
    experience_score INT
) AS $$
DECLARE
    v_rating NUMERIC;
    v_completed BIGINT;
    v_cancelled BIGINT;
    v_on_time BIGINT;
    v_completion_rate NUMERIC;
    v_on_time_rate NUMERIC;
    v_experience_score INT;
    v_rating_score NUMERIC;
    v_reliability_score INT;
BEGIN
    -- 1. Get rating (Bayesian rating calculated in riders table)
    SELECT COALESCE(r.rating, 5.0) INTO v_rating FROM public.riders r WHERE r.id = p_rider_id;
    v_rating_score := v_rating * 20.0; -- 5.0 rating -> 100 points

    -- 2. Completed / Cancelled / On-Time counts
    SELECT 
        COUNT(id) FILTER (WHERE order_status IN ('completed', 'delivered')),
        COUNT(id) FILTER (WHERE order_status = 'cancelled'),
        COUNT(id) FILTER (
            WHERE order_status IN ('completed', 'delivered') 
              AND (travel_date IS NULL OR completed_at <= travel_date + INTERVAL '4 hours')
              AND NOT EXISTS (
                  SELECT 1 FROM public.rider_reviews rr 
                  WHERE rr.order_id = orders.id AND 'late_arrival' = ANY(rr.tags)
              )
        )
    INTO v_completed, v_cancelled, v_on_time
    FROM public.orders
    WHERE rider_id = p_rider_id;

    -- 3. Calculate Rates
    IF (v_completed + v_cancelled) > 0 THEN
        v_completion_rate := (v_completed::numeric / (v_completed + v_cancelled)) * 100.0;
    ELSE
        v_completion_rate := 100.0; -- Default for new riders
    END IF;

    IF v_completed > 0 THEN
        v_on_time_rate := (v_on_time::numeric / v_completed) * 100.0;
    ELSE
        v_on_time_rate := 100.0; -- Default for new riders
    END IF;

    -- 4. Experience Score (Piecewise curve)
    IF v_completed = 0 THEN
        v_experience_score := 0;
    ELSIF v_completed < 10 THEN
        v_experience_score := 20;
    ELSIF v_completed < 50 THEN
        v_experience_score := 60;
    ELSIF v_completed < 100 THEN
        v_experience_score := 80;
    ELSE
        v_experience_score := 100;
    END IF;

    -- 5. Calculate final reliability score (40% rating, 40% completion rate, 20% experience)
    v_reliability_score := ROUND((v_rating_score * 0.40) + (v_completion_rate * 0.40) + (v_experience_score * 0.20));

    RETURN QUERY SELECT 
        LEAST(GREATEST(v_reliability_score, 0), 100)::INT,
        v_rating,
        ROUND(v_completion_rate, 2),
        ROUND(v_on_time_rate, 2),
        v_completed,
        v_cancelled,
        v_experience_score;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

CREATE OR REPLACE FUNCTION public.handle_order_activity_tracking()
RETURNS TRIGGER AS $$
DECLARE
  v_trip_time integer := 0;
  v_earnings numeric := 0.0;
  v_date date;
BEGIN
  -- Track changes to completed, delivered, or cancelled status
  IF NEW.order_status IS DISTINCT FROM OLD.order_status THEN
    v_date := (COALESCE(NEW.completed_at, NEW.cancelled_at, now()) AT TIME ZONE 'Asia/Kolkata')::date;
    
    -- Completed / Delivered
    IF NEW.order_status IN ('completed', 'delivered') AND NEW.rider_id IS NOT NULL THEN
      -- Calculate trip time in seconds
      IF NEW.time_taken_seconds IS NOT NULL AND NEW.time_taken_seconds > 0 THEN
        v_trip_time := NEW.time_taken_seconds;
      ELSE
        -- Fallback to difference between completed_at and picked_up_at / accepted_at
        IF NEW.completed_at IS NOT NULL THEN
          v_trip_time := EXTRACT(EPOCH FROM (NEW.completed_at - COALESCE(NEW.picked_up_at, NEW.accepted_at, NEW.created_at)))::integer;
          IF v_trip_time < 0 THEN v_trip_time := 0; END IF;
        END IF;
      END IF;

      v_earnings := COALESCE(NEW.rider_earning, 0.0);

      INSERT INTO public.rider_daily_activity (rider_id, date, active_seconds, completed_orders, earnings)
      VALUES (NEW.rider_id, v_date, v_trip_time, 1, v_earnings)
      ON CONFLICT (rider_id, date) DO UPDATE
      SET active_seconds = rider_daily_activity.active_seconds + v_trip_time,
          completed_orders = rider_daily_activity.completed_orders + 1,
          earnings = rider_daily_activity.earnings + v_earnings,
          updated_at = now();
          
    -- Cancelled
    ELSIF NEW.order_status = 'cancelled' AND NEW.rider_id IS NOT NULL THEN
      INSERT INTO public.rider_daily_activity (rider_id, date, cancelled_orders)
      VALUES (NEW.rider_id, v_date, 1)
      ON CONFLICT (rider_id, date) DO UPDATE
      SET cancelled_orders = rider_daily_activity.cancelled_orders + 1,
          updated_at = now();
    END IF;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

CREATE OR REPLACE FUNCTION public.handle_rider_status_change()
RETURNS TRIGGER AS $$
DECLARE
BEGIN
  -- If account_status is toggled
  IF NEW.account_status IS DISTINCT FROM OLD.account_status THEN
    -- Going online
    IF NEW.account_status = 'online' THEN
      INSERT INTO public.rider_daily_activity (rider_id, date, last_online_toggle_at)
      VALUES (NEW.id, (now() AT TIME ZONE 'Asia/Kolkata')::date, now())
      ON CONFLICT (rider_id, date) DO UPDATE
      SET last_online_toggle_at = now(),
          updated_at = now();
    -- Going offline
    ELSIF NEW.account_status = 'offline' AND OLD.account_status = 'online' THEN
      UPDATE public.rider_daily_activity
      SET online_seconds = online_seconds + EXTRACT(EPOCH FROM (now() - last_online_toggle_at))::integer,
          last_online_toggle_at = NULL,
          updated_at = now()
      WHERE rider_id = NEW.id AND last_online_toggle_at IS NOT NULL;
    END IF;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

CREATE OR REPLACE FUNCTION public.log_rider_withdrawal_event()
RETURNS TRIGGER AS $$
BEGIN
    IF (TG_OP = 'INSERT') THEN
        INSERT INTO public.rider_withdrawal_events (
            withdrawal_id,
            event_type,
            old_status,
            new_status,
            response
        ) VALUES (
            NEW.id,
            'initiated',
            NULL,
            NEW.status,
            NEW.cashfree_response
        );
    ELSIF (TG_OP = 'UPDATE') THEN
        -- Only log if status changed, response metadata changed, or reference id changed
        IF (OLD.status != NEW.status OR OLD.cashfree_response IS DISTINCT FROM NEW.cashfree_response OR OLD.cashfree_reference_id IS DISTINCT FROM NEW.cashfree_reference_id) THEN
            INSERT INTO public.rider_withdrawal_events (
                withdrawal_id,
                event_type,
                old_status,
                new_status,
                response
            ) VALUES (
                NEW.id,
                CASE 
                    WHEN OLD.status != NEW.status THEN 'status_change'
                    ELSE 'metadata_update'
                END,
                OLD.status,
                NEW.status,
                NEW.cashfree_response
            );
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

CREATE OR REPLACE FUNCTION public.on_new_chat_message()
RETURNS TRIGGER AS $$
DECLARE
    v_recipient_user_id uuid := NULL;
    v_customer_user_id uuid := NULL;
    v_rider_user_id uuid := NULL;
    v_order_rider_id uuid := NULL;
    v_sender_name text := 'Someone';
BEGIN
    -- Get sender name if possible
    SELECT COALESCE(full_name, 'Someone') INTO v_sender_name 
    FROM public.users 
    WHERE id = NEW.sender_id;

    IF NEW.order_id IS NOT NULL THEN
        -- Order chat
        SELECT user_id, rider_id INTO v_customer_user_id, v_order_rider_id 
        FROM public.orders 
        WHERE id = NEW.order_id;
        
        -- Get rider's user_id
        IF NEW.rider_id IS NOT NULL THEN
            SELECT user_id INTO v_rider_user_id FROM public.riders WHERE id = NEW.rider_id;
        ELSIF v_order_rider_id IS NOT NULL THEN
            SELECT user_id INTO v_rider_user_id FROM public.riders WHERE id = v_order_rider_id;
        END IF;

        IF NEW.sender_id = v_customer_user_id THEN
            v_recipient_user_id := v_rider_user_id;
        ELSIF NEW.sender_id = v_rider_user_id THEN
            v_recipient_user_id := v_customer_user_id;
        END IF;
    ELSE
        -- Support chat
        IF NEW.user_id IS NOT NULL AND NEW.sender_id != NEW.user_id THEN
            v_recipient_user_id := NEW.user_id;
        END IF;
    END IF;

    -- Send notification if recipient is determined
    IF v_recipient_user_id IS NOT NULL THEN
        PERFORM public.send_push_notification_fnc(
            v_recipient_user_id,
            v_sender_name,
            NEW.message,
            jsonb_build_object(
                'type', 'chat_message',
                'order_id', NEW.order_id,
                'message_id', NEW.id,
                'sender_type', NEW.sender_type
            )
        );
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

CREATE OR REPLACE FUNCTION public.on_notification_insert()
RETURNS TRIGGER AS $$
BEGIN
    -- Call delivery helper to trigger FCM send-push-notification edge function
    PERFORM public.deliver_push_notification_http_fnc(
        NEW.user_id,
        NEW.title,
        NEW.body,
        NEW.payload || jsonb_build_object(
            'notification_id', NEW.id,
            'type', NEW.notification_type,
            'reference_id', NEW.reference_id,
            'reference_type', NEW.reference_type
        )
    );
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

CREATE OR REPLACE FUNCTION public.on_rider_assignment_change()
RETURNS TRIGGER AS $$
DECLARE
    v_rider_user_id uuid := NULL;
BEGIN
    -- Notify when status is set or updated to 'sent'
    IF NEW.assignment_status = 'sent' AND (TG_OP = 'INSERT' OR OLD.assignment_status IS DISTINCT FROM 'sent') THEN
        SELECT user_id INTO v_rider_user_id FROM public.riders WHERE id = NEW.rider_id;

        IF v_rider_user_id IS NOT NULL THEN
            PERFORM public.send_push_notification_fnc(
                v_rider_user_id,
                'New Order Request',
                'You have a new order request nearby!',
                jsonb_build_object(
                    'type', 'order_assignment',
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
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

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
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public;

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
SET search_path = public
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