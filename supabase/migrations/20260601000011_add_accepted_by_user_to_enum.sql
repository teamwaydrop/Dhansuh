-- Idempotently add 'accepted_by_user' to the existing intercity_assignment_status_enum
ALTER TYPE public.intercity_assignment_status_enum ADD VALUE IF NOT EXISTS 'accepted_by_user';
