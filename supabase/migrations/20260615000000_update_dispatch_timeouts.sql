-- Migration: Update Dispatch timeouts and cooldowns
-- Date: 2026-06-15

-- 1. Add columns if not exists
ALTER TABLE public.dispatch_config
ADD COLUMN IF NOT EXISTS reject_cooldown_sec integer DEFAULT 180,
ADD COLUMN IF NOT EXISTS timeout_cooldown_sec integer DEFAULT 60;

-- 2. Update default values on existing configs
UPDATE public.dispatch_config
SET
    rider_response_timeout_sec = 60,
    reject_cooldown_sec = 180,
    timeout_cooldown_sec = 60;
