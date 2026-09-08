-- =====================================================================
-- Migration: Post-Ride Rider Ratings & Feedback Reviews
-- Date: 2026-05-31
-- Description: Creates the reviews table, triggers, and restrictive RLS policies
-- =====================================================================

-- 1. Create review_tag enum
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'review_tag') THEN
        CREATE TYPE public.review_tag AS ENUM (
            'clean_vehicle', 
            'polite_behavior', 
            'safe_driving', 
            'on_time', 
            'dirty_vehicle', 
            'rude_behavior', 
            'unsafe_driving', 
            'late_arrival', 
            'other'
        );
    END IF;
END$$;

-- 2. Create rider_reviews table
CREATE TABLE IF NOT EXISTS public.rider_reviews (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    order_id UUID NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
    rider_id UUID NOT NULL REFERENCES public.riders(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    rating INT NOT NULL CHECK (rating >= 1 AND rating <= 5),
    tags public.review_tag[] DEFAULT '{}',
    comment TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL,
    CONSTRAINT uq_rider_reviews_order UNIQUE (order_id)
);

-- 3. Enable RLS and define Policies
ALTER TABLE public.rider_reviews ENABLE ROW LEVEL SECURITY;

-- Drop existing policies if they exist to avoid duplication errors
DROP POLICY IF EXISTS "Users can insert reviews for their own orders" ON public.rider_reviews;
DROP POLICY IF EXISTS "Anyone can view reviews" ON public.rider_reviews;
DROP POLICY IF EXISTS "Users and riders can view reviews" ON public.rider_reviews;

-- Policy 1: Users can insert reviews for their own orders (INSERT-only, no UPDATE/DELETE policies are defined, preventing any modification)
CREATE POLICY "Users can insert reviews for their own orders" 
ON public.rider_reviews FOR INSERT 
TO authenticated
WITH CHECK (
    auth.uid() = user_id
);

-- Policy 2: Only the user who created it or the rated rider can view it (SELECT-only)
CREATE POLICY "Users and riders can view reviews" 
ON public.rider_reviews FOR SELECT 
TO authenticated
USING (
    auth.uid() = user_id OR
    rider_id IN (SELECT id FROM public.riders WHERE user_id = auth.uid())
);

-- 4. Create trigger to automatically update the rider's average rating (normalized via Bayesian Average)
CREATE OR REPLACE FUNCTION public.update_rider_average_rating()
RETURNS TRIGGER AS $$
DECLARE
  v_rider_id UUID;
BEGIN
  IF TG_OP = 'DELETE' THEN
    v_rider_id := OLD.rider_id;
  ELSE
    v_rider_id := NEW.rider_id;
  END IF;

  UPDATE public.riders
  SET rating = (
    SELECT CASE 
      WHEN COUNT(rating) > 0 THEN
        GREATEST(
          ROUND(
            (SUM(rating) + 25.0)::numeric / (COUNT(rating) + 5),
            2
          ),
          3.5
        )
      ELSE 5.0
    END
    FROM public.rider_reviews
    WHERE rider_id = v_rider_id
  )
  WHERE id = v_rider_id;
  
  RETURN NULL;
END;
$$ LANGUAGE plpgsql;

-- Drop trigger if exists to avoid duplication errors
DROP TRIGGER IF EXISTS tr_update_rider_average_rating ON public.rider_reviews;

CREATE TRIGGER tr_update_rider_average_rating
AFTER INSERT OR UPDATE OR DELETE ON public.rider_reviews
FOR EACH ROW
EXECUTE FUNCTION public.update_rider_average_rating();

-- 5. Normalize existing riders' ratings in public.riders using the same Bayesian Average formula
UPDATE public.riders r
SET rating = (
  SELECT CASE 
    WHEN COUNT(rating) > 0 THEN
      GREATEST(
        ROUND(
          (SUM(rating) + 25.0)::numeric / (COUNT(rating) + 5),
          2
        ),
        3.5
      )
    ELSE 5.0
  END
  FROM public.rider_reviews
  WHERE rider_id = r.id
);
