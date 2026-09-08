-- Migration: Recreate payment_for_enum with additional boost and order types
-- Date: 2026-06-12

-- 1. Temporarily change columns using payment_for_enum to text
ALTER TABLE public.payments ALTER COLUMN payment_for TYPE text;

-- 2. Drop the existing type
DROP TYPE IF EXISTS public.payment_for_enum;

-- 3. Create the new enum type
CREATE TYPE public.payment_for_enum AS ENUM (
  'ride_order',
  'parcel_order',
  'wallet_topup',
  'subscription',
  'withdrawal',
  'refund',
  'cod_settlement',
  'ride_boost',
  'intercity_ride_boost',
  'intercity_parcel_boost',
  'intercity_ride_order',
  'intercity_parcel_order',
  'ride_sharing'
);

-- 4. Cast the payments column back to the new enum type
ALTER TABLE public.payments ALTER COLUMN payment_for TYPE public.payment_for_enum USING payment_for::public.payment_for_enum;
