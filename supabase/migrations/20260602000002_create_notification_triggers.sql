-- =====================================================================
-- Migration: Push Notification Triggers
-- Date: 2026-06-02
-- Description: Sets up database trigger functions and triggers to invoke
--              the send-push-notification edge function asynchronously
--              via pg_net for key events.
-- =====================================================================

-- 1. Helper function to invoke the edge function via pg_net
CREATE OR REPLACE FUNCTION public.send_push_notification_fnc(
    p_user_id uuid,
    p_title text,
    p_body text,
    p_data jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    PERFORM net.http_post(
        url := 'https://yvwpchffctiagevpqgwy.supabase.co/functions/v1/send-push-notification',
        headers := '{"Content-Type": "application/json", "Authorization": "Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Inl2d3BjaGZmY3RpYWdldnBxZ3d5Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzgxMzQ3NzUsImV4cCI6MjA5MzcxMDc3NX0.y4Shv58UDlTF2BNGsVVy3fWR3O7M2MzjQmHabJAFdCA"}'::jsonb,
        body := jsonb_build_object(
            'user_id', p_user_id,
            'title', p_title,
            'body', p_body,
            'data', p_data
        ),
        timeout_milliseconds := 5000
    );
EXCEPTION WHEN OTHERS THEN
    -- Prevent trigger failure if pg_net has issues
    RAISE WARNING 'Failed to send push notification via pg_net: %', SQLERRM;
END;
$$;

-- 2. Trigger function for order status updates
CREATE OR REPLACE FUNCTION public.on_order_status_update()
RETURNS TRIGGER AS $$
DECLARE
    v_rider_user_id uuid := NULL;
    v_title text := '';
    v_body text := '';
BEGIN
    -- Check if status actually changed
    IF OLD.order_status IS DISTINCT FROM NEW.order_status THEN
        -- 1. Notify Passenger (NEW.user_id) for status updates
        IF NEW.order_status = 'accepted' THEN
            v_title := 'Order Accepted';
            v_body := 'A rider has accepted your order!';
        ELSIF NEW.order_status = 'rider_arrived' THEN
            v_title := 'Rider Arrived';
            v_body := 'Your rider has arrived at the pickup location.';
        ELSIF NEW.order_status = 'picked_up' THEN
            v_title := 'Order Picked Up';
            v_body := 'Your order is on the way!';
        ELSIF NEW.order_status = 'completed' THEN
            v_title := 'Order Completed';
            v_body := 'Your trip has been completed successfully.';
        ELSIF NEW.order_status = 'cancelled' THEN
            v_title := 'Order Cancelled';
            v_body := 'Your order has been cancelled.';
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
                    'Order Cancelled',
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

-- 3. Trigger for order status updates
DROP TRIGGER IF EXISTS trigger_order_status_update ON public.orders;
CREATE TRIGGER trigger_order_status_update
AFTER UPDATE OF order_status ON public.orders
FOR EACH ROW
EXECUTE FUNCTION public.on_order_status_update();


-- 4. Trigger function for new chat messages
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
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 5. Trigger for new chat messages
DROP TRIGGER IF EXISTS trigger_new_chat_message ON public.order_chat_messages;
CREATE TRIGGER trigger_new_chat_message
AFTER INSERT ON public.order_chat_messages
FOR EACH ROW
EXECUTE FUNCTION public.on_new_chat_message();


-- 6. Trigger function for rider assignment updates
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
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 7. Trigger for rider assignment updates
DROP TRIGGER IF EXISTS trigger_rider_assignment_change ON public.rider_assignments;
CREATE TRIGGER trigger_rider_assignment_change
AFTER INSERT OR UPDATE OF assignment_status ON public.rider_assignments
FOR EACH ROW
EXECUTE FUNCTION public.on_rider_assignment_change();
