-- Create custom enum types if they don't exist
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'cashfree_beneficiary_status_enum') THEN
        CREATE TYPE public.cashfree_beneficiary_status_enum AS ENUM ('pending', 'active', 'failed', 'disabled');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'payout_method_enum') THEN
        CREATE TYPE public.payout_method_enum AS ENUM ('bank_account', 'upi');
    END IF;
END$$;

-- Create sequence for beneficiary generation
CREATE SEQUENCE IF NOT EXISTS public.rider_beneficiary_seq START WITH 1;

-- Create function to generate rider beneficiary id
CREATE OR REPLACE FUNCTION public.generate_rider_beneficiary_id()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.beneficiary_id IS NULL THEN
        NEW.beneficiary_id :=
            'WDR' || LPAD(NEXTVAL('public.rider_beneficiary_seq')::TEXT, 6, '0');
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Create rider payout accounts table matching user schema exactly
CREATE TABLE IF NOT EXISTS public.rider_payout_accounts (
  id uuid NOT NULL DEFAULT gen_random_uuid (),
  rider_id uuid NOT NULL,
  user_id uuid NOT NULL,
  beneficiary_id text NOT NULL,
  beneficiary_name text NOT NULL,
  beneficiary_email text NULL,
  beneficiary_phone text NOT NULL,
  account_number text NULL,
  ifsc_code text NULL,
  upi_vpa text NULL,
  cashfree_beneficiary_added boolean NULL DEFAULT false,
  cashfree_beneficiary_status public.cashfree_beneficiary_status_enum NULL DEFAULT 'pending'::public.cashfree_beneficiary_status_enum,
  cashfree_beneficiary_response jsonb NULL,
  is_primary boolean NULL DEFAULT true,
  created_at timestamp without time zone NULL DEFAULT now(),
  updated_at timestamp without time zone NULL DEFAULT now(),
  payout_method public.payout_method_enum NOT NULL,
  CONSTRAINT rider_payout_accounts_pkey PRIMARY KEY (id),
  CONSTRAINT rider_payout_accounts_beneficiary_id_key UNIQUE (beneficiary_id),
  CONSTRAINT rider_payout_accounts_rider_id_fkey FOREIGN KEY (rider_id) REFERENCES public.riders (id) ON DELETE CASCADE,
  CONSTRAINT rider_payout_accounts_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users (id) ON DELETE CASCADE,
  CONSTRAINT payout_method_validation_check CHECK (
    (
      (
        (
          payout_method = 'bank_account'::public.payout_method_enum
        )
        AND (account_number IS NOT NULL)
        AND (ifsc_code IS NOT NULL)
      )
      OR (
        (payout_method = 'upi'::public.payout_method_enum)
        AND (upi_vpa IS NOT NULL)
      )
    )
  ),
  CONSTRAINT account_number_length_check CHECK (
    (
      (length(account_number) >= 8)
      AND (length(account_number) <= 20)
    )
  ),
  CONSTRAINT ifsc_format_check CHECK ((ifsc_code ~ '^[A-Z]{4}0[A-Z0-9]{6}$'::text))
) TABLESPACE pg_default;

-- Create indexes
CREATE UNIQUE INDEX IF NOT EXISTS idx_rider_payout_accounts_rider_id ON public.rider_payout_accounts USING btree (rider_id) TABLESPACE pg_default;
CREATE UNIQUE INDEX IF NOT EXISTS idx_rider_payout_accounts_user_id ON public.rider_payout_accounts USING btree (user_id) TABLESPACE pg_default;
CREATE INDEX IF NOT EXISTS idx_rider_payout_accounts_cashfree_status ON public.rider_payout_accounts USING btree (cashfree_beneficiary_status) TABLESPACE pg_default;
CREATE INDEX IF NOT EXISTS idx_rider_payout_accounts_beneficiary_id ON public.rider_payout_accounts USING btree (beneficiary_id) TABLESPACE pg_default;

-- Create trigger BEFORE INSERT
DROP TRIGGER IF EXISTS trigger_generate_beneficiary_id ON public.rider_payout_accounts;
CREATE TRIGGER trigger_generate_beneficiary_id
BEFORE INSERT ON public.rider_payout_accounts
FOR EACH ROW
EXECUTE FUNCTION public.generate_rider_beneficiary_id();

