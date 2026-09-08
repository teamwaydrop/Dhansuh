-- Migration: Add prefixed alphanumeric codes
-- Date: 2026-06-11

-- 1. Alter users and rider_travel_plans to add code columns
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS user_code text;
ALTER TABLE public.rider_travel_plans ADD COLUMN IF NOT EXISTS plan_code text;

-- 2. Alphanumeric random string generator
CREATE OR REPLACE FUNCTION public.generate_random_alphanumeric(p_length integer)
RETURNS text AS $$
DECLARE
    v_chars text := '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ';
    v_result text := '';
    i integer;
BEGIN
    FOR i IN 1..p_length LOOP
        v_result := v_result || substr(v_chars, floor(random() * length(v_chars) + 1)::integer, 1);
    END LOOP;
    RETURN v_result;
END;
$$ LANGUAGE plpgsql VOLATILE;

-- 3. Unique code generator functions
CREATE OR REPLACE FUNCTION public.generate_unique_user_code()
RETURNS text AS $$
DECLARE
    v_code text;
    v_exists boolean;
    v_attempts integer := 0;
BEGIN
    LOOP
        v_attempts := v_attempts + 1;
        v_code := 'WDU' || public.generate_random_alphanumeric(6);
        SELECT EXISTS(SELECT 1 FROM public.users WHERE user_code = v_code) INTO v_exists;
        IF NOT v_exists THEN
            RETURN v_code;
        END IF;
        IF v_attempts > 100 THEN
            RAISE EXCEPTION 'Failed to generate unique user_code after 100 attempts';
        END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION public.get_order_code_prefix(p_order_type text)
RETURNS text AS $$
BEGIN
    RETURN CASE p_order_type
        WHEN 'ride' THEN 'WDR'
        WHEN 'intercity_ride' THEN 'WDIR'
        WHEN 'local_parcel' THEN 'WDP'
        WHEN 'intercity_parcel' THEN 'WDIP'
        WHEN 'ride_sharing' THEN 'WDS'
        WHEN 'food_delivery' THEN 'WDF'
        WHEN 'grocery_delivery' THEN 'WDG'
        WHEN 'batch_delivery' THEN 'WDB'
        ELSE 'WD'
    END;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION public.generate_unique_order_code(p_order_type text)
RETURNS text AS $$
DECLARE
    v_prefix text;
    v_code text;
    v_exists boolean;
    v_attempts integer := 0;
BEGIN
    v_prefix := public.get_order_code_prefix(p_order_type);
    LOOP
        v_attempts := v_attempts + 1;
        v_code := v_prefix || public.generate_random_alphanumeric(6);
        SELECT EXISTS(SELECT 1 FROM public.orders WHERE order_code = v_code) INTO v_exists;
        IF NOT v_exists THEN
            RETURN v_code;
        END IF;
        IF v_attempts > 100 THEN
            RAISE EXCEPTION 'Failed to generate unique order_code after 100 attempts';
        END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION public.generate_unique_plan_code()
RETURNS text AS $$
DECLARE
    v_code text;
    v_exists boolean;
    v_attempts integer := 0;
BEGIN
    LOOP
        v_attempts := v_attempts + 1;
        v_code := 'WDTP' || public.generate_random_alphanumeric(6);
        SELECT EXISTS(SELECT 1 FROM public.rider_travel_plans WHERE plan_code = v_code) INTO v_exists;
        IF NOT v_exists THEN
            RETURN v_code;
        END IF;
        IF v_attempts > 100 THEN
            RAISE EXCEPTION 'Failed to generate unique plan_code after 100 attempts';
        END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION public.generate_unique_payment_code()
RETURNS text AS $$
DECLARE
    v_code text;
    v_exists boolean;
    v_attempts integer := 0;
BEGIN
    LOOP
        v_attempts := v_attempts + 1;
        v_code := 'WDTX' || public.generate_random_alphanumeric(6);
        SELECT EXISTS(SELECT 1 FROM public.payments WHERE payment_code = v_code) INTO v_exists;
        IF NOT v_exists THEN
            RETURN v_code;
        END IF;
        IF v_attempts > 100 THEN
            RAISE EXCEPTION 'Failed to generate unique payment_code after 100 attempts';
        END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION public.generate_unique_transfer_id()
RETURNS text AS $$
DECLARE
    v_code text;
    v_exists boolean;
    v_attempts integer := 0;
BEGIN
    LOOP
        v_attempts := v_attempts + 1;
        v_code := 'WDPY' || public.generate_random_alphanumeric(6);
        SELECT EXISTS(SELECT 1 FROM public.rider_withdrawals WHERE transfer_id = v_code) INTO v_exists;
        IF NOT v_exists THEN
            RETURN v_code;
        END IF;
        IF v_attempts > 100 THEN
            RAISE EXCEPTION 'Failed to generate unique transfer_id after 100 attempts';
        END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- 4. Trigger functions for automatic code population
