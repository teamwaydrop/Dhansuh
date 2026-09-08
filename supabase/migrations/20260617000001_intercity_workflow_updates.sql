-- =====================================================================
-- Migration: Simplified Intercity Marketplace Workflow Updates (Final Approved V5)
-- Date: 2026-06-17
-- Description: Sets up features_flags seed, travel plans, status constraints,
--              Postgres RPCs for transactional agreements, capacity trigger,
--              and pg_cron cleanups.
-- =====================================================================

-- 1. Alter travel_plan_status_enum
DO $$
BEGIN
    ALTER TYPE public.travel_plan_status_enum ADD VALUE IF NOT EXISTS 'fully_booked';
    ALTER TYPE public.travel_plan_status_enum ADD VALUE IF NOT EXISTS 'expired';
EXCEPTION
    WHEN duplicate_object THEN NULL;
END$$;

-- 2. Seed default configuration values into feature_flags table as valid JSON objects
INSERT INTO public.feature_flags (key, value, description)
VALUES 
    ('intercity_matching_radius_km', '{"km": 25}'::jsonb, 'Proximity matching radius in km for intercity matches')
ON CONFLICT (key) DO UPDATE SET
    value = excluded.value,
    description = excluded.description;

DELETE FROM public.feature_flags WHERE key = 'intercity_payment_timeout_minutes';
DELETE FROM public.feature_flags WHERE key = 'intercity_arrival_autocomplete_minutes';

-- 3. Alter rider_travel_plans Table
ALTER TABLE public.rider_travel_plans
    ADD COLUMN IF NOT EXISTS max_weight_kg NUMERIC NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS max_bookings INTEGER NOT NULL DEFAULT 3,
    ADD COLUMN IF NOT EXISTS travel_plan_type TEXT NOT NULL DEFAULT 'both' CHECK (travel_plan_type IN ('ride', 'parcel', 'both')),
    ADD COLUMN IF NOT EXISTS vehicle_type public.vehicle_type_enum;

-- 4. Alter orders Table (Parcel weight check constraint)
ALTER TABLE public.orders 
    DROP CONSTRAINT IF EXISTS check_intercity_parcel_weight;

ALTER TABLE public.orders 
    ADD CONSTRAINT check_intercity_parcel_weight 
    CHECK (order_type != 'intercity_parcel' OR (actual_weight_kg IS NOT NULL AND actual_weight_kg > 0));

-- 5. Alter intercity_requests Table
-- Drop check constraint on status column to support new statuses
ALTER TABLE public.intercity_requests
    DROP CONSTRAINT IF EXISTS intercity_requests_status_check;

-- Add new columns
ALTER TABLE public.intercity_requests
    ADD COLUMN IF NOT EXISTS booking_type TEXT CHECK (booking_type IN ('ride', 'parcel')),
    ADD COLUMN IF NOT EXISTS expires_at TIMESTAMP WITH TIME ZONE DEFAULT (now() + interval '24 hours'),
    ADD COLUMN IF NOT EXISTS metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    ADD COLUMN IF NOT EXISTS expiry_reason TEXT CHECK (expiry_reason IN ('negotiation_timeout', 'travel_date_passed', 'no_show'));

ALTER TABLE public.intercity_requests DROP COLUMN IF EXISTS payment_due_until;
ALTER TABLE public.intercity_requests DROP COLUMN IF EXISTS arrival_autocomplete_minutes;
ALTER TABLE public.orders DROP COLUMN IF EXISTS arrival_autocomplete_minutes;
ALTER TABLE public.rider_travel_plans DROP COLUMN IF EXISTS arrival_autocomplete_minutes;

-- Update any incompatible status rows in existing test data to 'request_sent' to prevent constraint failure
UPDATE public.intercity_requests
SET status = 'request_sent'
WHERE status NOT IN ('request_sent', 'discussion_started', 'fare_agreed', 'confirmed', 'paid', 'expired', 'cancelled', 'rejected');

-- Re-add check constraint supporting 8 statuses
ALTER TABLE public.intercity_requests
    ADD CONSTRAINT intercity_requests_status_check CHECK (status IN (
        'request_sent',
        'discussion_started',
        'fare_agreed',
        'confirmed',
        'paid',
        'expired',
        'cancelled',
        'rejected'
    ));

-- Add a comment on column status explaining the states
COMMENT ON COLUMN public.intercity_requests.status IS 
'Negotiation and booking states:
- request_sent: Initial offer/request sent from rider/user.
- discussion_started: Discussion accepted, chat unlocked.
- fare_agreed: Mutual fare agreed (metadata: sender_agreed = true, traveller_agreed = true).
- confirmed: Booking locked (capacity reserved, snapshots taken, payment due timer set).
- paid: Payment completed (unlocks all media chat features, waiting for transit).
- expired: Expired due to timeout (payment timeout or negotiation timeout).
- cancelled: Cancelled by one of the parties before payment or journey.
- rejected: Booking request rejected.';

