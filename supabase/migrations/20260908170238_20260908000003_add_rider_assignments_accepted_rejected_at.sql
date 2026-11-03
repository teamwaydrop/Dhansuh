
ALTER TABLE public.rider_assignments
    ADD COLUMN IF NOT EXISTS accepted_at timestamptz,
    ADD COLUMN IF NOT EXISTS rejected_at timestamptz;

NOTIFY pgrst, 'reload schema';
