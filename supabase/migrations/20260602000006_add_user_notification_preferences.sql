-- Add notification preferences columns to public.users table
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS pref_order_notifications boolean NOT NULL DEFAULT true;
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS pref_chat_notifications boolean NOT NULL DEFAULT true;
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS pref_rating_notifications boolean NOT NULL DEFAULT true;
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS pref_admin_notifications boolean NOT NULL DEFAULT true;
