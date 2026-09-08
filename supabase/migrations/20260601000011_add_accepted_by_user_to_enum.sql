-- 1. Create a brand new enum type that includes the 'accepted_by_user' state alongside the original states
CREATE TYPE public.intercity_assignment_status_enum AS ENUM (
    'sent', 
    'viewed', 
    'accepted', 
    'rejected', 
    'timed_out', 
    'expired', 
    'cancelled', 
    'accepted_by_user'
);

-- 2. Alter the assignment_status column in public.rider_assignments to use the new type
ALTER TABLE public.rider_assignments 
    ALTER COLUMN assignment_status TYPE public.intercity_assignment_status_enum 
    USING assignment_status::text::public.intercity_assignment_status_enum;

-- 3. Alter the assignment_status column in public.order_assignment_logs to use the new type
ALTER TABLE public.order_assignment_logs 
    ALTER COLUMN assignment_status TYPE public.intercity_assignment_status_enum 
    USING assignment_status::text::public.intercity_assignment_status_enum;
