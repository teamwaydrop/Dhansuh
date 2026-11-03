
CREATE INDEX IF NOT EXISTS idx_riders_online_coords
    ON public.riders USING btree (current_lat, current_lng)
    WHERE account_status = 'online';

DROP INDEX IF EXISTS public.idx_riders_current_lat;
DROP INDEX IF EXISTS public.idx_riders_current_lng;
