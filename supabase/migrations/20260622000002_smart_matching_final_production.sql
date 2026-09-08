-- =====================================================================
-- Migration: Production-Grade Trust & Matching System
-- Date: 2026-06-22
-- Description: Sets up the order_verifications table, lateral reliability calculation view,
--              and traveler capacity checks with zero synchronization bugs.
-- =====================================================================

-- 1. Create order_verifications table
CREATE TABLE IF NOT EXISTS public.order_verifications (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    order_id UUID NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
    verification_type TEXT NOT NULL CHECK (verification_type IN ('pickup', 'dropoff', 'damage_report', 'signature')),
    verification_status TEXT NOT NULL DEFAULT 'verified' CHECK (verification_status IN ('verified', 'bypassed', 'pending_sync', 'failed')),
    photo_url TEXT,
    latitude NUMERIC,
    longitude NUMERIC,
    metadata JSONB DEFAULT '{}'::jsonb,
    created_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL
);

-- Enable RLS
ALTER TABLE public.order_verifications ENABLE ROW LEVEL SECURITY;

-- Drop existing policies if any
DROP POLICY IF EXISTS "Allow participants to view order verifications" ON public.order_verifications;
DROP POLICY IF EXISTS "Allow assigned rider to insert order verifications" ON public.order_verifications;

-- Strict SELECT Policy: User must be the sender OR the assigned rider of the order
CREATE POLICY "Allow participants to view order verifications" 
ON public.order_verifications FOR SELECT TO authenticated
USING (
    EXISTS (
        SELECT 1 FROM public.orders o
        WHERE o.id = order_verifications.order_id
          AND (o.user_id = auth.uid() OR o.rider_id IN (SELECT r.id FROM public.riders r WHERE r.user_id = auth.uid()))
    )
);

-- Strict INSERT Policy: Only the assigned rider of the order can insert verification records
CREATE POLICY "Allow assigned rider to insert order verifications" 
ON public.order_verifications FOR INSERT TO authenticated
WITH CHECK (
    EXISTS (
        SELECT 1 FROM public.orders o
        WHERE o.id = order_verifications.order_id
          AND o.rider_id IN (SELECT r.id FROM public.riders r WHERE r.user_id = auth.uid())
    )
);

-- Enable Realtime for order_verifications
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'public' AND tablename = 'order_verifications') THEN
        IF NOT EXISTS (
            SELECT 1 FROM pg_publication_tables 
            WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'order_verifications'
        ) THEN
            ALTER PUBLICATION supabase_realtime ADD TABLE public.order_verifications;
        END IF;
        ALTER TABLE public.order_verifications REPLICA IDENTITY FULL;
    END IF;
END$$;


-- 2. Reliability Calculator Function (Dynamic and explainable)
CREATE OR REPLACE FUNCTION public.get_rider_reliability_stats(p_rider_id UUID)
RETURNS TABLE (
    reliability_score INT,
    rating NUMERIC,
    completion_rate NUMERIC,
    on_time_rate NUMERIC,
    total_completed BIGINT,
    total_cancelled BIGINT,
    experience_score INT
) AS $$
DECLARE
    v_rating NUMERIC;
    v_completed BIGINT;
    v_cancelled BIGINT;
    v_on_time BIGINT;
    v_completion_rate NUMERIC;
    v_on_time_rate NUMERIC;
    v_experience_score INT;
    v_rating_score NUMERIC;
    v_reliability_score INT;
