-- Route every find_nearby_riders call through the optimized six-argument implementation.
--
-- 20260901000010 added p_excluded_rider_ids with a default value, which created a new overload;
-- PostgreSQL does not replace a function when its argument list changes. The previous five-argument
-- function therefore remained callable, and the passenger nearby-count clients still send exactly
-- five parameters. Removing the legacy overload is safe because the sixth argument on the current
-- function defaults to an empty uuid array, preserving results for callers that omit it.

DROP FUNCTION IF EXISTS public.find_nearby_riders(
    uuid,
    double precision,
    double precision,
    double precision,
    integer
);

GRANT EXECUTE ON FUNCTION public.find_nearby_riders(
    uuid,
    double precision,
    double precision,
    double precision,
    integer,
    uuid[]
) TO authenticated, service_role;
