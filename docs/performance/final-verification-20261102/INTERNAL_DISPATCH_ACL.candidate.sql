-- LOCAL REVIEW CANDIDATE ONLY. Never executed against production.
-- Trigger/pg_net service-role calls remain valid. No Flutter direct caller found.
REVOKE EXECUTE ON FUNCTION public.assign_new_order_to_nearby_online_riders_core(uuid)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.assign_new_order_to_nearby_online_riders_core(uuid)
TO service_role;
-- Rollback must restore an independently captured exact pre-change ACL.
-- Do not guess a blanket GRANT TO PUBLIC or undo other security changes.
