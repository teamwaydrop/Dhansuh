-- LOCAL REVIEW CANDIDATE ONLY. No production migration has been applied.
-- Complements (does not replace) the existing participant authorization policy.
-- Current local Flutter no longer impersonates a system agent for its greeting.
CREATE POLICY chat_insert_requires_authenticated_sender
ON public.order_chat_messages AS RESTRICTIVE
FOR INSERT TO authenticated
WITH CHECK (sender_id = (SELECT auth.uid()));
-- The old order-less branch also allowed a self-authored message addressed to
-- any other user's support thread. Preserve self support and authenticated agents.
CREATE POLICY chat_support_insert_requires_owner_or_agent
ON public.order_chat_messages AS RESTRICTIVE
FOR INSERT TO authenticated
WITH CHECK (
  order_id IS NOT NULL
  OR user_id = (SELECT auth.uid())
  OR EXISTS (
    SELECT 1 FROM public.users
    WHERE id = (SELECT auth.uid()) AND role IN ('admin', 'support')
  )
);
-- Rollback, if this exact policy was subsequently approved and installed:
-- DROP POLICY chat_insert_requires_authenticated_sender ON public.order_chat_messages;
-- DROP POLICY chat_support_insert_requires_owner_or_agent ON public.order_chat_messages;
