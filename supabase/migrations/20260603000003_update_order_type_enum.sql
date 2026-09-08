-- =====================================================================
-- Migration: Update order_type_enum values
-- Date: 2026-06-10
-- Description: Recreates the order_type_enum with the new set of values,
--              migrating existing orders' data to prevent cast failures.
-- =====================================================================

-- 1. Temporarily alter orders.order_type column to TEXT to release type dependency
ALTER TABLE public.orders ALTER COLUMN order_type TYPE text;

-- 2. Migrate any legacy/deprecated values to the closest new equivalent
UPDATE public.orders SET order_type = 'local_parcel' WHERE order_type = 'parcel';

-- 3. Drop the old enum type (using CASCADE to clean up any dependent objects)
DROP TYPE IF EXISTS public.order_type_enum CASCADE;

-- 4. Create the new updated enum type with the requested values
CREATE TYPE public.order_type_enum AS ENUM (
    'ride',
    'intercity_ride',
    'ride_sharing',
    'local_parcel',
    'intercity_parcel',
    'batch_delivery',
    'food_delivery',
    'grocery_delivery'
);

-- 5. Alter the orders.order_type column back to the new enum type
ALTER TABLE public.orders 
    ALTER COLUMN order_type TYPE public.order_type_enum 
    USING order_type::public.order_type_enum;
