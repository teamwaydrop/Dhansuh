-- Fix two compounding RLS bugs on order_chat_messages that together remove the database-level
-- guarantee that a chat thread is scoped to a single order. Both are currently live (this
-- migration runs after every prior chat-RLS migration, so its predecessor's CREATE POLICY
-- bodies are what's actually in effect today).
--
-- Bug A -- rider_assignments subquery tautology (SELECT + INSERT):
--     r.id IN (SELECT ra.rider_id FROM public.rider_assignments ra WHERE ra.order_id = order_id)
-- The bare `order_id` inside that subquery is ambiguous -- rider_assignments itself has an
-- order_id column, and Postgres resolves an unqualified column name to the innermost scope
-- that has it. So this compiles to `ra.order_id = ra.order_id`, a tautology that is always
-- true, instead of the intended `ra.order_id = order_chat_messages.order_id`. Confirmed via the
-- compiled policy in the schema dump (supabase/migrations_baseline_wip/prod_schema_dump.sql),
-- which shows literally "ra.order_id = ra.order_id". Impact: any rider who has ever had a
-- rider_assignments row for *any* order (i.e. was ever offered/considered for a dispatch,
-- accepted or not) satisfies this clause for every order's chat, not just their own.
--
-- Bug B -- INSERT bare sender_id/user_id bypass reintroduced (INSERT only, more severe):
-- 20260716000012_restrict_chat_message_insert_to_participants.sql removed a bare
-- `sender_id = auth.uid() OR user_id = auth.uid()` OR-clause from the INSERT policy's WITH
-- CHECK specifically because, as its own comment documents, both fields are client-supplied on
-- insert, so it let any authenticated user post into ANY order's chat by setting sender_id/
-- user_id to their own id while pointing order_id/rider_id at someone else's order. Two days
-- later, 20260718000005_apply_chat_message_edit_delete_restriction.sql reapplied the SELECT/
-- INSERT/UPDATE/DELETE split "because the live database still only had the original single FOR
-- ALL policy" (the 20260716000003 split had never actually run) -- but it recreated the INSERT
-- policy from 20260716000003's pre-fix text, silently reverting the 20260716000012 fix. The
-- bare bypass is live in the INSERT policy today (confirmed by reading that file directly:
-- `sender_id = auth.uid()` / `user_id = auth.uid()` appear before the `order_id IS NOT NULL`
-- participant check). This is the more serious of the two: it is a currently-active hole that
-- lets any authenticated user (passenger or rider) write a message into any other order's
-- chat_messages row outright, regardless of participation.
--
-- Neither bug is exploited by this app's own client code today (it always sends/queries with
-- the current screen's real order_id), which is why this hasn't surfaced as messages visibly
-- leaking between rides in normal use -- but it means order isolation currently rests entirely
-- on client behavior being correct, not on the database enforcing it, which is exactly the
-- "don't trust a client-supplied id if identity can be enforced server-side" gap flagged for
-- audit. Fixing both here closes that gap for real.
--
-- Fix: qualify the rider_assignments subquery's outer reference against the policy's own table
-- (Bug A), and drop the bare sender_id/user_id bypass from the order-scoped INSERT branch again
-- (Bug B), restoring 20260716000012's intent. UPDATE/DELETE policies are untouched -- they
-- never referenced rider_assignments or carried this bypass.

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
