-- PROPOSAL ONLY. NOT APPLIED. Review and test on an isolated staging database first.
-- Snapshot: Waydrop catalog, 2026-10-31. No production records are changed by this file.
-- ROLLBACK is deliberate. Replace only after explicit deployment approval.
BEGIN;

-- Anonymous and regular application sessions have no compliance-investigation role.
-- No Flutter call sites for these views were found. Preserve service/SQL access.
REVOKE SELECT ON public.parcel_compliance_view,
  public.parcel_security_timeline_view FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.parcel_compliance_view,
  public.parcel_security_timeline_view TO service_role;

-- Internal schedulers/dispatch helpers have no caller identity checks. These exact
-- overloads are currently anon-executable. Cron/definer-owner calls remain possible.
REVOKE EXECUTE ON FUNCTION public.expire_stale_searching_orders(),
  public.redispatch_stalled_searching_orders(),
  public.expire_stale_active_orders(),
  public.expire_stale_intercity_requests(),
  public.redispatch_freed_riders(),
  public.assign_new_order_to_nearby_online_riders_core(uuid),
  public.send_order_status_notifications_core(uuid,text,text,text,integer,text,text,uuid,uuid,text,text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.expire_stale_searching_orders(),
  public.redispatch_stalled_searching_orders(),
  public.expire_stale_active_orders(),
  public.expire_stale_intercity_requests(),
  public.redispatch_freed_riders(),
  public.assign_new_order_to_nearby_online_riders_core(uuid),
  public.send_order_status_notifications_core(uuid,text,text,text,integer,text,text,uuid,uuid,text,text)
  TO service_role;

-- Existing prevent_role_self_escalation protects UPDATE only. An authenticated
-- account without a profile can currently INSERT its own row with role=admin.
-- Also protect suspension from owner updates. Keep the existing trigger intact.
CREATE OR REPLACE FUNCTION public.guard_client_user_security_fields()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF coalesce(auth.role(), '') IN ('anon', 'authenticated') THEN
    IF auth.uid() IS NULL THEN
      RAISE EXCEPTION 'An authenticated identity is required' USING ERRCODE = '42501';
    END IF;
    IF TG_OP = 'INSERT' THEN
      IF coalesce(NEW.role, 'user') <> 'user' OR NEW.is_developer IS TRUE
         OR NEW.is_suspended IS TRUE THEN
        RAISE EXCEPTION 'Security fields can only be assigned by the server'
          USING ERRCODE = '42501';
      END IF;
    ELSIF NEW.is_suspended IS DISTINCT FROM OLD.is_suspended THEN
      RAISE EXCEPTION 'Suspension can only be changed by the server' USING ERRCODE = '42501';
    END IF;
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.guard_client_user_security_fields() FROM PUBLIC, anon, authenticated;
CREATE TRIGGER guard_client_user_security_fields
BEFORE INSERT OR UPDATE ON public.users FOR EACH ROW
EXECUTE FUNCTION public.guard_client_user_security_fields();

-- Ownership RLS is not authorization to approve one's own KYC. Existing client
-- submissions go through create/validate-rider-kyc service-role Edge Functions.
CREATE OR REPLACE FUNCTION public.guard_client_kyc_decisions()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF coalesce(auth.role(), '') IN ('anon', 'authenticated') THEN
    IF auth.uid() IS NULL THEN
      RAISE EXCEPTION 'An authenticated identity is required' USING ERRCODE = '42501';
    END IF;
    -- Preserve existing staff review policies. This does not grant any RLS
    -- access; it only permits fields an existing policy already authorizes.
    -- Roles are read from protected database columns, never user metadata.
    IF EXISTS (
      SELECT 1 FROM public.users AS reviewer
      WHERE reviewer.id = auth.uid()
        AND reviewer.role IN ('admin', 'support')
        AND reviewer.is_suspended IS NOT TRUE
    ) THEN
      RETURN NEW;
    END IF;
    IF TG_OP = 'INSERT' THEN
      IF NEW.kyc_status::text IS DISTINCT FROM 'pending' OR NEW.activation_status::text IS DISTINCT FROM 'inactive'
         OR NEW.blocked_until IS NOT NULL OR NEW.rejection_reason IS NOT NULL THEN
        RAISE EXCEPTION 'KYC decisions can only be assigned by the server' USING ERRCODE = '42501';
      END IF;
    ELSIF NEW.kyc_status IS DISTINCT FROM OLD.kyc_status
       OR NEW.activation_status IS DISTINCT FROM OLD.activation_status
       OR NEW.blocked_until IS DISTINCT FROM OLD.blocked_until
       OR NEW.rejection_reason IS DISTINCT FROM OLD.rejection_reason THEN
      RAISE EXCEPTION 'KYC decisions can only be changed by the server' USING ERRCODE = '42501';
    END IF;
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.guard_client_kyc_decisions() FROM PUBLIC, anon, authenticated;
CREATE TRIGGER guard_client_kyc_decisions BEFORE INSERT OR UPDATE ON public.rider_kyc
FOR EACH ROW EXECUTE FUNCTION public.guard_client_kyc_decisions();

-- Existing UPI protection does not guard Cashfree beneficiary activation.
CREATE OR REPLACE FUNCTION public.guard_client_payout_activation()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF coalesce(auth.role(), '') IN ('anon', 'authenticated') THEN
    IF auth.uid() IS NULL THEN
      RAISE EXCEPTION 'An authenticated identity is required' USING ERRCODE = '42501';
    END IF;
    IF TG_OP = 'INSERT' THEN
      IF NEW.cashfree_beneficiary_status::text = 'active' THEN
        RAISE EXCEPTION 'Payout activation requires server verification' USING ERRCODE = '42501';
      END IF;
    ELSIF NEW.cashfree_beneficiary_status IS DISTINCT FROM OLD.cashfree_beneficiary_status THEN
      RAISE EXCEPTION 'Payout activation requires server verification' USING ERRCODE = '42501';
    END IF;
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.guard_client_payout_activation() FROM PUBLIC, anon, authenticated;
CREATE TRIGGER guard_client_payout_activation BEFORE INSERT OR UPDATE ON public.rider_payout_accounts
FOR EACH ROW EXECUTE FUNCTION public.guard_client_payout_activation();

-- Seven privileged routines lack a fixed search path. Qualified relation/type
-- names and extension resolution must be exercised with their real callers first.
ALTER FUNCTION public.handle_promo_usage_changes() SET search_path = public, pg_temp;
ALTER FUNCTION public.validate_and_calculate_promo(character varying,numeric,uuid) SET search_path = public, pg_temp;
ALTER FUNCTION public.fail_withdrawal(uuid,jsonb) SET search_path = public, pg_temp;
ALTER FUNCTION public.complete_withdrawal(uuid,text,text,jsonb) SET search_path = public, pg_temp;
ALTER FUNCTION public.expire_trip_sharing_tokens() SET search_path = public, pg_temp;
ALTER FUNCTION public.check_otp_lockout(character varying) SET search_path = public, pg_temp;
ALTER FUNCTION public.log_otp_attempt(character varying,boolean,character varying,character varying,character varying)
  SET search_path = public, pg_temp;

-- Required staging checks:
-- 1. anon cannot SELECT either private view or EXECUTE the seven internal RPCs.
-- 2. normal authenticated INSERT users(role='admin'/is_developer=true) fails;
--    INSERT own normal profile succeeds; UPDATE role/developer/suspension fails.
-- 3. owner cannot self-approve, activate or unblock KYC, or insert active payout.
-- 4. authenticated cross-user reads/writes remain denied by RLS.
-- 5. service-role KYC approval, payout setup, payments, withdrawals, notification
--    delivery and cron dispatch complete using their existing caller contracts.
-- 6. replay the original catalog snapshot to define rollback; do not blindly
--    re-grant access or remove existing policies/triggers.
ROLLBACK;
