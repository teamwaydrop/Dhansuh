-- Migration: Index rider_reviews(rider_id, rated_by) and (user_id, rated_by) to fix statement
-- timeouts on review submission.
-- Date: 2026-08-01
--
-- ROOT CAUSE (WayDrop Progressive Degradation Audit, finding DB-2 -- highest confidence finding in
-- the audit): rider_reviews (20260531000004_rider_ratings.sql) carries only a primary key and a
-- UNIQUE(order_id, rated_by) constraint. Two AFTER INSERT OR UPDATE OR DELETE triggers on this
-- table -- update_rider_average_rating() and update_user_average_rating()
-- (20260717000007_intercity_bidirectional_ratings.sql) -- each run a synchronous, non-incremental
-- aggregate (SUM/COUNT) over the entire review history for one rider/user, filtered by
-- `WHERE rider_id = ... AND rated_by = 'user'` and `WHERE user_id = ... AND rated_by = 'rider'`
-- respectively, inside the very transaction that inserts the new review. Neither filter column is
-- indexed, so every review submission forces a full sequential scan of the table before it can
-- commit -- this is the direct, mechanical cause of the reported Postgres 57014
-- ("canceling statement due to statement timeout") on review submission, and it gets worse the
-- more reviews accumulate for an active rider or frequent passenger.
--
-- Fix: two composite indexes matching the exact filters both trigger functions already use,
-- with `rating` included so the SUM/COUNT aggregates can be satisfied by an index-only scan
-- without a heap fetch per row. This is a pure index addition -- the trigger functions, the
-- Bayesian-average formula, and the resulting `rating`/`total_ratings` values are completely
-- unchanged; only the query plan (index range scan instead of full table seq scan) changes.
CREATE INDEX IF NOT EXISTS idx_rider_reviews_rider_id_rated_by
    ON public.rider_reviews (rider_id, rated_by) INCLUDE (rating);

CREATE INDEX IF NOT EXISTS idx_rider_reviews_user_id_rated_by
    ON public.rider_reviews (user_id, rated_by) INCLUDE (rating);
