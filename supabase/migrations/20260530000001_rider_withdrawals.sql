-- Create rider withdrawal status enum if it doesn't exist
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'rider_withdrawal_status_enum') THEN
        CREATE TYPE public.rider_withdrawal_status_enum AS ENUM ('pending', 'processing', 'success', 'failed');
    END IF;
END$$;

-- Create rider withdrawals table
CREATE TABLE IF NOT EXISTS public.rider_withdrawals (
  id uuid NOT NULL DEFAULT gen_random_uuid (),
  rider_id uuid NOT NULL,
  user_id uuid NOT NULL,
  amount numeric(10,2) NOT NULL,
  transfer_id text NOT NULL,
  status public.rider_withdrawal_status_enum NOT NULL DEFAULT 'pending'::public.rider_withdrawal_status_enum,
  cashfree_reference_id text NULL,
  cashfree_response jsonb NULL,
  created_at timestamp with time zone NULL DEFAULT now(),
  updated_at timestamp with time zone NULL DEFAULT now(),
  CONSTRAINT rider_withdrawals_pkey PRIMARY KEY (id),
  CONSTRAINT rider_withdrawals_transfer_id_key UNIQUE (transfer_id),
  CONSTRAINT rider_withdrawals_rider_id_fkey FOREIGN KEY (rider_id) REFERENCES public.riders (id) ON DELETE CASCADE,
  CONSTRAINT rider_withdrawals_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users (id) ON DELETE CASCADE,
  CONSTRAINT rider_withdrawals_amount_check CHECK (amount > 0)
) TABLESPACE pg_default;

-- Create rider withdrawal events audit table
CREATE TABLE IF NOT EXISTS public.rider_withdrawal_events (
  id uuid NOT NULL DEFAULT gen_random_uuid (),
  withdrawal_id uuid NOT NULL,
  event_type text NOT NULL,
  old_status public.rider_withdrawal_status_enum NULL,
  new_status public.rider_withdrawal_status_enum NOT NULL,
  response jsonb NULL,
  created_at timestamp with time zone NULL DEFAULT now(),
  CONSTRAINT rider_withdrawal_events_pkey PRIMARY KEY (id),
  CONSTRAINT rider_withdrawal_events_withdrawal_id_fkey FOREIGN KEY (withdrawal_id) REFERENCES public.rider_withdrawals (id) ON DELETE CASCADE
) TABLESPACE pg_default;

-- Create indexes for performance
CREATE INDEX IF NOT EXISTS idx_rider_withdrawals_rider_id ON public.rider_withdrawals (rider_id);
CREATE INDEX IF NOT EXISTS idx_rider_withdrawals_user_id ON public.rider_withdrawals (user_id);
CREATE INDEX IF NOT EXISTS idx_rider_withdrawals_transfer_id ON public.rider_withdrawals (transfer_id);
CREATE INDEX IF NOT EXISTS idx_rider_withdrawal_events_withdrawal_id ON public.rider_withdrawal_events (withdrawal_id);

-- Trigger function to automatically update updated_at
CREATE OR REPLACE FUNCTION public.update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Create trigger on rider_withdrawals
DROP TRIGGER IF EXISTS set_updated_at ON public.rider_withdrawals;
CREATE TRIGGER set_updated_at
BEFORE UPDATE ON public.rider_withdrawals
FOR EACH ROW
EXECUTE FUNCTION public.update_updated_at_column();

-- Trigger function to automatically log withdrawal events
CREATE OR REPLACE FUNCTION public.log_rider_withdrawal_event()
RETURNS TRIGGER AS $$
BEGIN
    IF (TG_OP = 'INSERT') THEN
        INSERT INTO public.rider_withdrawal_events (
            withdrawal_id,
            event_type,
            old_status,
            new_status,
            response
        ) VALUES (
            NEW.id,
            'initiated',
            NULL,
            NEW.status,
            NEW.cashfree_response
        );
    ELSIF (TG_OP = 'UPDATE') THEN
        -- Only log if status changed, response metadata changed, or reference id changed
        IF (OLD.status != NEW.status OR OLD.cashfree_response IS DISTINCT FROM NEW.cashfree_response OR OLD.cashfree_reference_id IS DISTINCT FROM NEW.cashfree_reference_id) THEN
            INSERT INTO public.rider_withdrawal_events (
                withdrawal_id,
                event_type,
                old_status,
                new_status,
                response
            ) VALUES (
                NEW.id,
                CASE 
                    WHEN OLD.status != NEW.status THEN 'status_change'
                    ELSE 'metadata_update'
                END,
                OLD.status,
                NEW.status,
                NEW.cashfree_response
            );
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Create trigger on rider_withdrawals
DROP TRIGGER IF EXISTS log_withdrawal_event ON public.rider_withdrawals;
CREATE TRIGGER log_withdrawal_event
AFTER INSERT OR UPDATE ON public.rider_withdrawals
FOR EACH ROW
EXECUTE FUNCTION public.log_rider_withdrawal_event();

