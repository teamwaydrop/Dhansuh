-- =====================================================================
-- Migration: Add seats_requested to orders
-- Date: 2026-07-17
-- Description: The intercity passenger "Travel Request" flow lets a
--              passenger request more than one seat on a shared intercity
--              ride (e.g. travelling with family). Nothing on `orders`
--              previously recorded how many seats/passengers a request is
--              for. lib/models/transport_order.dart already speculatively
--              parsed json['seats_requested'] (falling back to a
--              non-existent 'capacity' key) with no backing column — this
--              adds the real column so that parsing is no longer dead code.
-- =====================================================================

ALTER TABLE public.orders
    ADD COLUMN IF NOT EXISTS seats_requested integer NOT NULL DEFAULT 1;

COMMENT ON COLUMN public.orders.seats_requested IS
    'Number of passenger seats requested for an intercity_ride Travel Request. Always 1 for non-ride-sharing order types.';