CREATE OR REPLACE FUNCTION public.trg_users_user_code()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.user_code IS NULL OR NEW.user_code = '' THEN
        NEW.user_code := public.generate_unique_user_code();
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_populate_user_code ON public.users;
CREATE TRIGGER trg_populate_user_code
BEFORE INSERT ON public.users
FOR EACH ROW
EXECUTE FUNCTION public.trg_users_user_code();

CREATE OR REPLACE FUNCTION public.trg_orders_order_code()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.order_code IS NULL OR NEW.order_code = '' OR NEW.order_code LIKE 'WX%' THEN
        NEW.order_code := public.generate_unique_order_code(NEW.order_type::text);
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_populate_order_code ON public.orders;
CREATE TRIGGER trg_populate_order_code
BEFORE INSERT ON public.orders
FOR EACH ROW
EXECUTE FUNCTION public.trg_orders_order_code();

CREATE OR REPLACE FUNCTION public.trg_travel_plans_plan_code()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.plan_code IS NULL OR NEW.plan_code = '' THEN
        NEW.plan_code := public.generate_unique_plan_code();
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_populate_plan_code ON public.rider_travel_plans;
CREATE TRIGGER trg_populate_plan_code
BEFORE INSERT ON public.rider_travel_plans
FOR EACH ROW
EXECUTE FUNCTION public.trg_travel_plans_plan_code();

CREATE OR REPLACE FUNCTION public.trg_payments_payment_code()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.payment_code IS NULL OR NEW.payment_code = '' THEN
        NEW.payment_code := public.generate_unique_payment_code();
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_populate_payment_code ON public.payments;
CREATE TRIGGER trg_populate_payment_code
BEFORE INSERT ON public.payments
FOR EACH ROW
EXECUTE FUNCTION public.trg_payments_payment_code();

CREATE OR REPLACE FUNCTION public.trg_rider_withdrawals_transfer_id()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.transfer_id IS NULL OR NEW.transfer_id = '' OR NOT (NEW.transfer_id LIKE 'WDPY%') THEN
        NEW.transfer_id := public.generate_unique_transfer_id();
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_populate_transfer_id ON public.rider_withdrawals;
CREATE TRIGGER trg_populate_transfer_id
BEFORE INSERT ON public.rider_withdrawals
FOR EACH ROW
EXECUTE FUNCTION public.trg_rider_withdrawals_transfer_id();

-- 5. Backfill existing records safely
DO $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN SELECT id FROM public.users WHERE user_code IS NULL OR user_code = '' LOOP
        UPDATE public.users SET user_code = public.generate_unique_user_code() WHERE id = r.id;
    END LOOP;
END $$;

DO $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN SELECT id, order_type FROM public.orders WHERE order_code IS NULL OR order_code = '' OR order_code LIKE 'WX%' LOOP
        UPDATE public.orders SET order_code = public.generate_unique_order_code(r.order_type::text) WHERE id = r.id;
    END LOOP;
END $$;

DO $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN SELECT id FROM public.rider_travel_plans WHERE plan_code IS NULL OR plan_code = '' LOOP
        UPDATE public.rider_travel_plans SET plan_code = public.generate_unique_plan_code() WHERE id = r.id;
    END LOOP;
END $$;

DO $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN SELECT id FROM public.payments WHERE payment_code IS NULL OR payment_code = '' OR NOT (payment_code LIKE 'WDTX%') LOOP
        UPDATE public.payments SET payment_code = public.generate_unique_payment_code() WHERE id = r.id;
    END LOOP;
END $$;

DO $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN SELECT id FROM public.rider_withdrawals WHERE transfer_id IS NULL OR transfer_id = '' OR NOT (transfer_id LIKE 'WDPY%') LOOP
        UPDATE public.rider_withdrawals SET transfer_id = public.generate_unique_transfer_id() WHERE id = r.id;
    END LOOP;
END $$;

-- 6. Add unique constraints to the columns
ALTER TABLE public.users DROP CONSTRAINT IF EXISTS users_user_code_key;
ALTER TABLE public.users ADD CONSTRAINT users_user_code_key UNIQUE (user_code);

ALTER TABLE public.rider_travel_plans DROP CONSTRAINT IF EXISTS rider_travel_plans_plan_code_key;
ALTER TABLE public.rider_travel_plans ADD CONSTRAINT rider_travel_plans_plan_code_key UNIQUE (plan_code);

-- Also ensure order_code is unique if not already
ALTER TABLE public.orders DROP CONSTRAINT IF EXISTS orders_order_code_key;
ALTER TABLE public.orders ADD CONSTRAINT orders_order_code_key UNIQUE (order_code);

-- 7. Redefine public.initiate_withdrawal to use generate_unique_transfer_id()
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

    -- 5. Generate unique transfer_id using WDPY prefix
    v_transfer_id := public.generate_unique_transfer_id();

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
