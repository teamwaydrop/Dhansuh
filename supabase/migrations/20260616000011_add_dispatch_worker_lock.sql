-- Migration: Add dispatch worker lock to orders table
-- Date: 2026-06-16

ALTER TABLE public.orders
ADD COLUMN IF NOT EXISTS dispatch_worker_running boolean DEFAULT false,
ADD COLUMN IF NOT EXISTS dispatch_worker_started_at timestamp with time zone;
