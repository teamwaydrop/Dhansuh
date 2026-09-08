-- Create promo_codes table
CREATE TABLE IF NOT EXISTS public.promo_codes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code varchar NOT NULL UNIQUE,
  discount_type varchar NOT NULL CHECK (discount_type in ('percentage', 'fixed_amount')),
  discount_value numeric(10, 2) NOT NULL,
  max_discount numeric(10, 2), -- Cap on percentage discounts
  min_order_value numeric(10, 2) DEFAULT 0.00,
  expires_at timestamp with time zone NOT NULL,
  max_uses integer, -- Overall global usage limit
  uses_count integer DEFAULT 0,
  is_active boolean DEFAULT true,
  audience_type varchar NOT NULL DEFAULT 'everyone' CHECK (audience_type in ('everyone', 'restricted')),
  created_at timestamp with time zone DEFAULT now()
);

-- Index promo code searches
CREATE INDEX IF NOT EXISTS idx_promo_codes_code ON public.promo_codes (code);

-- Enable RLS on promo_codes
ALTER TABLE public.promo_codes ENABLE ROW LEVEL SECURITY;

-- Create promo_code_users table to restrict targeted promo codes to specific users
CREATE TABLE IF NOT EXISTS public.promo_code_users (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  promo_code_id uuid NOT NULL REFERENCES public.promo_codes(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT promo_code_users_unique UNIQUE(promo_code_id, user_id)
);

-- Enable RLS on promo_code_users
ALTER TABLE public.promo_code_users ENABLE ROW LEVEL SECURITY;

-- Select policy: users can only view their own assignments
DROP POLICY IF EXISTS "Users can view their own promo assignments" ON public.promo_code_users;
CREATE POLICY "Users can view their own promo assignments"
ON public.promo_code_users
FOR SELECT
TO authenticated
USING (user_id = auth.uid());

-- Select policy: read active and applicable promo codes
DROP POLICY IF EXISTS "Allow public read access to active promos" ON public.promo_codes;
DROP POLICY IF EXISTS "Allow read access to active and applicable promos" ON public.promo_codes;
CREATE POLICY "Allow read access to active and applicable promos"
ON public.promo_codes
FOR SELECT
TO authenticated
USING (
  is_active = true 
  AND expires_at > now()
  AND (
    audience_type = 'everyone'
    OR EXISTS (
      SELECT 1 FROM public.promo_code_users pcu
      WHERE pcu.promo_code_id = id AND pcu.user_id = auth.uid()
    )
  )
);

-- Create user_promo_usages table to prevent multiple uses per user
CREATE TABLE IF NOT EXISTS public.user_promo_usages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  promo_code_id uuid NOT NULL REFERENCES public.promo_codes(id) ON DELETE CASCADE,
  used_at timestamp with time zone DEFAULT now(),
  order_id uuid REFERENCES public.orders(id) ON DELETE CASCADE,
  CONSTRAINT user_promo_usages_user_promo_unique UNIQUE(user_id, promo_code_id)
);

-- Enable RLS on user_promo_usages
ALTER TABLE public.user_promo_usages ENABLE ROW LEVEL SECURITY;

-- Select/Insert policies: users can see and register their own usages
DROP POLICY IF EXISTS "Users can view their own promo usages" ON public.user_promo_usages;
CREATE POLICY "Users can view their own promo usages"
ON public.user_promo_usages
FOR SELECT
TO authenticated
USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can record their own promo usage" ON public.user_promo_usages;
CREATE POLICY "Users can record their own promo usage"
ON public.user_promo_usages
FOR INSERT
TO authenticated
WITH CHECK (auth.uid() = user_id);

-- Trigger function to automatically manage uses_count in promo_codes
CREATE OR REPLACE FUNCTION public.handle_promo_usage_changes()
RETURNS TRIGGER AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    UPDATE public.promo_codes
    SET uses_count = uses_count + 1
    WHERE id = NEW.promo_code_id;
  ELSIF TG_OP = 'DELETE' THEN
    UPDATE public.promo_codes
    SET uses_count = GREATEST(0, uses_count - 1)
    WHERE id = OLD.promo_code_id;
  END IF;
  RETURN NULL;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS trigger_handle_promo_usage_changes ON public.user_promo_usages;