-- Enable Row Level Security (RLS) on rider_payout_accounts table
ALTER TABLE public.rider_payout_accounts ENABLE ROW LEVEL SECURITY;

-- Select policy: riders can view their own payout account details
DROP POLICY IF EXISTS "Riders can view their own payout account" ON public.rider_payout_accounts;
CREATE POLICY "Riders can view their own payout account"
ON public.rider_payout_accounts
FOR SELECT
TO authenticated
USING (auth.uid() = user_id);

-- Delete policy: riders can delete their own payout account details
DROP POLICY IF EXISTS "Riders can delete their own payout account" ON public.rider_payout_accounts;
CREATE POLICY "Riders can delete their own payout account"
ON public.rider_payout_accounts
FOR DELETE
TO authenticated
USING (auth.uid() = user_id);

-- Create rider payout updates log table to enforce weekly limits
CREATE TABLE IF NOT EXISTS public.rider_payout_updates_log (
  id uuid NOT NULL DEFAULT gen_random_uuid (),
  user_id uuid NOT NULL,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT rider_payout_updates_log_pkey PRIMARY KEY (id),
  CONSTRAINT rider_payout_updates_log_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users (id) ON DELETE CASCADE
) TABLESPACE pg_default;

-- Create composite index on user_id and created_at for updates log
CREATE INDEX IF NOT EXISTS idx_rider_payout_updates_log_user_created ON public.rider_payout_updates_log (user_id, created_at);

-- Enable RLS on updates log table
ALTER TABLE public.rider_payout_updates_log ENABLE ROW LEVEL SECURITY;

-- Select policy: riders can view their own log (no insert/update/delete policies are created, blocking direct write access)
DROP POLICY IF EXISTS "Riders can view their own payout updates log" ON public.rider_payout_updates_log;
CREATE POLICY "Riders can view their own payout updates log"
ON public.rider_payout_updates_log
FOR SELECT
TO authenticated
USING (auth.uid() = user_id);

-- Trigger function to check and log payout updates
CREATE OR REPLACE FUNCTION public.check_payout_update_limit()
RETURNS TRIGGER AS $$
DECLARE
    v_update_count integer;
BEGIN
    -- Check if it's insert, or if it's update where rider-initiated fields changed
    IF (TG_OP = 'INSERT') OR 
       (TG_OP = 'UPDATE' AND (
           OLD.account_number IS DISTINCT FROM NEW.account_number OR
           OLD.ifsc_code IS DISTINCT FROM NEW.ifsc_code OR
           OLD.upi_vpa IS DISTINCT FROM NEW.upi_vpa OR
           OLD.beneficiary_name IS DISTINCT FROM NEW.beneficiary_name OR
           OLD.beneficiary_phone IS DISTINCT FROM NEW.beneficiary_phone OR
           OLD.beneficiary_email IS DISTINCT FROM NEW.beneficiary_email OR
           OLD.payout_method IS DISTINCT FROM NEW.payout_method
       )) THEN
       
        -- 1. Lock the user row to prevent race conditions on concurrent requests
        PERFORM 1 FROM public.users WHERE id = NEW.user_id FOR UPDATE;

        -- 2. Count updates in the last 7 days (rolling window)
        SELECT COUNT(*) INTO v_update_count
        FROM public.rider_payout_updates_log
        WHERE user_id = NEW.user_id
          AND created_at > now() - INTERVAL '7 days';

        IF v_update_count >= 2 THEN
            RAISE EXCEPTION 'Maximum of 2 payout account updates allowed per week';
        END IF;

        -- 3. Log this update event
        INSERT INTO public.rider_payout_updates_log (user_id)
        VALUES (NEW.user_id);
        
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Register BEFORE INSERT OR UPDATE trigger to enforce the 2 updates/week constraint
DROP TRIGGER IF EXISTS trigger_check_payout_update_limit ON public.rider_payout_accounts;
CREATE TRIGGER trigger_check_payout_update_limit
BEFORE INSERT OR UPDATE ON public.rider_payout_accounts
FOR EACH ROW
EXECUTE FUNCTION public.check_payout_update_limit();
