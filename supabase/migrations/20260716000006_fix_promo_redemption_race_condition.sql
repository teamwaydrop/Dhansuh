-- Migration: Close the promo redemption race condition.
-- Date: 2026-07-16
--
-- validate_and_calculate_promo() checked uses_count >= max_uses with a
-- plain SELECT and no lock, while the actual uses_count increment happened
-- later via a separate AFTER INSERT trigger on user_promo_usages
-- (handle_promo_usage_changes), fired from a completely separate database
-- round-trip (create-order/index.ts calls validate_and_calculate_promo via
-- one RPC call, then inserts into user_promo_usages afterward once the
-- order is created). Because these are two different transactions, adding
-- FOR UPDATE to the validation SELECT alone cannot close the race — the row
-- lock is released as soon as that RPC call returns, before the later
-- insert/increment ever happens. Concurrent redemptions near the cap can
-- all read the same pre-increment uses_count and all pass validation.
--
-- Fix: validate_and_calculate_promo now atomically reserves a usage slot
-- via a single conditional UPDATE (enforcing the cap in the same statement
-- as the increment), so the cap can never be exceeded regardless of
-- concurrency. The increment is removed from the AFTER INSERT branch of
-- handle_promo_usage_changes to avoid double-counting (create-order is the
-- only inserter into user_promo_usages, and it always calls
-- validate_and_calculate_promo first) — the AFTER DELETE branch (decrement
-- on usage reversal) is left unchanged.

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
  -- 1. Fetch promo details, locking the row so concurrent redemptions of
  -- the same code are serialized against the reservation UPDATE below.
  SELECT * INTO v_promo
  FROM public.promo_codes
  WHERE code = UPPER(p_code)
    AND is_active = true
    AND expires_at > now()
  FOR UPDATE;

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

  -- 2. Verify min order value
  IF p_order_value < v_promo.min_order_value THEN
    RETURN jsonb_build_object('success', false, 'message', 'Minimum order value of ₹' || v_promo.min_order_value::text || ' is required');
  END IF;

  -- 3. Verify single usage per user
  SELECT count(*) INTO v_used_count
  FROM public.user_promo_usages
  WHERE user_id = p_user_id AND promo_code_id = v_promo.id;

  IF v_used_count > 0 THEN
    RETURN jsonb_build_object('success', false, 'message', 'You have already used this promo code');
  END IF;

  -- 4. Atomically reserve a usage slot, enforcing the global cap (if any)
  -- in the same statement as the increment so it can never be exceeded.
  UPDATE public.promo_codes
  SET uses_count = uses_count + 1
  WHERE id = v_promo.id
    AND (max_uses IS NULL OR uses_count < max_uses);

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'message', 'Promo code usage limit has been reached');
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

-- Remove the now-redundant increment on INSERT (validate_and_calculate_promo
-- reserves the slot atomically above); keep the decrement on DELETE for
-- usage-reversal scenarios.
CREATE OR REPLACE FUNCTION public.handle_promo_usage_changes()
RETURNS TRIGGER AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    UPDATE public.promo_codes
    SET uses_count = GREATEST(0, uses_count - 1)
    WHERE id = OLD.promo_code_id;
  END IF;
  RETURN NULL;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