-- 6. Trigger Functions
-- Prevent travel plan deletion if active bookings exist on it
CREATE OR REPLACE FUNCTION public.check_travel_plan_active_bookings()
RETURNS TRIGGER AS $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM public.intercity_requests
        WHERE route_id = OLD.id
          AND status IN ('confirmed', 'paid')
    ) THEN
        RAISE EXCEPTION 'Cannot delete travel plan while active bookings exist. Mark it inactive instead.';
    END IF;
    RETURN OLD;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS prevent_delete_active_travel_plan ON public.rider_travel_plans;
CREATE TRIGGER prevent_delete_active_travel_plan
BEFORE DELETE ON public.rider_travel_plans
FOR EACH ROW
EXECUTE FUNCTION public.check_travel_plan_active_bookings();

-- Sync travel plan status AFTER requests change (revive fully_booked to active)
CREATE OR REPLACE FUNCTION public.sync_travel_plan_status_after()
RETURNS TRIGGER AS $$
DECLARE
    v_active_bookings INT;
    v_max_bookings INT;
    v_plan_status public.travel_plan_status_enum;
    v_route_id uuid;
BEGIN
    IF TG_OP = 'DELETE' THEN
        v_route_id := OLD.route_id;
    ELSE
        v_route_id := NEW.route_id;
    END IF;

    IF v_route_id IS NULL THEN
        RETURN NULL;
    END IF;

    SELECT max_bookings, status INTO v_max_bookings, v_plan_status
    FROM public.rider_travel_plans
    WHERE id = v_route_id
    FOR UPDATE;

    SELECT COUNT(*) INTO v_active_bookings
    FROM public.intercity_requests
    WHERE route_id = v_route_id
      AND status IN ('confirmed', 'paid');

    IF v_active_bookings >= v_max_bookings THEN
        IF v_plan_status = 'active'::public.travel_plan_status_enum THEN
            UPDATE public.rider_travel_plans 
            SET status = 'fully_booked'::public.travel_plan_status_enum 
            WHERE id = v_route_id;
        END IF;
    ELSE
        -- Revive only fully_booked plans. Never touch expired or cancelled plans.
        IF v_plan_status = 'fully_booked'::public.travel_plan_status_enum THEN
            UPDATE public.rider_travel_plans 
            SET status = 'active'::public.travel_plan_status_enum 
            WHERE id = v_route_id;
        END IF;
    END IF;

    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trigger_sync_travel_plan_status ON public.intercity_requests;
CREATE TRIGGER trigger_sync_travel_plan_status
AFTER INSERT OR UPDATE OR DELETE ON public.intercity_requests
FOR EACH ROW
EXECUTE FUNCTION public.sync_travel_plan_status_after();

-- 7. Postgres RPCs for Agreement & Confirmation (Transaction Safety)
-- accept_intercity_offer updates metadata and transitions status atomically
CREATE OR REPLACE FUNCTION public.accept_intercity_offer(
    p_request_id uuid,
    p_actor_type text
)
RETURNS jsonb AS $$
DECLARE
    v_request RECORD;
    v_metadata jsonb;
BEGIN
    SELECT * INTO v_request
    FROM public.intercity_requests
    WHERE id = p_request_id
    FOR UPDATE;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Request not found';
    END IF;
    
    v_metadata := COALESCE(v_request.metadata, '{}'::jsonb);
    
    IF p_actor_type = 'sender' THEN
        v_metadata := v_metadata || '{"sender_agreed": true}'::jsonb;
    ELSIF p_actor_type = 'traveller' THEN
        v_metadata := v_metadata || '{"traveller_agreed": true}'::jsonb;
    ELSE
        RAISE EXCEPTION 'Invalid actor type: %', p_actor_type;
    END IF;
    
    IF COALESCE((v_metadata->>'sender_agreed')::boolean, false) = true 
       AND COALESCE((v_metadata->>'traveller_agreed')::boolean, false) = true THEN
        UPDATE public.intercity_requests
        SET metadata = v_metadata,
            status = 'fare_agreed',
            updated_at = now()
        WHERE id = p_request_id;
    ELSE
        UPDATE public.intercity_requests
        SET metadata = v_metadata,
            status = 'discussion_started',
            updated_at = now()
        WHERE id = p_request_id;
    END IF;
    
    SELECT json_build_object(
        'id', id,
        'status', status,
        'metadata', metadata,
        'proposed_fare', proposed_fare
    )::jsonb INTO v_metadata
    FROM public.intercity_requests
    WHERE id = p_request_id;
    
    RETURN v_metadata;