BEGIN
    -- 1. Get rating (Bayesian rating calculated in riders table)
    SELECT COALESCE(r.rating, 5.0) INTO v_rating FROM public.riders r WHERE r.id = p_rider_id;
    v_rating_score := v_rating * 20.0; -- 5.0 rating -> 100 points

    -- 2. Completed / Cancelled / On-Time counts
    SELECT 
        COUNT(id) FILTER (WHERE order_status IN ('completed', 'delivered')),
        COUNT(id) FILTER (WHERE order_status = 'cancelled'),
        COUNT(id) FILTER (
            WHERE order_status IN ('completed', 'delivered') 
              AND (travel_date IS NULL OR completed_at <= travel_date + INTERVAL '4 hours')
              AND NOT EXISTS (
                  SELECT 1 FROM public.rider_reviews rr 
                  WHERE rr.order_id = orders.id AND 'late_arrival' = ANY(rr.tags)
              )
        )
    INTO v_completed, v_cancelled, v_on_time
    FROM public.orders
    WHERE rider_id = p_rider_id;

    -- 3. Calculate Rates
    IF (v_completed + v_cancelled) > 0 THEN
        v_completion_rate := (v_completed::numeric / (v_completed + v_cancelled)) * 100.0;
    ELSE
        v_completion_rate := 100.0; -- Default for new riders
    END IF;

    IF v_completed > 0 THEN
        v_on_time_rate := (v_on_time::numeric / v_completed) * 100.0;
    ELSE
        v_on_time_rate := 100.0; -- Default for new riders
    END IF;

    -- 4. Experience Score (Piecewise curve)
    IF v_completed = 0 THEN
        v_experience_score := 0;
    ELSIF v_completed < 10 THEN
        v_experience_score := 20;
    ELSIF v_completed < 50 THEN
        v_experience_score := 60;
    ELSIF v_completed < 100 THEN
        v_experience_score := 80;
    ELSE
        v_experience_score := 100;
    END IF;

    -- 5. Calculate final reliability score (40% rating, 40% completion rate, 20% experience)
    v_reliability_score := ROUND((v_rating_score * 0.40) + (v_completion_rate * 0.40) + (v_experience_score * 0.20));

    RETURN QUERY SELECT 
        LEAST(GREATEST(v_reliability_score, 0), 100)::INT,
        v_rating,
        ROUND(v_completion_rate, 2),
        ROUND(v_on_time_rate, 2),
        v_completed,
        v_cancelled,
        v_experience_score;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- 3. Dynamic Reliability View
CREATE OR REPLACE VIEW public.rider_reliability_view AS
SELECT 
    r.id AS rider_id,
    r.user_id,
    stats.reliability_score,
    stats.rating,
    stats.completion_rate,
    stats.on_time_rate,
    stats.total_completed,
    stats.total_cancelled,
    stats.experience_score
FROM public.riders r
CROSS JOIN LATERAL public.get_rider_reliability_stats(r.id) stats;


-- 4. Simplified Dynamic Travel Plan Capacity View
-- Group active weights globally by rider to ensure corridor-independent accuracy
CREATE OR REPLACE VIEW public.travel_plan_capacity_view AS
WITH active_weight_usage AS (
    SELECT 
        o.rider_id,
        COALESCE(SUM(
            COALESCE(
                o.actual_weight_kg,
                COALESCE(NULLIF(regexp_replace(o.weight_category::text, '[^0-9.]', '', 'g'), ''), '0')::numeric
            )
        ), 0.0) AS used_weight_kg
    FROM public.orders o
    WHERE o.order_status IN ('accepted', 'rider_arrived', 'picked_up', 'ongoing', 'rider_at_drop')
    GROUP BY o.rider_id
)
SELECT 
    tp.id AS plan_id,
    tp.max_weight_kg,
    COALESCE(uw.used_weight_kg, 0.0) AS used_weight_kg,
    GREATEST(tp.max_weight_kg - COALESCE(uw.used_weight_kg, 0.0), 0.0) AS remaining_capacity_kg
FROM public.rider_travel_plans tp
LEFT JOIN active_weight_usage uw ON uw.rider_id = tp.rider_id;

-- Grant permissions
GRANT SELECT ON public.order_verifications TO authenticated;
GRANT INSERT ON public.order_verifications TO authenticated;
GRANT SELECT ON public.rider_reliability_view TO authenticated;
GRANT SELECT ON public.travel_plan_capacity_view TO authenticated;
