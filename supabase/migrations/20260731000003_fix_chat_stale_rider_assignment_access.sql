-- =====================================================================
-- P0 FIX: order_chat_messages SELECT/INSERT policies granted chat access to
-- ANY rider who was ever offered an order via rider_assignments -- rejected,
-- expired, lost the accept race, or later replaced -- forever, since
-- rider_assignments rows are only ever status-updated (sent/viewed/accepted/
-- rejected/timed_out/expired/cancelled), never deleted.
-- =====================================================================
-- ROOT CAUSE (20260726000000_fix_chat_message_rider_assignment_order_scope.sql,
-- still the live definition -- confirmed no later migration redefines these
-- two policies):
--   r.id IN (SELECT ra.rider_id FROM public.rider_assignments ra
--            WHERE ra.order_id = order_chat_messages.order_id)
-- has no assignment_status filter, so a rider who was merely broadcast the
-- order (assignment_status='sent'/'rejected'/'expired'/'cancelled') matches
-- this clause exactly the same as the rider who actually holds it.
--
-- FIX: restrict the clause to assignment_status = 'accepted' -- the only
-- status that means "this rider currently holds (or has held, for chat
-- history purposes tied to a real acceptance event) this assignment", per
-- assignment_status_enum ('sent','viewed','accepted','rejected','timed_out',
-- 'expired','cancelled'). The `r.id IN (SELECT o.rider_id FROM orders o
-- WHERE o.id = order_chat_messages.order_id)` clause (unaffected, untouched)
-- remains the primary/authoritative "is this the CURRENTLY assigned rider"
-- check via orders.rider_id -- this migration only tightens the secondary
-- rider_assignments-based clause to match its original intent.
-- =====================================================================

DROP POLICY IF EXISTS "Allow chat participants to view messages" ON public.order_chat_messages;

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
                WHERE o.id = order_chat_messages.order_id AND o.user_id = auth.uid()
            )
            OR
            EXISTS (
                SELECT 1 FROM public.riders r
                WHERE r.user_id = auth.uid() AND (
                    r.id = order_chat_messages.rider_id
                    OR
                    r.id IN (SELECT o.rider_id FROM public.orders o WHERE o.id = order_chat_messages.order_id)
                    OR
                    r.id IN (
                        SELECT ra.rider_id FROM public.rider_assignments ra
                        WHERE ra.order_id = order_chat_messages.order_id
                          AND ra.assignment_status = 'accepted'
                    )
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
                WHERE o.id = order_chat_messages.order_id AND o.user_id = auth.uid()
            )
            OR
            EXISTS (
                SELECT 1 FROM public.riders r
                WHERE r.user_id = auth.uid() AND (
                    r.id = order_chat_messages.rider_id
                    OR
                    r.id IN (SELECT o.rider_id FROM public.orders o WHERE o.id = order_chat_messages.order_id)
                    OR
                    r.id IN (
                        SELECT ra.rider_id FROM public.rider_assignments ra
                        WHERE ra.order_id = order_chat_messages.order_id
                          AND ra.assignment_status = 'accepted'
                    )
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
