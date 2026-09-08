-- Add order_notification_mode preference column to public.users table
ALTER TABLE public.users 
ADD COLUMN IF NOT EXISTS order_notification_mode text 
NOT NULL 
DEFAULT 'important_only'
CHECK (order_notification_mode IN ('all', 'important_only', 'tracking_silent'));

-- Create Notifications Log Table for history & unread tracking
CREATE TABLE IF NOT EXISTS public.notifications (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    title text NOT NULL,
    body text NOT NULL,
    notification_type text NOT NULL,
    reference_id uuid,
    reference_type text,
    is_read boolean NOT NULL DEFAULT false,
    push_sent boolean NOT NULL DEFAULT false,
    delivery_status text NOT NULL DEFAULT 'pending',
    delivery_error text,
    payload jsonb NOT NULL DEFAULT '{}',
    created_at timestamptz NOT NULL DEFAULT now(),
    read_at timestamptz
);

-- Enable RLS
ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;

-- RLS Policies
DROP POLICY IF EXISTS "Users can view their own notifications" ON public.notifications;
CREATE POLICY "Users can view their own notifications"
    ON public.notifications
    FOR SELECT
    USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can update their own notifications" ON public.notifications;
CREATE POLICY "Users can update their own notifications"
    ON public.notifications
    FOR UPDATE
    USING (auth.uid() = user_id)
    WITH CHECK (auth.uid() = user_id);

-- Permissions
GRANT ALL ON public.notifications TO service_role;
GRANT SELECT, UPDATE ON public.notifications TO authenticated;

-- Helper function to perform HTTP POST to Deno Edge function asynchronously via pg_net
CREATE OR REPLACE FUNCTION public.deliver_push_notification_http_fnc(
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
    RAISE WARNING 'Failed to send push notification HTTP call: %', SQLERRM;
END;
$$;

-- Redefine send_push_notification_fnc to log inside notifications table
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
DECLARE
    v_notification_type text := COALESCE(p_data->>'type', 'general');
    v_reference_id uuid := NULL;
    v_reference_type text := NULL;
BEGIN
    -- Extract reference info if present
    IF p_data ? 'order_id' THEN
        BEGIN
            v_reference_id := (p_data->>'order_id')::uuid;
            v_reference_type := 'order';
        EXCEPTION WHEN OTHERS THEN
            -- Ignore formatting errors
        END;
    ELSIF p_data ? 'payment_id' THEN
        BEGIN
            v_reference_id := (p_data->>'payment_id')::uuid;
            v_reference_type := 'payment';
        EXCEPTION WHEN OTHERS THEN
            -- Ignore formatting errors
        END;
    END IF;

    -- Insert into notifications log table (which triggers async HTTP delivery)
    INSERT INTO public.notifications (
        user_id,
        title,
        body,
        notification_type,
        reference_id,
        reference_type,
        payload
    ) VALUES (
        p_user_id,
        p_title,
        p_body,
        v_notification_type,
        v_reference_id,
        v_reference_type,
        p_data
    );
END;
$$;

-- Trigger function for public.notifications insert
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
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Bind trigger to notifications table
DROP TRIGGER IF EXISTS trigger_notification_insert ON public.notifications;
CREATE TRIGGER trigger_notification_insert
AFTER INSERT ON public.notifications
FOR EACH ROW
EXECUTE FUNCTION public.on_notification_insert();
