-- Fix: order_chat_messages INSERT policy allowed sending messages to ANY
-- order's chat.
-- Date: 2026-07-16
--
-- The INSERT policy created in 20260716000003_restrict_chat_message_edit_
-- delete_to_sender.sql ("Allow chat participants to send messages") ORs a
-- bare `sender_id = auth.uid() OR user_id = auth.uid()` alongside the real
-- participant checks. Both fields are client-supplied on insert, so any
-- authenticated user can trivially set sender_id/user_id to their own id
-- while pointing order_id/rider_id at someone else's order, satisfying the
-- check regardless of the participant predicate below it. That lets any
-- authenticated user post into any order's chat.
--
-- Fix: for order-specific messages (order_id IS NOT NULL), require genuine
-- participation (order owner or assigned/matched rider) instead of the
-- self-referential bypass. The self bypass is kept only for general support
-- sessions (order_id IS NULL), where it is required for a user to start/
-- continue their own support thread. SELECT/UPDATE/DELETE policies are
-- unchanged.

DROP POLICY IF EXISTS "Allow chat participants to send messages" ON public.order_chat_messages;

CREATE POLICY "Allow chat participants to send messages" ON public.order_chat_messages
FOR INSERT TO authenticated
WITH CHECK (
    EXISTS (
        SELECT 1 FROM public.users
        WHERE id = auth.uid() AND (role = 'admin' OR role = 'support')
    )
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
            user_id = auth.uid()
            OR
            rider_id IN (SELECT id FROM public.riders WHERE user_id = auth.uid())
        )
    )
);
