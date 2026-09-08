-- Migration: Introduce an explicit Partner Service Mode on the existing riders table.
-- Date: 2026-07-18
--
-- Root cause being fixed: today every partner (rider) receives BOTH Local
-- Ride/Parcel dispatch AND Intercity Travel (Travel Plans / Travel Together /
-- Intercity Parcel) requests, because no layer of the stack (DB, RLS, edge
-- functions, Flutter) has any concept of which service a partner has chosen
-- to do. This migration adds the single source of truth for that concept,
-- reusing the existing `riders` row rather than introducing a duplicate
-- partner table.
--
-- Design:
--   - `service_mode` is nullable with NO default. Existing rows land as
--     NULL after this migration, which deliberately means "not yet chosen"
--     rather than being silently guessed at (no auto-classification from
--     history, no admin approval — every partner picks their own mode from
--     Profile/Settings, per product decision). NULL fails every downstream
--     `service_mode = 'local'` / `= 'intercity'` equality filter, so an
--     unset partner is safely excluded from BOTH matching pools until they
--     choose.
--   - The enum is intentionally small today (local, intercity) but is
--     designed to grow via `ALTER TYPE ... ADD VALUE` for future service
--     types (food delivery, truck logistics, courier, airport shuttle)
--     without any redesign of this table or a new join table.

CREATE TYPE public.partner_service_mode_enum AS ENUM ('local', 'intercity');

ALTER TABLE public.riders
    ADD COLUMN service_mode public.partner_service_mode_enum;

COMMENT ON COLUMN public.riders.service_mode IS
    'Partner-selected service mode (local ride/parcel vs intercity traveller). NULL = not yet chosen; excluded from all dispatch/matching until set. Self-service only, changed from Profile/Settings.';

-- Partial index matching the hot-path dispatch filter (online riders queried by mode).
CREATE INDEX idx_riders_service_mode
    ON public.riders (service_mode)
    WHERE account_status = 'online';