-- Function to initiate a withdrawal atomically
CREATE OR REPLACE FUNCTION public.initiate_withdrawal(p_amount numeric, p_user_id uuid)
RETURNS jsonb AS $$
DECLARE
    v_rider_id uuid;
    v_wallet_balance numeric;
    v_payout_account_id uuid;
    v_payout_status public.cashfree_beneficiary_status_enum;
    v_transfer_id text;
    v_withdrawal_id uuid;
    v_beneficiary_id text;
    v_payout_method public.payout_method_enum;
    v_upi_vpa text;
BEGIN
    -- 1. Validation for withdrawal amount
    IF p_amount <= 0 THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', 'Invalid withdrawal amount'
        );
    END IF;

    -- 2. Fetch rider and lock row to prevent race conditions on balance updates
    SELECT id, wallet_balance INTO v_rider_id, v_wallet_balance
    FROM public.riders
    WHERE user_id = p_user_id
    FOR UPDATE;

    IF v_rider_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'Rider profile not found');
    END IF;

    -- 3. Fetch payout account details (limit to 1 account to prevent multi-row return database exception)
    SELECT id, cashfree_beneficiary_status, beneficiary_id, payout_method, upi_vpa
    INTO v_payout_account_id, v_payout_status, v_beneficiary_id, v_payout_method, v_upi_vpa
    FROM public.rider_payout_accounts
    WHERE user_id = p_user_id
    ORDER BY created_at DESC
    LIMIT 1;

    IF v_payout_account_id IS NULL OR v_beneficiary_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'Payout account beneficiary ID not found');
    END IF;

    -- 4. Check wallet balance
    IF v_wallet_balance < p_amount THEN
        RETURN jsonb_build_object('success', false, 'message', 'Insufficient wallet balance');
    END IF;

    -- 5. Generate unique transfer_id
    v_transfer_id := 'WDT' || REPLACE(gen_random_uuid()::text, '-', '');

    -- 6. Deduct wallet balance (rider row is already locked)
    UPDATE public.riders
    SET wallet_balance = wallet_balance - p_amount
    WHERE id = v_rider_id;

    -- 7. Insert pending withdrawal (logs trigger automatically)
    INSERT INTO public.rider_withdrawals (
        rider_id,
        user_id,
        amount,
        transfer_id,
        status
    ) VALUES (
        v_rider_id,
        p_user_id,
        p_amount,
        v_transfer_id,
        'pending'::public.rider_withdrawal_status_enum
    ) RETURNING id INTO v_withdrawal_id;

    RETURN jsonb_build_object(
        'success', true,
        'rider_id', v_rider_id,
        'withdrawal_id', v_withdrawal_id,
        'transfer_id', v_transfer_id,
        'beneficiary_id', v_beneficiary_id,
        'payout_method', v_payout_method,
        'upi_vpa', v_upi_vpa
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function to mark a withdrawal as failed and rollback wallet balance
CREATE OR REPLACE FUNCTION public.fail_withdrawal(p_withdrawal_id uuid, p_error_response jsonb)
RETURNS jsonb AS $$
DECLARE
    v_rider_id uuid;
    v_amount numeric;
    v_status public.rider_withdrawal_status_enum;
BEGIN
    -- Fetch and lock the withdrawal record
    SELECT rider_id, amount, status INTO v_rider_id, v_amount, v_status
    FROM public.rider_withdrawals
    WHERE id = p_withdrawal_id
    FOR UPDATE;

    IF v_rider_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'Withdrawal record not found');
    END IF;

    -- Only allow failing from non-finalized states (pending or processing)
    IF v_status IN ('success'::public.rider_withdrawal_status_enum, 'failed'::public.rider_withdrawal_status_enum) THEN
        RETURN jsonb_build_object('success', true, 'message', 'Withdrawal already finalized in ' || v_status::text || ' state');
    END IF;

    -- Update withdrawal status (updated_at is handled by trigger)
    UPDATE public.rider_withdrawals
    SET status = 'failed'::public.rider_withdrawal_status_enum,
        cashfree_response = p_error_response
    WHERE id = p_withdrawal_id;

    -- Lock rider row for update
    PERFORM id FROM public.riders WHERE id = v_rider_id FOR UPDATE;

    -- Refund rider's wallet balance
    UPDATE public.riders
    SET wallet_balance = wallet_balance + v_amount
    WHERE id = v_rider_id;

    RETURN jsonb_build_object('success', true);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function to mark a withdrawal as complete/success/processing/failed/pending from Cashfree
