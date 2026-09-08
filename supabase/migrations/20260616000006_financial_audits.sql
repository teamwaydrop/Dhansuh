-- Create wallet_transactions table
CREATE TABLE IF NOT EXISTS public.wallet_transactions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  rider_id uuid NOT NULL,
  amount numeric(10, 2) NOT NULL,
  type varchar NOT NULL CHECK (type in ('credit', 'debit', 'bonus', 'settlement', 'adjustment')),
  reference_id uuid NOT NULL, -- Links to order_id, withdrawal_id, etc.
  reference_type varchar NOT NULL CHECK (reference_type in ('order', 'withdrawal', 'settlement', 'bonus')),
  description text,
  created_at timestamp with time zone DEFAULT now(),
  CONSTRAINT wallet_transactions_rider_id_fkey FOREIGN KEY (rider_id) REFERENCES public.riders(id) ON DELETE CASCADE
);

-- Enable RLS on wallet_transactions
ALTER TABLE public.wallet_transactions ENABLE ROW LEVEL SECURITY;

-- Select policy: riders can only view their own transactions
DROP POLICY IF EXISTS "Riders can view their own wallet transactions" ON public.wallet_transactions;
CREATE POLICY "Riders can view their own wallet transactions"
ON public.wallet_transactions
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.riders r
    WHERE r.id = rider_id AND r.user_id = auth.uid()
  )
);

-- Immutable Ledger Trigger: Prevent update or delete operations on wallet_transactions
CREATE OR REPLACE FUNCTION public.prevent_wallet_transaction_modifications()
RETURNS TRIGGER AS $$
BEGIN
    RAISE EXCEPTION 'Immutable Ledger Error: Wallet transactions cannot be updated or deleted.';
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trigger_prevent_wallet_transaction_mods ON public.wallet_transactions;
CREATE TRIGGER trigger_prevent_wallet_transaction_mods
BEFORE UPDATE OR DELETE ON public.wallet_transactions
FOR EACH ROW
EXECUTE FUNCTION public.prevent_wallet_transaction_modifications();

-- Create wallet_audit_logs table to store results of nightly checks
CREATE TABLE IF NOT EXISTS public.wallet_audit_logs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  run_at timestamp with time zone DEFAULT now(),
  discrepancies_found integer NOT NULL,
  details jsonb
);

-- Enable RLS on wallet_audit_logs (only admins/service role can access)
ALTER TABLE public.wallet_audit_logs ENABLE ROW LEVEL SECURITY;

-- Nightly Ledger Auditor Function
CREATE OR REPLACE FUNCTION public.audit_rider_wallets()
RETURNS jsonb AS $$
DECLARE
  v_discrepancy_count integer := 0;
  v_details jsonb;
BEGIN
  -- Find all riders where wallet_balance != sum of wallet_transactions
  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'rider_id', r.id,
    'wallet_balance', r.wallet_balance,
    'ledger_sum', coalesce(sum(t.amount), 0)
  )), '[]'::jsonb)
  INTO v_details
  FROM public.riders r
  LEFT JOIN public.wallet_transactions t ON t.rider_id = r.id
  GROUP BY r.id, r.wallet_balance
  HAVING r.wallet_balance != coalesce(sum(t.amount), 0);

  v_discrepancy_count := jsonb_array_length(v_details);

  -- Log the run results
  INSERT INTO public.wallet_audit_logs (discrepancies_found, details)
  VALUES (v_discrepancy_count, v_details);

  RETURN jsonb_build_object(
    'success', true,
    'discrepancies_found', v_discrepancy_count,
    'details', v_details
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Revoke public permissions on audit function
REVOKE EXECUTE ON FUNCTION public.audit_rider_wallets() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.audit_rider_wallets() TO service_role, postgres;

-- Create Settlement Reconciliation View
CREATE OR REPLACE VIEW public.settlement_reconciliation_summary AS
SELECT
  o.id AS order_id,
  o.rider_id,
  o.final_fare,
  o.order_status,
  o.payment_mode,
  o.payment_status,
  -- Cash Collected: Fare paid in cash directly to rider on completed rides
  CASE 
    WHEN o.payment_mode = 'cash' AND o.order_status IN ('completed', 'delivered') THEN o.final_fare 
    ELSE 0.00
  END AS cash_collected,
  -- Wallet Credits: Fare transactions processed for this order context
  coalesce((
    SELECT sum(amount) 
    FROM public.wallet_transactions 
    WHERE reference_id = o.id AND reference_type = 'order'
  ), 0.00) AS wallet_transaction_sum,
  -- Settlements: Sum of success payouts/withdrawals processed for this rider
  coalesce((
    SELECT sum(amount)
    FROM public.rider_withdrawals
    WHERE rider_id = o.rider_id AND status = 'success'
  ), 0.00) AS total_settlements
FROM public.orders o;