CREATE TRIGGER trigger_handle_promo_usage_changes
AFTER INSERT OR DELETE ON public.user_promo_usages
FOR EACH ROW
EXECUTE FUNCTION public.handle_promo_usage_changes();

-- Seed default promo codes
INSERT INTO public.promo_codes (code, discount_type, discount_value, max_discount, min_order_value, expires_at, max_uses, audience_type) VALUES
  ('FIRST50', 'fixed_amount', 50.00, NULL, 100.00, '2030-12-31 23:59:59+00', 10000, 'everyone'),
  ('WAYDROP20', 'percentage', 20.00, 100.00, 0.00, '2030-12-31 23:59:59+00', 50000, 'everyone')
ON CONFLICT (code) DO UPDATE SET
  discount_type = excluded.discount_type,
  discount_value = excluded.discount_value,
  max_discount = excluded.max_discount,
  min_order_value = excluded.min_order_value,
  expires_at = excluded.expires_at,
  max_uses = excluded.max_uses,
  audience_type = excluded.audience_type;

-- Helper function to validate and calculate promo discounts
CREATE OR REPLACE FUNCTION public.validate_and_calculate_promo(
  p_code varchar,
  p_order_value numeric,
  p_user_id uuid
)
RETURNS jsonb AS $$
DECLARE
  v_promo record;
  v_used_count integer;
  v_discount numeric := 0.00;
BEGIN
  -- 1. Fetch promo details
  SELECT * INTO v_promo
  FROM public.promo_codes
  WHERE code = UPPER(p_code)
    AND is_active = true
    AND expires_at > now();

  IF v_promo.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'message', 'Invalid or expired promo code');
  END IF;

  -- 1.5 Verify audience constraints
  IF v_promo.audience_type = 'restricted' THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.promo_code_users
      WHERE promo_code_id = v_promo.id AND user_id = p_user_id
    ) THEN
      RETURN jsonb_build_object('success', false, 'message', 'This promo code is not valid for your account');
    END IF;
  END IF;

  -- 2. Verify global usage limit
  IF v_promo.max_uses IS NOT NULL AND v_promo.uses_count >= v_promo.max_uses THEN
    RETURN jsonb_build_object('success', false, 'message', 'Promo code usage limit has been reached');
  END IF;

  -- 3. Verify min order value
  IF p_order_value < v_promo.min_order_value THEN
    RETURN jsonb_build_object('success', false, 'message', 'Minimum order value of ₹' || v_promo.min_order_value::text || ' is required');
  END IF;

  -- 4. Verify single usage per user
  SELECT count(*) INTO v_used_count
  FROM public.user_promo_usages
  WHERE user_id = p_user_id AND promo_code_id = v_promo.id;

  IF v_used_count > 0 THEN
    RETURN jsonb_build_object('success', false, 'message', 'You have already used this promo code');
  END IF;

  -- 5. Calculate discount amount
  IF v_promo.discount_type = 'fixed_amount' THEN
    v_discount := LEAST(v_promo.discount_value, p_order_value);
  ELSIF v_promo.discount_type = 'percentage' THEN
    v_discount := (p_order_value * (v_promo.discount_value / 100.00));
    IF v_promo.max_discount IS NOT NULL THEN
      v_discount := LEAST(v_discount, v_promo.max_discount);
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'promo_id', v_promo.id,
    'discount_amount', round(v_discount, 2),
    'discount_type', v_promo.discount_type,
    'discount_value', v_promo.discount_value
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Revoke public permissions
REVOKE EXECUTE ON FUNCTION public.validate_and_calculate_promo(varchar, numeric, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.validate_and_calculate_promo(varchar, numeric, uuid) TO service_role, postgres, authenticated;
