-- Migration: Replace the two full-history rating aggregations on rider_reviews with true O(1)
-- incremental running totals.
-- Date: 2026-08-01
--
-- ROOT CAUSE (WayDrop Progressive Degradation Audit, finding DB-2 -- the highest-confidence finding
-- in the original audit, and explicitly deferred at implementation time as "a larger, separate
-- change to trigger logic"): update_rider_average_rating() and update_user_average_rating()
-- (20260531000004_rider_ratings.sql, 20260717000007_intercity_bidirectional_ratings.sql) each
-- re-run a full SUM/COUNT aggregate over a rider's or passenger's ENTIRE historical review set,
-- synchronously, inside the same transaction as every new review insert. 20260801000002 already
-- added indexes backing these aggregates, turning the query from a full table seq scan into an
-- index range scan -- a real fix for the previously-reported statement timeout at current review
-- volumes -- but the scan cost still grows linearly with how many reviews a rider/passenger has
-- ever received. This migration removes that remaining growth entirely: every review submission now
-- does a single O(1) row update using pre-tracked running totals, regardless of review history size.
--
-- CORRECTNESS: the Bayesian-average formula, its rounding, and its floor are byte-for-byte
-- unchanged -- GREATEST(ROUND((sum + 25.0) / (count + 5), 2), 3.5). The two new tracking columns
-- (riders.rating_sum, riders.total_ratings, users.rating_sum -- users.total_ratings already exists)
-- are backfilled below from the exact same SUM/COUNT source query the old trigger body ran live, so
-- every existing rider's and user's `rating` value is mathematically guaranteed identical before and
-- after this migration -- this is a pure implementation-strategy change (incremental vs. full
-- recompute), not a business-logic or output-value change.
--
-- ONE SUBTLETY PRESERVED DELIBERATELY: update_user_average_rating()'s original formula had no
-- explicit "zero reviews" branch (unlike update_rider_average_rating(), which has one) -- at zero
-- rows, SUM(rating) is SQL NULL, so the original formula evaluated to NULL and
-- GREATEST(NULL, 3.5) = 3.5 (Postgres's GREATEST/LEAST ignore NULL arguments). A naive incremental
-- rewrite using a NOT NULL rating_sum column defaulting to 0 would instead compute
-- (0 + 25.0) / (0 + 5) = 5.0 at zero reviews -- a real behavior change. The rewritten
-- update_user_average_rating() below has an explicit zero-count branch forcing 3.5, exactly
-- replicating the original's NULL-propagation result rather than "fixing" this pre-existing
-- asymmetry with riders (whose zero-review default is legitimately 5.0, via its own explicit
-- branch). Neither table's zero-review behavior was changed by this migration.

-- =====================================================================
-- 1. New running-total columns (additive only; existing `rating` and `users.total_ratings`
--    columns, their types, and their defaults are untouched).
-- =====================================================================
ALTER TABLE public.riders
    ADD COLUMN IF NOT EXISTS rating_sum numeric NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS total_ratings integer NOT NULL DEFAULT 0;

ALTER TABLE public.users
    ADD COLUMN IF NOT EXISTS rating_sum numeric NOT NULL DEFAULT 0;

-- =====================================================================
-- 2. One-time backfill from existing rider_reviews data -- the only full-history scan this
--    migration performs, and it runs once at migration-apply time, backed by the
--    (rider_id, rated_by) / (user_id, rated_by) indexes added in 20260801000002.
-- =====================================================================
UPDATE public.riders r
SET rating_sum = COALESCE(sub.sum_rating, 0),
    total_ratings = COALESCE(sub.cnt, 0)
FROM (
    SELECT rider_id, SUM(rating) AS sum_rating, COUNT(*) AS cnt
    FROM public.rider_reviews
    WHERE rated_by = 'user'
    GROUP BY rider_id
) sub
WHERE r.id = sub.rider_id;

UPDATE public.users u
SET rating_sum = COALESCE(sub.sum_rating, 0),
    total_ratings = COALESCE(sub.cnt, 0)
FROM (
    SELECT user_id, SUM(rating) AS sum_rating, COUNT(*) AS cnt
    FROM public.rider_reviews
    WHERE rated_by = 'rider'
    GROUP BY user_id
) sub
WHERE u.id = sub.user_id;

-- =====================================================================
-- 3. Incremental trigger bodies. CREATE OR REPLACE keeps the existing trigger names/timing
--    (tr_update_rider_average_rating, tr_update_user_average_rating -- AFTER INSERT OR UPDATE OR
--    DELETE ON rider_reviews) untouched; only what each function computes changes.
-- =====================================================================
CREATE OR REPLACE FUNCTION public.update_rider_average_rating()
RETURNS TRIGGER AS $$
DECLARE
  v_rider_id UUID;
  v_delta_sum numeric := 0;
  v_delta_count integer := 0;
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.rated_by IS DISTINCT FROM 'user' THEN RETURN NULL; END IF;
    v_rider_id := NEW.rider_id;
    v_delta_sum := NEW.rating;
    v_delta_count := 1;
  ELSIF TG_OP = 'DELETE' THEN
    IF OLD.rated_by IS DISTINCT FROM 'user' THEN RETURN NULL; END IF;
    v_rider_id := OLD.rider_id;
    v_delta_sum := -OLD.rating;
    v_delta_count := -1;
  ELSE
    -- UPDATE: nets out OLD's contribution (if it counted) and applies NEW's (if it counts),
    -- matching the original's exclusive dependence on NEW.rider_id for the target row.
    IF OLD.rated_by IS DISTINCT FROM 'user' AND NEW.rated_by IS DISTINCT FROM 'user' THEN
      RETURN NULL;
    END IF;
    v_rider_id := NEW.rider_id;
    IF OLD.rated_by = 'user' THEN
      v_delta_sum := v_delta_sum - OLD.rating;
      v_delta_count := v_delta_count - 1;
    END IF;
    IF NEW.rated_by = 'user' THEN
      v_delta_sum := v_delta_sum + NEW.rating;
      v_delta_count := v_delta_count + 1;
    END IF;
  END IF;

  UPDATE public.riders
  SET rating_sum = COALESCE(rating_sum, 0) + v_delta_sum,
      total_ratings = COALESCE(total_ratings, 0) + v_delta_count,
      rating = CASE
        WHEN (COALESCE(total_ratings, 0) + v_delta_count) > 0 THEN
          GREATEST(
            ROUND((COALESCE(rating_sum, 0) + v_delta_sum + 25.0) / (COALESCE(total_ratings, 0) + v_delta_count + 5), 2),
            3.5
          )
        ELSE 5.0
      END
  WHERE id = v_rider_id;

  RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION public.update_user_average_rating()
RETURNS TRIGGER AS $$
DECLARE
  v_user_id UUID;
  v_delta_sum numeric := 0;
  v_delta_count integer := 0;
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.rated_by IS DISTINCT FROM 'rider' THEN RETURN NULL; END IF;
    v_user_id := NEW.user_id;
    v_delta_sum := NEW.rating;
    v_delta_count := 1;
  ELSIF TG_OP = 'DELETE' THEN
    IF OLD.rated_by IS DISTINCT FROM 'rider' THEN RETURN NULL; END IF;
    v_user_id := OLD.user_id;
    v_delta_sum := -OLD.rating;
    v_delta_count := -1;
  ELSE
    IF OLD.rated_by IS DISTINCT FROM 'rider' AND NEW.rated_by IS DISTINCT FROM 'rider' THEN
      RETURN NULL;
    END IF;
    v_user_id := NEW.user_id;
    IF OLD.rated_by = 'rider' THEN
      v_delta_sum := v_delta_sum - OLD.rating;
      v_delta_count := v_delta_count - 1;
    END IF;
    IF NEW.rated_by = 'rider' THEN
      v_delta_sum := v_delta_sum + NEW.rating;
      v_delta_count := v_delta_count + 1;
    END IF;
  END IF;

  UPDATE public.users
  SET rating_sum = COALESCE(rating_sum, 0) + v_delta_sum,
      total_ratings = COALESCE(total_ratings, 0) + v_delta_count,
      -- No "count = 0 -> 5.0" branch here, deliberately -- see header comment. Zero reviews must
      -- keep resolving to 3.5, exactly matching the original NULL-propagating formula.
      rating = CASE
        WHEN (COALESCE(total_ratings, 0) + v_delta_count) > 0 THEN
          GREATEST(
            ROUND((COALESCE(rating_sum, 0) + v_delta_sum + 25.0) / (COALESCE(total_ratings, 0) + v_delta_count + 5), 2),
            3.5
          )
        ELSE 3.5
      END
  WHERE id = v_user_id;

  RETURN NULL;
END;
$$ LANGUAGE plpgsql;
