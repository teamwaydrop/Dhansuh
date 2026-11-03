-- Captured production definition; NOT a deployment script.
CREATE OR REPLACE FUNCTION public.prevent_chat_before_intercity_acceptance()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
    IF NEW.order_id IS NULL THEN
        RETURN NEW;
    END IF;

    -- Admin/support messages are never blocked, matching the existing RLS policy's own carve-out.
    IF EXISTS (
        SELECT 1 FROM public.users
        WHERE id = auth.uid() AND role IN ('admin', 'support')
    ) THEN
        RETURN NEW;
    END IF;

    IF EXISTS (
        SELECT 1 FROM public.intercity_requests ir
        WHERE ir.parcel_id = NEW.order_id
          AND ir.status = 'request_sent'
    ) THEN
        RAISE EXCEPTION 'You can send messages after the request is accepted.';
    END IF;

    RETURN NEW;
END;
$function$

