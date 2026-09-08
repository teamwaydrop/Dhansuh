-- Migration: Create rider_daily_activity table and triggers to track rider active/online time and trip details.

CREATE TABLE public.rider_daily_activity (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  rider_id uuid NOT NULL,
  date date NOT NULL DEFAULT CURRENT_DATE,
  online_seconds integer NOT NULL DEFAULT 0,
  active_seconds integer NOT NULL DEFAULT 0, -- Time spent on active trips
  completed_orders integer DEFAULT 0,
  cancelled_orders integer DEFAULT 0,
  earnings numeric DEFAULT 0.0,
  last_online_toggle_at timestamp with time zone,
  created_at timestamp with time zone DEFAULT now(),
  updated_at timestamp with time zone DEFAULT now(),
  CONSTRAINT rider_daily_activity_pkey PRIMARY KEY (id),
  CONSTRAINT rider_daily_activity_rider_id_date_key UNIQUE (rider_id, date),
  CONSTRAINT rider_daily_activity_rider_id_fkey FOREIGN KEY (rider_id) REFERENCES public.riders(id) ON DELETE CASCADE
);

-- RLS Policies
ALTER TABLE public.rider_daily_activity ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Riders can view their own daily activity"
  ON public.rider_daily_activity
  FOR SELECT
  TO authenticated
  USING (
    rider_id IN (
      SELECT id FROM public.riders WHERE user_id = auth.uid()
    )
  );

GRANT SELECT ON public.rider_daily_activity TO authenticated;

-- Trigger Function to track online time when rider status changes
CREATE OR REPLACE FUNCTION public.handle_rider_status_change()
RETURNS TRIGGER AS $$
DECLARE
BEGIN
  -- If account_status is toggled
  IF NEW.account_status IS DISTINCT FROM OLD.account_status THEN
    -- Going online
    IF NEW.account_status = 'online' THEN
      INSERT INTO public.rider_daily_activity (rider_id, date, last_online_toggle_at)
      VALUES (NEW.id, CURRENT_DATE, now())
      ON CONFLICT (rider_id, date) DO UPDATE
      SET last_online_toggle_at = now(),
          updated_at = now();
    -- Going offline
    ELSIF NEW.account_status = 'offline' AND OLD.account_status = 'online' THEN
      UPDATE public.rider_daily_activity
      SET online_seconds = online_seconds + EXTRACT(EPOCH FROM (now() - last_online_toggle_at))::integer,
          last_online_toggle_at = NULL,
          updated_at = now()
      WHERE rider_id = NEW.id AND last_online_toggle_at IS NOT NULL;
    END IF;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE TRIGGER on_rider_status_change
  AFTER UPDATE OF account_status ON public.riders
  FOR EACH ROW
  EXECUTE FUNCTION public.handle_rider_status_change();

-- Trigger Function to track active seconds, completed/cancelled orders, and earnings
CREATE OR REPLACE FUNCTION public.handle_order_activity_tracking()
RETURNS TRIGGER AS $$
DECLARE
  v_trip_time integer := 0;
  v_earnings numeric := 0.0;
  v_date date;
BEGIN
  -- Track changes to completed, delivered, or cancelled status
  IF NEW.order_status IS DISTINCT FROM OLD.order_status THEN
    v_date := COALESCE(NEW.completed_at, NEW.cancelled_at, now())::date;
    
    -- Completed / Delivered
    IF NEW.order_status IN ('completed', 'delivered') AND NEW.rider_id IS NOT NULL THEN
      -- Calculate trip time in seconds
      IF NEW.time_taken_seconds IS NOT NULL AND NEW.time_taken_seconds > 0 THEN
        v_trip_time := NEW.time_taken_seconds;
      ELSE
        -- Fallback to difference between completed_at and picked_up_at / accepted_at
        IF NEW.completed_at IS NOT NULL THEN
          v_trip_time := EXTRACT(EPOCH FROM (NEW.completed_at - COALESCE(NEW.picked_up_at, NEW.accepted_at, NEW.created_at)))::integer;
          IF v_trip_time < 0 THEN v_trip_time := 0; END IF;
        END IF;
      END IF;

      v_earnings := COALESCE(NEW.rider_earning, 0.0);

      INSERT INTO public.rider_daily_activity (rider_id, date, active_seconds, completed_orders, earnings)
      VALUES (NEW.rider_id, v_date, v_trip_time, 1, v_earnings)
      ON CONFLICT (rider_id, date) DO UPDATE
      SET active_seconds = rider_daily_activity.active_seconds + v_trip_time,
          completed_orders = rider_daily_activity.completed_orders + 1,
          earnings = rider_daily_activity.earnings + v_earnings,
          updated_at = now();
          
    -- Cancelled
    ELSIF NEW.order_status = 'cancelled' AND NEW.rider_id IS NOT NULL THEN
      INSERT INTO public.rider_daily_activity (rider_id, date, cancelled_orders)
      VALUES (NEW.rider_id, v_date, 1)
      ON CONFLICT (rider_id, date) DO UPDATE
      SET cancelled_orders = rider_daily_activity.cancelled_orders + 1,
          updated_at = now();
    END IF;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE TRIGGER on_order_activity_tracking
  AFTER UPDATE OF order_status ON public.orders
  FOR EACH ROW
  EXECUTE FUNCTION public.handle_order_activity_tracking();
