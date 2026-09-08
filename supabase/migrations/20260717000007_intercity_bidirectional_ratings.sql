-- Migration: Bidirectional ratings for Intercity Travel Matching (Part 22)
-- Date: 2026-07-17
--
-- rider_reviews (20260531000004_rider_ratings.sql) only ever recorded a passenger rating a rider
-- (UNIQUE(order_id), one row per order, always {rider_id, user_id, rating} meaning "user_id's
-- opinion of rider_id"). The Travel Together spec requires the Partner to also rate the User after
-- a trip, and for a User Card to show the passenger's own rating/review count — neither direction
-- nor those columns existed. Rather than a second review table, this extends the existing one:
-- a rated_by column distinguishes "user rates rider" (existing behavior, default, unchanged) from
-- "rider rates user" (new), and the unique constraint widens to (order_id, rated_by) so both
-- directions can coexist for the same order. public.users gains the rating/total_ratings columns
-- rider_reviews already established the pattern for on public.riders.

-- 1. Add rated_by direction column
ALTER TABLE public.rider_reviews
    ADD COLUMN IF NOT EXISTS rated_by text NOT NULL DEFAULT 'user' CHECK (rated_by IN ('user', 'rider'));

-- 2. Widen the per-order uniqueness so one review per direction per order is allowed
ALTER TABLE public.rider_reviews
    DROP CONSTRAINT IF EXISTS uq_rider_reviews_order;

ALTER TABLE public.rider_reviews
    ADD CONSTRAINT uq_rider_reviews_order_direction UNIQUE (order_id, rated_by);

-- 3. Tighten the existing user-side insert policy to explicitly require rated_by='user'
-- (previously it only checked auth.uid() = user_id, which no longer disambiguates direction).
DROP POLICY IF EXISTS "Users can insert reviews for their own orders" ON public.rider_reviews;

CREATE POLICY "Users can insert reviews for their own orders"
ON public.rider_reviews FOR INSERT
TO authenticated
WITH CHECK (
    rated_by = 'user'
    AND auth.uid() = user_id
);

-- 4. New insert policy: a rider may rate the passenger on their own completed order
DROP POLICY IF EXISTS "Riders can insert reviews for their own orders" ON public.rider_reviews;

CREATE POLICY "Riders can insert reviews for their own orders"
ON public.rider_reviews FOR INSERT
TO authenticated
WITH CHECK (
    rated_by = 'rider'
    AND rider_id IN (SELECT id FROM public.riders WHERE user_id = auth.uid())
    AND EXISTS (
        SELECT 1 FROM public.orders o
        WHERE o.id = order_id
          AND o.rider_id = rider_reviews.rider_id
          AND o.user_id = rider_reviews.user_id
    )
);

-- 5. Re-scope the existing average-rating trigger to only fold rated_by='user' rows into
-- riders.rating (unchanged behavior/values for all existing data).
CREATE OR REPLACE FUNCTION public.update_rider_average_rating()
RETURNS TRIGGER AS $$
DECLARE
  v_rider_id UUID;
  v_rated_by TEXT;
BEGIN
  IF TG_OP = 'DELETE' THEN
    v_rider_id := OLD.rider_id;
    v_rated_by := OLD.rated_by;
  ELSE
    v_rider_id := NEW.rider_id;
    v_rated_by := NEW.rated_by;
  END IF;

  IF v_rated_by IS DISTINCT FROM 'user' THEN
    RETURN NULL;
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
      AND rated_by = 'user'
  )
  WHERE id = v_rider_id;

  RETURN NULL;
END;
$$ LANGUAGE plpgsql;

-- 6. public.users rating/review-count columns (mirrors public.riders.rating)
ALTER TABLE public.users
    ADD COLUMN IF NOT EXISTS rating numeric DEFAULT 5,
    ADD COLUMN IF NOT EXISTS total_ratings integer DEFAULT 0;

-- 7. New trigger: fold rated_by='rider' rows into the rated user's users.rating/total_ratings,
-- using the exact same Bayesian-average formula as update_rider_average_rating() for consistency.
CREATE OR REPLACE FUNCTION public.update_user_average_rating()
RETURNS TRIGGER AS $$
DECLARE
  v_user_id UUID;
  v_rated_by TEXT;
BEGIN
  IF TG_OP = 'DELETE' THEN
    v_user_id := OLD.user_id;
    v_rated_by := OLD.rated_by;
  ELSE
    v_user_id := NEW.user_id;
    v_rated_by := NEW.rated_by;
  END IF;

  IF v_rated_by IS DISTINCT FROM 'rider' THEN
    RETURN NULL;
  END IF;

  UPDATE public.users
  SET rating = (
        SELECT GREATEST(
          ROUND(
            (SUM(rating) + 25.0)::numeric / (COUNT(rating) + 5),
            2
          ),
          3.5
        )
        FROM public.rider_reviews
        WHERE user_id = v_user_id
          AND rated_by = 'rider'
      ),
      total_ratings = (
        SELECT COUNT(*)
        FROM public.rider_reviews
        WHERE user_id = v_user_id
          AND rated_by = 'rider'
      )
  WHERE id = v_user_id;

  RETURN NULL;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS tr_update_user_average_rating ON public.rider_reviews;

CREATE TRIGGER tr_update_user_average_rating
AFTER INSERT OR UPDATE OR DELETE ON public.rider_reviews
FOR EACH ROW
EXECUTE FUNCTION public.update_user_average_rating();
