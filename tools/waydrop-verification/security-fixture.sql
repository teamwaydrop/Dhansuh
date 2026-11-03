-- Synthetic local fixture for PostgreSQL authorization tests. No real account data.
-- This models the affected permissions/RLS/columns, not the complete production schema.
CREATE ROLE anon;
CREATE ROLE authenticated;
CREATE ROLE service_role BYPASSRLS;
CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS
  $$ SELECT nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
CREATE FUNCTION auth.role() RETURNS text LANGUAGE sql STABLE AS
  $$ SELECT nullif(current_setting('request.jwt.claim.role', true), '') $$;
GRANT USAGE ON SCHEMA auth, public TO anon, authenticated, service_role;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA auth TO anon, authenticated, service_role;

CREATE TABLE public.users (
 id uuid PRIMARY KEY, role text DEFAULT 'user', is_developer boolean DEFAULT false,
 is_suspended boolean DEFAULT false, full_name text, email text
);
CREATE TABLE public.rider_kyc (
 id uuid PRIMARY KEY, user_id uuid NOT NULL REFERENCES public.users(id),
 kyc_status text NOT NULL DEFAULT 'pending', activation_status text NOT NULL DEFAULT 'inactive',
 blocked_until timestamptz, rejection_reason text, full_name text
);
CREATE TABLE public.rider_payout_accounts (
 id uuid PRIMARY KEY, user_id uuid NOT NULL REFERENCES public.users(id),
 cashfree_beneficiary_status text DEFAULT 'pending'
);
ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.rider_kyc ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.rider_payout_accounts ENABLE ROW LEVEL SECURITY;
-- Same owner predicates as the catalog snapshot; an omitted UPDATE WITH CHECK
-- inherits USING in PostgreSQL, which these tests also verify.
CREATE POLICY "Users can view own profile" ON public.users FOR SELECT TO authenticated USING (auth.uid()=id);
CREATE POLICY "Users can insert own profile" ON public.users FOR INSERT TO authenticated WITH CHECK (auth.uid()=id);
CREATE POLICY "Users can update own profile" ON public.users FOR UPDATE TO authenticated USING (auth.uid()=id);
CREATE POLICY "Users can view own kyc" ON public.rider_kyc FOR SELECT TO authenticated USING (auth.uid()=user_id);
CREATE POLICY "Users can create own kyc" ON public.rider_kyc FOR INSERT TO authenticated WITH CHECK (auth.uid()=user_id);
CREATE POLICY "Users can update own kyc" ON public.rider_kyc FOR UPDATE TO authenticated USING (auth.uid()=user_id);
CREATE POLICY "admin_can_select_rider_kyc" ON public.rider_kyc FOR SELECT TO authenticated
USING (EXISTS (SELECT 1 FROM public.users u WHERE u.id=auth.uid() AND u.role='admin'));
CREATE POLICY "admin_can_update_rider_kyc" ON public.rider_kyc FOR UPDATE TO authenticated
USING (EXISTS (SELECT 1 FROM public.users u WHERE u.id=auth.uid() AND u.role='admin'))
WITH CHECK (EXISTS (SELECT 1 FROM public.users u WHERE u.id=auth.uid() AND u.role='admin'));
CREATE POLICY "rider_select_own_payout_account" ON public.rider_payout_accounts FOR SELECT TO authenticated USING (auth.uid()=user_id);
CREATE POLICY "rider_insert_own_payout_account" ON public.rider_payout_accounts FOR INSERT TO authenticated WITH CHECK (auth.uid()=user_id);
GRANT SELECT, INSERT, UPDATE ON public.users, public.rider_kyc, public.rider_payout_accounts TO authenticated;
GRANT ALL ON ALL TABLES IN SCHEMA public TO service_role;

CREATE VIEW public.parcel_compliance_view AS SELECT id, full_name, email FROM public.users;
CREATE VIEW public.parcel_security_timeline_view AS SELECT id, user_id, blocked_until FROM public.rider_kyc;
GRANT SELECT ON public.parcel_compliance_view, public.parcel_security_timeline_view TO PUBLIC, anon, authenticated, service_role;

CREATE TABLE public.promo_codes (
 id uuid PRIMARY KEY, code text, is_active boolean, expires_at timestamptz,
 audience_type text, max_uses integer, uses_count integer, min_order_value numeric,
 discount_type text, discount_value numeric, max_discount numeric
);
CREATE TABLE public.promo_code_users (promo_code_id uuid, user_id uuid);
CREATE TABLE public.user_promo_usages (promo_code_id uuid, user_id uuid);
-- No client table grants on promo tables: the real definer body must perform reads.

INSERT INTO public.users(id, full_name) VALUES
 ('00000000-0000-4000-8000-000000000001', 'Synthetic A'),
 ('00000000-0000-4000-8000-000000000002', 'Synthetic B');
INSERT INTO public.rider_kyc(id,user_id) VALUES
 ('10000000-0000-4000-8000-000000000001','00000000-0000-4000-8000-000000000001'),
 ('10000000-0000-4000-8000-000000000002','00000000-0000-4000-8000-000000000002');
INSERT INTO public.promo_codes VALUES
 ('20000000-0000-4000-8000-000000000001','OPEN',true,now()+interval '1 year','all',100,0,1,'percentage',10,50),
 ('20000000-0000-4000-8000-000000000002','ONLYB',true,now()+interval '1 year','restricted',100,0,1,'fixed_amount',20,null);
INSERT INTO public.promo_code_users VALUES ('20000000-0000-4000-8000-000000000002','00000000-0000-4000-8000-000000000002');
