-- Migration: Index order_chat_messages(order_id) to eliminate a sequential scan on every chat load.
-- Date: 2026-08-01
--
-- ROOT CAUSE (WayDrop Progressive Degradation Audit, finding DB-1): order_chat_messages
-- (20260601000008_create_order_chat_messages.sql) has never had any index beyond its primary key.
-- Every chat screen open queries `WHERE order_id = ?`, and the RLS SELECT policy
-- (20260726000000_fix_chat_message_rider_assignment_order_scope.sql) evaluates up to three nested
-- EXISTS subqueries per candidate row before admitting it -- both of which currently require a
-- full sequential scan of the entire table (never archived/partitioned, growing with every message
-- ever sent across every order) instead of narrowing to the handful of rows for one order first.
--
-- Fix: add a covering index on (order_id, created_at) -- order_id because that's the only column
-- ever equality-filtered on by both the app's queries and the RLS policy's outer row, created_at
-- because chat is always read in chronological order for a single thread. This is a pure index
-- addition -- no RLS policy, trigger, or application logic changes. Result set and row visibility
-- are unaffected; only the query plan (index scan instead of seq scan) changes.
CREATE INDEX IF NOT EXISTS idx_order_chat_messages_order_id_created_at
    ON public.order_chat_messages (order_id, created_at);
