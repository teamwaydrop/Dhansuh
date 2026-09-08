-- =====================================================================
-- Migration: Negotiation Chat Messages Table for Intercity Orders
-- Date: 2026-06-01
-- Description: Creates the order_chat_messages table, adds RLS policies, 
--              and enables real-time replication.
-- =====================================================================

CREATE TABLE IF NOT EXISTS public.order_chat_messages (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    order_id UUID NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
    rider_id UUID NOT NULL REFERENCES public.riders(id) ON DELETE CASCADE,
    sender_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    sender_type TEXT NOT NULL CHECK (sender_type IN ('user', 'rider')),
    message TEXT NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL
);

-- Enable Row Level Security (RLS)
ALTER TABLE public.order_chat_messages ENABLE ROW LEVEL SECURITY;

-- Drop existing policies if any
DROP POLICY IF EXISTS "Allow chat participants to read/write" ON public.order_chat_messages;

-- Create policy allowing participants (order's customer or rider) to view and send messages
CREATE POLICY "Allow chat participants to read/write" ON public.order_chat_messages
FOR ALL TO authenticated
USING (
    -- Customer check: auth.uid() is the creator of the order
    EXISTS (
        SELECT 1 FROM public.orders o
        WHERE o.id = order_id AND o.user_id = auth.uid()
    )
    OR
    -- Rider check: auth.uid() is the user of the matched/assigned rider
    EXISTS (
        SELECT 1 FROM public.riders r
        WHERE r.id = rider_id AND r.user_id = auth.uid()
    )
);

-- Enable real-time replication on the table
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'public' AND tablename = 'order_chat_messages') THEN
        IF NOT EXISTS (
            SELECT 1 FROM pg_publication_tables 
            WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'order_chat_messages'
        ) THEN
            ALTER PUBLICATION supabase_realtime ADD TABLE public.order_chat_messages;
        END IF;
        ALTER TABLE public.order_chat_messages REPLICA IDENTITY FULL;
    END IF;
END$$;
