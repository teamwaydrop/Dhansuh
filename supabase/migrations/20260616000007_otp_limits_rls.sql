-- Create otp_attempts table to track brute force attacks
CREATE TABLE IF NOT EXISTS public.otp_attempts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  phone varchar NOT NULL,
  attempted_at timestamp with time zone DEFAULT now(),
  is_successful boolean NOT NULL,
  otp_code varchar,
  client_ip varchar,
  action_type varchar NOT NULL CHECK (action_type in ('request', 'verify'))
);

-- Index phone and timestamp for fast lookups
CREATE INDEX IF NOT EXISTS idx_otp_attempts_phone_timestamp ON public.otp_attempts (phone, attempted_at DESC);

-- Enable RLS on otp_attempts
ALTER TABLE public.otp_attempts ENABLE ROW LEVEL SECURITY;

-- OTP Lockout Verification Checker
CREATE OR REPLACE FUNCTION public.check_otp_lockout(p_phone varchar)
RETURNS jsonb AS $$
DECLARE
  v_failed_count_15m integer;
  v_failed_count_24h integer;
  v_locked_until timestamp with time zone;
BEGIN
  -- 1. Check if there are 20+ failed attempts in the last 24h -> require a completely fresh OTP code
  SELECT count(*) INTO v_failed_count_24h
  FROM public.otp_attempts
  WHERE phone = p_phone
    AND action_type = 'verify'
    AND is_successful = false
    AND attempted_at >= now() - interval '24 hours';

  IF v_failed_count_24h >= 20 THEN
    RETURN jsonb_build_object(
      'locked', true,
      'lockout_type', 'fresh_issuance',
      'message', 'Too many failed verification attempts. Please request a fresh OTP code.',
      'retry_after_seconds', 0
    );
  END IF;

  -- 2. Check for 10 failed attempts within 24h -> 1 hour lockout
  IF v_failed_count_24h >= 10 THEN
    -- Find when the 10th failure occurred
    SELECT attempted_at + interval '1 hour' INTO v_locked_until
    FROM public.otp_attempts
    WHERE phone = p_phone
      AND action_type = 'verify'
      AND is_successful = false
      AND attempted_at >= now() - interval '24 hours'
    ORDER BY attempted_at DESC
    LIMIT 1 OFFSET 9;

    IF v_locked_until > now() THEN
      RETURN jsonb_build_object(
        'locked', true,
        'lockout_type', '1_hour',
        'message', 'Account locked for 1 hour due to 10 failed verification attempts.',
        'retry_after_seconds', extract(epoch from (v_locked_until - now()))::integer
      );
    END IF;
  END IF;

  -- 3. Check for 5 failed attempts in the last 15m -> 15 min lockout
  SELECT count(*) INTO v_failed_count_15m
  FROM public.otp_attempts
  WHERE phone = p_phone
    AND action_type = 'verify'
    AND is_successful = false
    AND attempted_at >= now() - interval '15 minutes';

  IF v_failed_count_15m >= 5 THEN
    -- Find when the 5th failure occurred
    SELECT attempted_at + interval '15 minutes' INTO v_locked_until
    FROM public.otp_attempts
    WHERE phone = p_phone
      AND action_type = 'verify'
      AND is_successful = false
      AND attempted_at >= now() - interval '15 minutes'
    ORDER BY attempted_at DESC
    LIMIT 1 OFFSET 4;

    IF v_locked_until > now() THEN
      RETURN jsonb_build_object(
        'locked', true,
        'lockout_type', '15_minutes',
        'message', 'Account locked for 15 minutes due to 5 incorrect OTP attempts.',
        'retry_after_seconds', extract(epoch from (v_locked_until - now()))::integer
      );
    END IF;
  END IF;

  RETURN jsonb_build_object('locked', false);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Revoke public permissions on check_otp_lockout
REVOKE EXECUTE ON FUNCTION public.check_otp_lockout(varchar) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.check_otp_lockout(varchar) TO service_role, postgres;

-- Helper to log OTP attempts
CREATE OR REPLACE FUNCTION public.log_otp_attempt(
  p_phone varchar,
  p_is_successful boolean,
  p_action_type varchar,
  p_otp_code varchar DEFAULT NULL,
  p_client_ip varchar DEFAULT NULL
)
RETURNS void AS $$
BEGIN
  INSERT INTO public.otp_attempts (phone, is_successful, action_type, otp_code, client_ip)
  VALUES (p_phone, p_is_successful, p_action_type, p_otp_code, p_client_ip);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Revoke public permissions on log_otp_attempt
REVOKE EXECUTE ON FUNCTION public.log_otp_attempt(varchar, boolean, varchar, varchar, varchar) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.log_otp_attempt(varchar, boolean, varchar, varchar, varchar) TO service_role, postgres;


-- Create trip_share_tokens table
CREATE TABLE IF NOT EXISTS public.trip_share_tokens (
  token_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL,
  token varchar NOT NULL UNIQUE,
  expires_at timestamp with time zone NOT NULL,
  is_revoked boolean DEFAULT false,
  access_count integer DEFAULT 0,
  last_accessed_at timestamp with time zone,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT trip_share_tokens_order_id_fkey FOREIGN KEY (order_id) REFERENCES public.orders(id) ON DELETE CASCADE
);

-- Enable RLS on trip_share_tokens
ALTER TABLE public.trip_share_tokens ENABLE ROW LEVEL SECURITY;

-- Trip Sharing Policies
DROP POLICY IF EXISTS "Allow public read of active unexpired share tokens" ON public.trip_share_tokens;
CREATE POLICY "Allow public read of active unexpired share tokens"
ON public.trip_share_tokens
FOR SELECT
USING (is_revoked = false AND expires_at > now());

DROP POLICY IF EXISTS "Allow owners and riders of orders to manage share tokens" ON public.trip_share_tokens;
CREATE POLICY "Allow owners and riders of orders to manage share tokens"
ON public.trip_share_tokens
FOR ALL
TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.orders o
    WHERE o.id = order_id AND (
      o.user_id = auth.uid() OR 
      o.rider_id = (SELECT id FROM public.riders r WHERE r.user_id = auth.uid())
    )
  )
);

-- Auto-expire trip sharing tokens trigger function
CREATE OR REPLACE FUNCTION public.expire_trip_sharing_tokens()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.order_status IN ('completed', 'delivered', 'cancelled') THEN
    UPDATE public.trip_share_tokens
    SET is_revoked = true
    WHERE order_id = NEW.id;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS trigger_expire_trip_sharing_tokens ON public.orders;
CREATE TRIGGER trigger_expire_trip_sharing_tokens
AFTER UPDATE OF order_status ON public.orders
FOR EACH ROW
EXECUTE FUNCTION public.expire_trip_sharing_tokens();


-- Explicitly audit and enable RLS on critical production tables
ALTER TABLE public.orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.rider_assignments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.wallet_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.trip_share_tokens ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.order_chat_messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.police_sos_logs ENABLE ROW LEVEL SECURITY;
