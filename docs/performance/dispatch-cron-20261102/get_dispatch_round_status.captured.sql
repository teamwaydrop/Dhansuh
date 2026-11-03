CREATE OR REPLACE FUNCTION public.get_dispatch_round_status(p_order_id uuid, p_round integer)
 RETURNS TABLE(order_status text, pending_assignments integer)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
    SELECT
        (SELECT o.order_status::text FROM public.orders o WHERE o.id = p_order_id) AS order_status,
        (
            SELECT COUNT(*)::integer
            FROM public.rider_assignments ra
            WHERE ra.order_id = p_order_id
              AND ra.assignment_round = p_round
              AND ra.assignment_status = 'sent'
        ) AS pending_assignments;
$function$
;
