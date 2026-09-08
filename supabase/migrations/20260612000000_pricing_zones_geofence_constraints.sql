-- Migration: Add geofencing constraints to pricing_zones
-- Date: 2026-06-12

ALTER TABLE public.pricing_zones
ADD CONSTRAINT chk_radius_positive
CHECK (radius_km IS NULL OR radius_km > 0);

ALTER TABLE public.pricing_zones
ADD CONSTRAINT chk_latitude
CHECK (
    center_lat IS NULL OR
    (center_lat >= -90 AND center_lat <= 90)
);

ALTER TABLE public.pricing_zones
ADD CONSTRAINT chk_longitude
CHECK (
    center_lng IS NULL OR
    (center_lng >= -180 AND center_lng <= 180)
);
