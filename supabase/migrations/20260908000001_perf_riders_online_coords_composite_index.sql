-- =============================================================================
-- PERF (slowdown-after-a-few-rides investigation, 2026-09-08) — Phase 1, item 1
--
-- Replace the two single-column btree indexes on riders.current_lat and
-- riders.current_lng with ONE composite PARTIAL index scoped to online riders.
--
-- WHY:
--   * The only place a lat/lng RANGE predicate is used against `riders` is the
--     booking-screen "nearby riders on the map" bounding-box query
--     (lib/features/local_rides/booking/screens/ride_location_screen.dart and
--     lib/features/local_parcels/booking/screens/parcel_booking_screen.dart):
--         .eq('account_status','online')
--         .gte/.lte('current_lat', ...) .gte/.lte('current_lng', ...)
--     find_nearby_riders() uses idx_riders_location_updated, and
--     redispatch_freed_riders() seq-scans the (tiny) riders table — neither
--     touches these two indexes. (EXPLAIN-verified 2026-09-08.)
--   * Two separate single-column float indexes cannot serve a 2-D range
--     efficiently anyway — the planner picks one and filters the other.
--   * BOTH must be maintained on every rider GPS write (~1 write / 10 s per
--     online rider) even though only ONLINE riders are ever queried this way.
--
-- EFFECT:
--   * The bounding-box query gets a single, better-matched composite index.
--   * GPS writes maintain one online-scoped index instead of two global ones.
--   * No behaviour change: identical rider set is returned to the app.
--
-- REVERSIBLE: recreate the two dropped indexes:
--   CREATE INDEX idx_riders_current_lat ON public.riders USING btree (current_lat);
--   CREATE INDEX idx_riders_current_lng ON public.riders USING btree (current_lng);
--   DROP INDEX idx_riders_online_coords;
-- =============================================================================

CREATE INDEX IF NOT EXISTS idx_riders_online_coords
    ON public.riders USING btree (current_lat, current_lng)
    WHERE account_status = 'online';

DROP INDEX IF EXISTS public.idx_riders_current_lat;
DROP INDEX IF EXISTS public.idx_riders_current_lng;
