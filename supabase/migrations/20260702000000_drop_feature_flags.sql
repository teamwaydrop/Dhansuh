-- =====================================================================
-- Migration: Drop feature_flags table
-- Date: 2026-07-02
-- Description: Drops the public.feature_flags table since remote feature
--              flags are no longer used.
-- =====================================================================

DROP TABLE IF EXISTS public.feature_flags CASCADE;