CREATE OR REPLACE FUNCTION public.complete_withdrawal(
    p_withdrawal_id uuid,
    p_cashfree_ref_id text,
    p_status text,
    p_response jsonb
)
RETURNS jsonb AS $$
DECLARE
    v_rider_id uuid;
    v_amount numeric;
    v_current_status public.rider_withdrawal_status_enum;
    v_new_status public.rider_withdrawal_status_enum;
BEGIN
    -- Safely cast input status text to enum
    BEGIN
        v_new_status := p_status::public.rider_withdrawal_status_enum;
    EXCEPTION WHEN OTHERS THEN
        RETURN jsonb_build_object('success', false, 'message', 'Invalid status to complete withdrawal');
    END;

    -- Fetch and lock the withdrawal record
    SELECT rider_id, amount, status INTO v_rider_id, v_amount, v_current_status
    FROM public.rider_withdrawals
    WHERE id = p_withdrawal_id
    FOR UPDATE;

    IF v_rider_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'message', 'Withdrawal record not found');
    END IF;

    -- Check if already finalized (success or failed)
    IF v_current_status IN ('success'::public.rider_withdrawal_status_enum, 'failed'::public.rider_withdrawal_status_enum) THEN
        RETURN jsonb_build_object('success', true, 'message', 'Withdrawal already finalized in ' || v_current_status::text || ' state');
    END IF;

    -- Prevent invalid transition from processing back to pending
    IF v_current_status = 'processing'::public.rider_withdrawal_status_enum AND v_new_status = 'pending'::public.rider_withdrawal_status_enum THEN
        RETURN jsonb_build_object('success', false, 'message', 'Cannot transition from processing back to pending');
    END IF;

    -- Update withdrawal status (updated_at is handled by trigger)
    UPDATE public.rider_withdrawals
    SET status = v_new_status,
        cashfree_reference_id = p_cashfree_ref_id,
        cashfree_response = p_response
    WHERE id = p_withdrawal_id;

    -- Refund rider's wallet balance if status resolved to failed
    IF v_new_status = 'failed'::public.rider_withdrawal_status_enum THEN
        -- Lock rider row for update
        PERFORM id FROM public.riders WHERE id = v_rider_id FOR UPDATE;

        UPDATE public.riders
        SET wallet_balance = wallet_balance + v_amount
        WHERE id = v_rider_id;
    END IF;

    RETURN jsonb_build_object('success', true);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Enable Row Level Security (RLS) on rider_withdrawals and events tables
ALTER TABLE public.rider_withdrawals ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.rider_withdrawal_events ENABLE ROW LEVEL SECURITY;

-- Select policy: riders can view their own withdrawals
DROP POLICY IF EXISTS "Riders can view their own withdrawals" ON public.rider_withdrawals;
CREATE POLICY "Riders can view their own withdrawals"
ON public.rider_withdrawals
FOR SELECT
TO authenticated
USING (auth.uid() = user_id);

-- Select policy: riders can view their own withdrawal events
DROP POLICY IF EXISTS "Riders can view their own withdrawal events" ON public.rider_withdrawal_events;
CREATE POLICY "Riders can view their own withdrawal events"
ON public.rider_withdrawal_events
FOR SELECT
TO authenticated
USING (
    EXISTS (
        SELECT 1 FROM public.rider_withdrawals w
        WHERE w.id = withdrawal_id AND w.user_id = auth.uid()
    )
);

-- Revoke execute permissions on SECURITY DEFINER functions from PUBLIC (anon/authenticated)
REVOKE EXECUTE ON FUNCTION public.initiate_withdrawal(numeric, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.fail_withdrawal(uuid, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.complete_withdrawal(uuid, text, text, jsonb) FROM PUBLIC;

-- Grant execute permissions specifically to service_role and postgres
GRANT EXECUTE ON FUNCTION public.initiate_withdrawal(numeric, uuid) TO service_role, postgres;
GRANT EXECUTE ON FUNCTION public.fail_withdrawal(uuid, jsonb) TO service_role, postgres;
GRANT EXECUTE ON FUNCTION public.complete_withdrawal(uuid, text, text, jsonb) TO service_role, postgres;
