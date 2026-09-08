-- =====================================================================
-- Migration: Create Intercity Requests Table and Expand Chat Schema
-- Date: 2026-06-03
-- Description: Adds a requests table for intercity negotiation flow
--              and adds message_type/metadata to order_chat_messages.
-- =====================================================================

-- 1. Create intercity_requests table
CREATE TABLE IF NOT EXISTS public.intercity_requests (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    parcel_id UUID NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
    route_id UUID REFERENCES public.rider_travel_plans(id) ON DELETE SET NULL,
    traveller_id UUID NOT NULL REFERENCES public.riders(id) ON DELETE CASCADE,
    sender_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    initiated_by TEXT NOT NULL CHECK (initiated_by IN ('traveller', 'sender')),
    status TEXT NOT NULL DEFAULT 'request_sent' CHECK (status IN (
        'request_sent',
        'discussion_started',
        'confirmed',
        'paid',
        'in_progress',
        'completed',
        'cancelled'
    )),
    proposed_fare NUMERIC NOT NULL,
    sender_confirmed BOOLEAN NOT NULL DEFAULT false,
    traveller_confirmed BOOLEAN NOT NULL DEFAULT false,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL
);

-- Enable Row Level Security (RLS)
ALTER TABLE public.intercity_requests ENABLE ROW LEVEL SECURITY;

-- Drop existing policies if any
DROP POLICY IF EXISTS "Allow request participants to read/write" ON public.intercity_requests;

-- Create policy allowing participants (sender or traveller) to view and modify requests
CREATE POLICY "Allow request participants to read/write" ON public.intercity_requests
FOR ALL TO authenticated
USING (
    sender_id = auth.uid()
    OR EXISTS (
        SELECT 1 FROM public.riders r
        WHERE r.id = traveller_id AND r.user_id = auth.uid()
    )
)
WITH CHECK (
    sender_id = auth.uid()
    OR EXISTS (
        SELECT 1 FROM public.riders r
        WHERE r.id = traveller_id AND r.user_id = auth.uid()
    )
);

-- Enable real-time replication for intercity_requests
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'public' AND tablename = 'intercity_requests') THEN
        IF NOT EXISTS (
            SELECT 1 FROM pg_publication_tables 
            WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'intercity_requests'
        ) THEN
            ALTER PUBLICATION supabase_realtime ADD TABLE public.intercity_requests;
        END IF;
        ALTER TABLE public.intercity_requests REPLICA IDENTITY FULL;
    END IF;
END$$;


-- 2. Expand order_chat_messages table for rich types
ALTER TABLE public.order_chat_messages 
ADD COLUMN IF NOT EXISTS message_type TEXT DEFAULT 'text' CHECK (message_type IN ('text', 'offer', 'image', 'location')),
ADD COLUMN IF NOT EXISTS metadata JSONB DEFAULT '{}'::jsonb;


-- 3. Trigger Function to Send Push Notifications on Intercity Request changes
CREATE OR REPLACE FUNCTION public.on_intercity_request_change()
RETURNS TRIGGER AS $$
DECLARE
    v_rider_user_id uuid := NULL;
    v_passenger_user_id uuid := NEW.sender_id;
    v_title text := '';
    v_body text := '';
    v_notify_user_id uuid := NULL;
BEGIN
    -- Fetch the rider's user_id
    SELECT user_id INTO v_rider_user_id FROM public.riders WHERE id = NEW.traveller_id;

    -- A) When a request is INSERTED (request_sent)
    IF TG_OP = 'INSERT' THEN
        IF NEW.initiated_by = 'sender' THEN
            -- Sender is passenger, notify rider (traveller)
            v_notify_user_id := v_rider_user_id;
            v_title := 'New Request Received 📦';
            v_body := 'A passenger wants you to carry their shipment or ride. Open details to discuss!';
        ELSE
            -- Initiator is rider, notify passenger (sender)
            v_notify_user_id := v_passenger_user_id;
            v_title := 'New Offer Received ⚡';
            v_body := 'A traveller offered to carry your shipment or ride. Open details to discuss!';
        END IF;

    -- B) When request is UPDATED and status changes
    ELSIF TG_OP = 'UPDATE' AND OLD.status IS DISTINCT FROM NEW.status THEN
        IF NEW.status = 'discussion_started' THEN
            -- Discussion accepted, notify the initiator of request
            IF NEW.initiated_by = 'sender' THEN
                v_notify_user_id := v_passenger_user_id;
            ELSE
                v_notify_user_id := v_rider_user_id;
            END IF;
            v_title := 'Discussion Opened 💬';
            v_body := 'The conversation has been accepted. You can now chat and negotiate the fare!';
            
        ELSIF NEW.status = 'confirmed' THEN
            -- Notify BOTH (need to send separately, here we notify the one who did NOT trigger the final confirm, or just notify sender that they can pay)
            -- Let's notify passenger (sender) to complete payment
            v_notify_user_id := v_passenger_user_id;
            v_title := 'Booking Confirmed! 🎉';
            v_body := 'Both parties have confirmed the booking. Please proceed to payment.';
            
        ELSIF NEW.status = 'paid' THEN
            -- Passenger paid, notify traveller (rider)
            v_notify_user_id := v_rider_user_id;
            v_title := 'Payment Verified! 💳';
            v_body := 'Passenger has paid for the trip. You can now start the transit.';
            
        ELSIF NEW.status = 'in_progress' THEN
            -- Trip started, notify passenger
            v_notify_user_id := v_passenger_user_id;
            v_title := 'Trip on the Way 🗺️';
            v_body := 'Traveller has collected the parcel/started the ride. Track live updates!';
            
        ELSIF NEW.status = 'completed' THEN
            -- Completed, notify passenger
            v_notify_user_id := v_passenger_user_id;
            v_title := 'Trip Completed Successfully 🎉';
            v_body := 'Your shipment/ride has been delivered. Thank the traveller!';
        END IF;
    END IF;

    -- Send push notification if a target recipient is identified
    IF v_notify_user_id IS NOT NULL THEN
        PERFORM public.send_push_notification_fnc(
            v_notify_user_id,
            v_title,
            v_body,
            jsonb_build_object(
                'type', 'intercity_request',
                'request_id', NEW.id,
                'order_id', NEW.parcel_id,
                'rider_id', NEW.traveller_id,
                'status', NEW.status
            )
        );
    END IF;

    -- In case of final confirmed status, let's also notify the rider (separate call since both need it)
    IF TG_OP = 'UPDATE' AND OLD.status IS DISTINCT FROM NEW.status AND NEW.status = 'confirmed' THEN
        IF v_rider_user_id IS NOT NULL THEN
            PERFORM public.send_push_notification_fnc(
                v_rider_user_id,
                'Booking Confirmed! 🎉',
                'Booking is confirmed by the passenger. Awaiting payment.',
                jsonb_build_object(
                    'type', 'intercity_request',
                    'request_id', NEW.id,
                    'order_id', NEW.parcel_id,
                    'rider_id', NEW.traveller_id,
                    'status', NEW.status
                )
            );
        END IF;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Drop existing trigger if any
DROP TRIGGER IF EXISTS trigger_intercity_request_change ON public.intercity_requests;

-- Create the trigger
CREATE TRIGGER trigger_intercity_request_change
AFTER INSERT OR UPDATE ON public.intercity_requests
FOR EACH ROW
EXECUTE FUNCTION public.on_intercity_request_change();

-- Grant privileges to authenticated and service_role roles
GRANT SELECT, INSERT, UPDATE, DELETE ON public.intercity_requests TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.intercity_requests TO service_role;

