-- Migration: add a client-supplied idempotency key to public.orders, to let create-order safely
-- de-duplicate a retried "create this order" request.
--
-- P1 FIX 1 (WayDrop P1 pass, create-order idempotency): create-order's client caller
-- (ride_location_screen.dart) has a 30s timeout on the create-order call. On timeout, the
-- client cannot tell whether the order was actually created server-side before it stopped
-- waiting -- a plain client retry in that state risked creating a second, duplicate order for
-- the same booking. The fix threads a client-generated idempotency_key through create-order:
-- a repeated request with the same (user_id, idempotency_key) pair returns the already-created
-- order instead of inserting a second one. See create-order/index.ts and
-- ride_location_screen.dart's _generateBookingIdempotencyKey()/_createOrder() for the two
-- call-site halves of this fix.
--
-- WHY THIS IS SAFE (purely additive, forward-only):
--   1. New column, nullable, no default -- existing rows are entirely unaffected (they simply
--      get NULL), and this is a fast metadata-only ALTER TABLE in Postgres 11+ (no table
--      rewrite, no long lock).
--   2. The uniqueness constraint is a PARTIAL index (`WHERE idempotency_key IS NOT NULL`), not a
--      table-wide UNIQUE constraint -- every OTHER order-creation path in this codebase
--      (intercity booking confirmation, parcel booking, etc.) that never sets this column is
--      completely unaffected: those rows are simply not indexed by it at all, so they can never
--      collide with each other or with ride bookings that do set it.
--   3. Nothing else in the schema (RLS policies, triggers, other migrations) references this
--      column, so no existing behavior changes as a result of adding it.
--   4. Scoped by (user_id, idempotency_key) rather than idempotency_key alone, so even a
--      theoretically-colliding client-generated value from two different users can never be
--      treated as the same booking attempt.

ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS idempotency_key text;

CREATE UNIQUE INDEX IF NOT EXISTS idx_orders_user_idempotency_key
  ON public.orders (user_id, idempotency_key)
  WHERE idempotency_key IS NOT NULL;
