-- Fix: same live/migration drift pattern found and fixed for send_push_notification_fnc
-- (20260718000002) and intercity_requests (20260718000003) — this time on
-- public.order_chat_messages, found during the full-schema policy audit for this release.
--
-- 20260716000003_restrict_chat_message_edit_delete_to_sender.sql intended to split the single
-- "Allow chat participants to read/write" FOR ALL policy (20260601000009) into four (SELECT/INSERT
-- unchanged, UPDATE/DELETE newly restricted to the message's own sender or admin/support), so one
-- side of a chat could no longer edit or delete a message sent by the other party. Confirmed via
-- pg_policy that the live database still only has the original single FOR ALL policy — the split
-- never took effect, so this gap is still open in production today.
--
-- In scope for this release specifically because order_chat_messages is the same chat used by the
-- Travel Together negotiation flow (proposal/offer messages, the "[AGREED] ..." system message on
-- Accept) that this release's verification pass explicitly covers. Confirmed zero regression risk
-- by grepping every order_chat_messages call site in lib/: the app only ever INSERTs and SELECTs
-- this table — there is no .update( or .delete( call anywhere — so narrowing UPDATE/DELETE cannot
-- break any current flow.

DROP POLICY IF EXISTS "Allow chat participants to read/write" ON public.order_chat_messages;

-- 1. SELECT: unchanged participant visibility.
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
DROP POLICY IF EXISTS "Allow chat participants to send messages" ON public.order_chat_messages;
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
DROP POLICY IF EXISTS "Allow sender to update own chat messages" ON public.order_chat_messages;
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
DROP POLICY IF EXISTS "Allow sender to delete own chat messages" ON public.order_chat_messages;
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
