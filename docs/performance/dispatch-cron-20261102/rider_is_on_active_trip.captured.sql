CREATE OR REPLACE FUNCTION public.rider_is_on_active_trip(p_rider_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
    SELECT EXISTS (
        SELECT 1
        FROM public.orders o
        WHERE o.rider_id = p_rider_id
          AND (
                o.order_status::text IN ('rider_arrived', 'picked_up', 'rider_at_drop', 'ongoing', 'payment_pending')
                OR (
                    o.order_status::text = 'accepted'
                    AND (
                        public.get_required_service_mode(o.order_type::text, o.distance_meters) = 'local'
                        OR o.trip_started_at IS NOT NULL
                    )
                )
              )
    );
$function$
;
