-- Migration: Add Developer Test Mode flag.
-- Date: 2026-07-24
--
-- Adds users.is_developer, a boolean that lets flagged accounts (or accounts
-- with role = 'admin') bypass service-area restrictions in the client and in
-- calculate-order-pricing, for internal QA/testing of booking flows outside
-- configured pricing_zones. Defaults to false for all existing and new rows,
-- so normal users see no behavior change.
--
-- Like users.role (see 20260716000005_prevent_role_self_escalation.sql),
-- this flag must never be self-grantable: it is intended to be turned on
-- out-of-band via the Supabase dashboard/SQL console (service_role) only.
-- We extend the existing prevent_role_self_escalation trigger function
-- rather than adding a second trigger, since it already fires on every
-- UPDATE of public.users.

ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS is_developer boolean NOT NULL DEFAULT false;

CREATE OR REPLACE FUNCTION public.prevent_role_self_escalation()
RETURNS TRIGGER AS $$
BEGIN
    IF (NEW.role IS DISTINCT FROM OLD.role OR NEW.is_developer IS DISTINCT FROM OLD.is_developer) THEN
        IF auth.role() != 'service_role' THEN
            RAISE EXCEPTION 'Changing the role or is_developer column is not permitted for this session.';
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