END;
$$ LANGUAGE plpgsql;

-- confirm_intercity_booking transactionally confirms booking & updates order
CREATE OR REPLACE FUNCTION public.confirm_intercity_booking(
    p_request_id uuid
)
RETURNS jsonb AS $$
DECLARE
    v_request RECORD;
    v_active_bookings INT;
    v_max_bookings INT;
    v_plan_pickup TEXT;
    v_plan_dest TEXT;
    v_plan_vehicle public.vehicle_type_enum;
    v_plan_date TIMESTAMPTZ;
    v_plan_weight NUMERIC;
    v_order_weight NUMERIC;
    v_order_type TEXT;
    v_pickup_city TEXT;
    v_dest_city TEXT;
    v_metadata jsonb;
BEGIN
    SELECT * INTO v_request
    FROM public.intercity_requests
    WHERE id = p_request_id
    FOR UPDATE;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Request not found';
    END IF;
    
    IF v_request.status = 'confirmed' THEN
        RETURN json_build_object('success', true, 'status', 'confirmed')::jsonb;
    END IF;
    
    IF COALESCE((v_request.metadata->>'sender_agreed')::boolean, false) IS NOT TRUE 
       OR COALESCE((v_request.metadata->>'traveller_agreed')::boolean, false) IS NOT TRUE THEN
        RAISE EXCEPTION 'Cannot confirm booking before both parties agree on the fare.';
    END IF;
    
    SELECT max_bookings, pickup_city, destination_city, vehicle_type, travel_date, max_weight_kg 
    INTO v_max_bookings, v_plan_pickup, v_plan_dest, v_plan_vehicle, v_plan_date, v_plan_weight
    FROM public.rider_travel_plans
    WHERE id = v_request.route_id
    FOR UPDATE;
    
    SELECT COUNT(*) INTO v_active_bookings
    FROM public.intercity_requests
    WHERE route_id = v_request.route_id
      AND status IN ('confirmed', 'paid')
      AND id IS DISTINCT FROM p_request_id;
      
    IF v_active_bookings >= v_max_bookings THEN
        RAISE EXCEPTION 'This travel plan is fully booked. (Current: %, Max limit: %)', v_active_bookings, v_max_bookings;
    END IF;
    
    SELECT actual_weight_kg, order_type, pickup_city, destination_city
    INTO v_order_weight, v_order_type, v_pickup_city, v_dest_city
    FROM public.orders
    WHERE id = v_request.parcel_id;
    
    v_metadata := COALESCE(v_request.metadata, '{}'::jsonb) || jsonb_build_object(
        'travel_plan_snapshot', jsonb_build_object(
            'pickup_city', v_plan_pickup,
            'destination_city', v_plan_dest,
            'vehicle_type', v_plan_vehicle,
            'travel_date', v_plan_date,
            'max_weight_kg', v_plan_weight
        ),
        'booking_snapshot', jsonb_build_object(
            'agreed_fare', v_request.proposed_fare,
            'booking_type', v_request.booking_type,
            'pickup_city', v_pickup_city,
            'destination_city', v_dest_city,
            'weight_kg', v_order_weight
        )
    );
    
    UPDATE public.intercity_requests
    SET status = 'confirmed',
        metadata = v_metadata,
        updated_at = now()
    WHERE id = p_request_id;
    
    UPDATE public.orders
    SET order_status = 'accepted'::public.order_status_enum,
        rider_id = v_request.traveller_id,
        final_fare = v_request.proposed_fare,
        current_fare = v_request.proposed_fare,
        updated_at = now()
    WHERE id = v_request.parcel_id;
    
    RETURN json_build_object('success', true, 'status', 'confirmed')::jsonb;
END;
$$ LANGUAGE plpgsql;

-- 8. Expiry Cleanups Function
CREATE OR REPLACE FUNCTION public.expire_stale_intercity_requests()
RETURNS VOID AS $$
BEGIN
    -- Stale negotiation expiration (24h)
    UPDATE public.intercity_requests
    SET status = 'expired',
        expiry_reason = 'negotiation_timeout',
        updated_at = now()
    WHERE status IN ('request_sent', 'discussion_started', 'fare_agreed')
      AND expires_at < now();

    -- Travel plan auto-expiry
    UPDATE public.rider_travel_plans
    SET status = 'expired'::public.travel_plan_status_enum
    WHERE travel_date < now()
      AND status = 'active'::public.travel_plan_status_enum;
END;
$$ LANGUAGE plpgsql;
