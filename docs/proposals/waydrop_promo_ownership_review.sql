-- PROPOSAL ONLY. The exact live definition with an ownership guard added.
-- Public execute is already revoked for anon. Preserve service-role order pricing.
-- Staging: same-user succeeds; another user's id gets 42501; server pricing unchanged.
BEGIN;
CREATE OR REPLACE FUNCTION public.validate_and_calculate_promo(p_code character varying, p_order_value numeric, p_user_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_promo record;
  v_used_count integer;
  v_discount numeric := 0.00;
BEGIN
  IF coalesce(auth.role(), '') <> 'service_role'
     AND (auth.uid() IS NULL OR auth.uid() IS DISTINCT FROM p_user_id) THEN
    RAISE EXCEPTION 'Promo checks must use the authenticated user' USING ERRCODE = '42501';
  END IF;
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
$function$
;
ALTER FUNCTION public.validate_and_calculate_promo(character varying,numeric,uuid)
  SET search_path = public, pg_temp;
REVOKE EXECUTE ON FUNCTION public.validate_and_calculate_promo(character varying,numeric,uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.validate_and_calculate_promo(character varying,numeric,uuid)
  TO authenticated, service_role;
ROLLBACK;
