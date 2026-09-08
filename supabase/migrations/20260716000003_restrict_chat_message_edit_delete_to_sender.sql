-- Migration: Restrict UPDATE/DELETE on order_chat_messages to the sender.
-- Date: 2026-07-16
--
-- The single FOR ALL policy "Allow chat participants to read/write"
-- (20260601000009_generic_chat_and_roles.sql) governs SELECT/INSERT/UPDATE/
-- DELETE with the same "is a participant" predicate, so any participant
-- (passenger or assigned rider) can edit or delete a message sent by the
-- OTHER party in the same chat. This splits the single policy into four:
-- SELECT and INSERT keep the existing broad participant predicate
-- unchanged, while UPDATE and DELETE are newly restricted to the message's
-- own sender (or an admin/support user, preserving existing moderation
-- capability).

DROP POLICY IF EXISTS "Allow chat participants to read/write" ON public.order_chat_messages;

-- 1. SELECT: unchanged participant visibility.
CREATE POLICY "Allow chat participants to view messages" ON public.order_chat_messages
FOR SELECT TO authenticated
USING (
    EXISTS (
        SELECT 1 FROM public.users
        WHERE id = auth.uid() AND (role = 'admin' OR role = 'support')
    )
    OR
    sender_id = auth.uid()
    OR
    user_id = auth.uid()
    OR
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
    (
        order_id IS NULL AND (
            sender_id = auth.uid()
            OR
            rider_id IN (SELECT id FROM public.riders WHERE user_id = auth.uid())
        )
    )
);

-- 2. INSERT: unchanged participant predicate (as WITH CHECK).
CREATE POLICY "Allow chat participants to send messages" ON public.order_chat_messages
FOR INSERT TO authenticated
WITH CHECK (
    EXISTS (
        SELECT 1 FROM public.users
        WHERE id = auth.uid() AND (role = 'admin' OR role = 'support')
    )
    OR
    sender_id = auth.uid()
    OR
    user_id = auth.uid()
    OR
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
    (
        order_id IS NULL AND (
            sender_id = auth.uid()
            OR
            rider_id IN (SELECT id FROM public.riders WHERE user_id = auth.uid())
        )
    )
);

-- 3. UPDATE: restricted to the message's own sender (or admin/support).
CREATE POLICY "Allow sender to update own chat messages" ON public.order_chat_messages
FOR UPDATE TO authenticated
USING (
    sender_id = auth.uid()
    OR
    EXISTS (
        SELECT 1 FROM public.users
        WHERE id = auth.uid() AND (role = 'admin' OR role = 'support')
    )
)
WITH CHECK (
    sender_id = auth.uid()
    OR
    EXISTS (
        SELECT 1 FROM public.users
        WHERE id = auth.uid() AND (role = 'admin' OR role = 'support')
    )
);

-- 4. DELETE: restricted to the message's own sender (or admin/support).
CREATE POLICY "Allow sender to delete own chat messages" ON public.order_chat_messages
FOR DELETE TO authenticated
USING (
    sender_id = auth.uid()
    OR
    EXISTS (
        SELECT 1 FROM public.users
        WHERE id = auth.uid() AND (role = 'admin' OR role = 'support')
    )
);
