-- Migration: Add dynamic dispatch columns to dispatch_config and dispatch_state to orders
-- Date: 2026-06-12

-- 1. Add fields to dispatch_config
ALTER TABLE public.dispatch_config
ADD COLUMN IF NOT EXISTS round_2_trigger_after_sec integer DEFAULT 300,
ADD COLUMN IF NOT EXISTS round_2_no_riders_trigger_sec integer DEFAULT 60,
ADD COLUMN IF NOT EXISTS round_2_trigger_if_no_riders_sec integer DEFAULT 60,
ADD COLUMN IF NOT EXISTS round_3_trigger_after_sec integer DEFAULT 600;

-- 2. Add dispatch_state to orders table
ALTER TABLE public.orders
ADD COLUMN IF NOT EXISTS dispatch_state jsonb DEFAULT '{}'::jsonb;

-- 3. Set default values for dispatch_config
UPDATE public.dispatch_config
SET
    round_1_radius_km = 3,
    round_1_batch_size = 5,

    round_2_radius_km = 5,
    round_2_batch_size = 8,

    round_3_radius_km = 10,
    round_3_batch_size = 12,

    round_2_trigger_after_sec = 300,
    round_2_no_riders_trigger_sec = 60,
    round_2_trigger_if_no_riders_sec = 60,
    round_3_trigger_after_sec = 600,

    rider_response_timeout_sec = 30,
    max_search_duration_sec = 900;

-- 4. Enable RLS and add public select policy for dispatch_config
ALTER TABLE public.dispatch_config ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Allow public read access to dispatch_config" ON public.dispatch_config;

CREATE POLICY "Allow public read access to dispatch_config"
ON public.dispatch_config
FOR SELECT
TO anon, authenticated
USING (true);
