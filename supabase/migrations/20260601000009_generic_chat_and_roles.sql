-- =====================================================================
-- Migration: Generic Chats, Roles & Admin Policies
-- Date: 2026-06-01
-- Description: Adds role column to users, makes chat references nullable,
--              expands sender types, and updates RLS policies for admin access.
-- =====================================================================

-- 1. Safely add role column to public.users if not present
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS role TEXT DEFAULT 'user';

-- 2. Alter order_chat_messages columns to be nullable for support chats
ALTER TABLE public.order_chat_messages ALTER COLUMN order_id DROP NOT NULL;
ALTER TABLE public.order_chat_messages ALTER COLUMN rider_id DROP NOT NULL;
ALTER TABLE public.order_chat_messages ADD COLUMN IF NOT EXISTS is_support BOOLEAN DEFAULT false;
ALTER TABLE public.order_chat_messages ADD COLUMN IF NOT EXISTS user_id UUID REFERENCES public.users(id) ON DELETE CASCADE;

-- 3. Drop and recreate check constraint on sender_type
ALTER TABLE public.order_chat_messages DROP CONSTRAINT IF EXISTS order_chat_messages_sender_type_check;
ALTER TABLE public.order_chat_messages ADD CONSTRAINT order_chat_messages_sender_type_check 
    CHECK (sender_type IN ('user', 'rider', 'admin', 'support'));

-- 4. Drop old RLS policy
DROP POLICY IF EXISTS "Allow chat participants to read/write" ON public.order_chat_messages;

-- 5. Create new RLS policy allowing participants, senders, and admins
CREATE POLICY "Allow chat participants to read/write" ON public.order_chat_messages
FOR ALL TO authenticated
USING (
    -- Admin/Support staff check: authenticated user is admin/support in users table
    EXISTS (
        SELECT 1 FROM public.users 
        WHERE id = auth.uid() AND (role = 'admin' OR role = 'support')
    )
    OR
    -- Sender check: user created the message
    sender_id = auth.uid()
    OR
    -- User check: user is the owner of the support session
    user_id = auth.uid()
    OR
    -- Participant check for order-specific chats
    (
        order_id IS NOT NULL AND (
            EXISTS (
                SELECT 1 FROM public.orders o
                WHERE o.id = order_id AND o.user_id = auth.uid()
            )
            OR
            EXISTS (
                SELECT 1 FROM public.riders r
                WHERE r.user_id = auth.uid() AND (
                    r.id = rider_id 
                    OR 
                    r.id IN (SELECT o.rider_id FROM public.orders o WHERE o.id = order_id)
                    OR
                    r.id IN (SELECT ra.rider_id FROM public.rider_assignments ra WHERE ra.order_id = order_id)
                )
            )
        )
    )
    OR
    -- Participant check for general support chats (order_id is null)
    (
        order_id IS NULL AND (
            sender_id = auth.uid()
            OR
            rider_id IN (SELECT id FROM public.riders WHERE user_id = auth.uid())
        )
    )
);
