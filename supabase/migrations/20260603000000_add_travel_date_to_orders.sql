-- Add travel_date column to the orders table
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS travel_date timestamptz;
