-- Add pickup_city and destination_city to orders table
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS pickup_city text;
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS destination_city text;

-- Create travel plan status and weight category enums if not exist
DO $$ 
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'travel_plan_status_enum') THEN
        CREATE TYPE public.travel_plan_status_enum AS ENUM ('active', 'completed', 'cancelled');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'weight_category_enum') THEN
        CREATE TYPE public.weight_category_enum AS ENUM ('0_5', '6_15', '16_25', '26_50');
    END IF;
END$$;

-- Create rider_travel_plans table
CREATE TABLE IF NOT EXISTS public.rider_travel_plans (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    rider_id uuid NOT NULL REFERENCES public.riders(id) ON DELETE CASCADE,
    pickup_city text NOT NULL,
    destination_city text NOT NULL,
    pickup_lat double precision,
    pickup_lng double precision,
    destination_lat double precision,
    destination_lng double precision,
    weight_preference public.weight_category_enum DEFAULT '26_50',
    travel_date timestamptz NOT NULL,
    status public.travel_plan_status_enum NOT NULL DEFAULT 'active',
    created_at text DEFAULT (NOW() AT TIME ZONE 'UTC')::text,
    updated_at text DEFAULT (NOW() AT TIME ZONE 'UTC')::text
);


-- Enable RLS
ALTER TABLE public.rider_travel_plans ENABLE ROW LEVEL SECURITY;

-- SELECT Policy: allow authenticated users to view active travel plans
DROP POLICY IF EXISTS "Allow authenticated users to view active travel plans" ON public.rider_travel_plans;
CREATE POLICY "Allow authenticated users to view active travel plans"
ON public.rider_travel_plans
FOR SELECT
TO authenticated
USING (status = 'active'::public.travel_plan_status_enum);

-- INSERT Policy: riders can insert their own travel plans
DROP POLICY IF EXISTS "Allow riders to insert their own travel plans" ON public.rider_travel_plans;
CREATE POLICY "Allow riders to insert their own travel plans"
ON public.rider_travel_plans
FOR INSERT
TO authenticated
WITH CHECK (
    EXISTS (
        SELECT 1 FROM public.riders r
        WHERE r.id = rider_travel_plans.rider_id
          AND r.user_id = auth.uid()
    )
);

-- UPDATE Policy: riders can update their own travel plans
DROP POLICY IF EXISTS "Allow riders to update their own travel plans" ON public.rider_travel_plans;
CREATE POLICY "Allow riders to update their own travel plans"
ON public.rider_travel_plans
FOR UPDATE
TO authenticated
USING (
    EXISTS (
        SELECT 1 FROM public.riders r
        WHERE r.id = rider_travel_plans.rider_id
          AND r.user_id = auth.uid()
    )
)
WITH CHECK (
    EXISTS (
        SELECT 1 FROM public.riders r
        WHERE r.id = rider_travel_plans.rider_id
          AND r.user_id = auth.uid()
    )
);

-- DELETE Policy: riders can delete their own travel plans
DROP POLICY IF EXISTS "Allow riders to delete their own travel plans" ON public.rider_travel_plans;
CREATE POLICY "Allow riders to delete their own travel plans"
ON public.rider_travel_plans
FOR DELETE
TO authenticated
USING (
    EXISTS (
        SELECT 1 FROM public.riders r
        WHERE r.id = rider_travel_plans.rider_id
          AND r.user_id = auth.uid()
    )
);

-- Enable Realtime for rider_travel_plans
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'public' AND tablename = 'rider_travel_plans') THEN
        IF NOT EXISTS (
            SELECT 1 FROM pg_publication_tables 
            WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'rider_travel_plans'
        ) THEN
            ALTER PUBLICATION supabase_realtime ADD TABLE public.rider_travel_plans;
        END IF;
        ALTER TABLE public.rider_travel_plans REPLICA IDENTITY FULL;
    END IF;
END$$;
