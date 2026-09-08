# WayDrop Technical Documentation — Operational Runbook

**Version:** 1.0  
**Last Updated:** July 5, 2026  
**Maintainer:** Lead Ops Engineer  
**Applies To Commit:** 241d836  

---

## 1. Modifying & Expanding Serviceable Zones

When launching WayDrop in a new city or expanding service boundaries, follow these steps to register the new zone:

### 1.1. Add a Pricing Zone
Add a new row to the **`pricing_zones`** table:
```sql
INSERT INTO public.pricing_zones (
    zone_name,
    center_lat,
    center_lng,
    geofence_radius_km,
    is_active
) VALUES (
    'Hyderabad City',
    17.3850,
    78.4867,
    25.0,  -- 25 km geofence radius
    true
);
```

### 1.2. Configure Service Rates
Add matching configurations to the **`pricing_config`** table for the new zone:
```sql
INSERT INTO public.pricing_config (
    zone_id,
    vehicle_type,
    base_fare,
    per_km_charge,
    per_minute_charge,
    platform_fee,
    commission_percentage
) VALUES (
    'zone-uuid-from-step-1.1',
    'bike',
    30.00,  -- 30 INR Base fare
    8.00,   -- 8 INR per kilometer
    1.50,   -- 1.5 INR per minute
    5.00,   -- 5 INR Platform fee
    15.00   -- 15% Platform commission
);
```

---

## 2. Manual KYC Verification Approvals

If a rider's automated KYC validation fails due to document quality issues, administrators can review and approve submissions manually:

1. **Verify Documents:** Log into the Supabase dashboard and inspect the document scans in the `kyc_docs` storage bucket.
2. **Approve Submission:** Run the following query to approve the KYC record and activate the rider's profile:
   ```sql
   -- 1. Approve KYC status
   UPDATE public.rider_kyc
   SET kyc_status = 'approved',
       activation_status = 'active',
       rejection_reason = NULL,
       updated_at = NOW()
   WHERE user_id = 'target-user-uuid';

   -- 2. Create the rider profile if it does not exist
   INSERT INTO public.riders (user_id, wallet_balance, account_status)
   VALUES ('target-user-uuid', 0.00, 'offline')
   ON CONFLICT (user_id) DO NOTHING;
   ```
3. **Notify Rider:** The database trigger on the `riders` table will automatically send a push notification: "Your KYC has been approved! Switch to Rider Mode to start earning."

---

## 3. Webhook Recovery & Manual Payments Reconciliation

If the Cashfree webhook fails to deliver a payment confirmation:

1. **Verify Transaction:** Log into the Cashfree merchant dashboard and verify the payment status using the `order_id` (e.g. `WDP100234`).
2. **Manual Reconciliation:** If the transaction is confirmed as successful, run the following query to update the order status manually:
   ```sql
   -- 1. Update the payment record status
   UPDATE public.payments
   SET status = 'success',
       updated_at = NOW()
   WHERE order_id = 'target-order-uuid';

   -- 2. Update the order status and payment details
   UPDATE public.orders
   SET payment_status = 'paid',
       order_status = 'searching'
   WHERE id = 'target-order-uuid';
   ```
3. **Trigger Dispatch:** Invoke the `start-dispatch` Edge Function manually to start matching the order with nearby riders:
   ```bash
   curl -i -X POST \
     -H "Content-Type: application/json" \
     -H "Authorization: Bearer YOUR_SERVICE_ROLE_KEY" \
     -d '{"order_id": "target-order-uuid"}' \
     https://yvwpchffctiagevpqgwy.supabase.co/functions/v1/start-dispatch
   ```

### 3.1. Subscription Entitlement Recovery (Payment Captured, Entitlement Not Activated)

Cashfree confirming a payment and the rider actually receiving their WayDrop MAX entitlement are
two separate writes (`cashfree-webhook`/`verify-payment`: first `payments.payment_status='paid'`,
then a second `riders` UPDATE that activates the subscription). If the second write fails after
the first succeeds — a transient DB error, for example — the webhook returns a 500, Cashfree
retries it, and the retry's own idempotency check (`payment.payment_status === "paid"` →
`"ALREADY PROCESSED"`) exits before ever reaching the entitlement code again. The rider is charged
but never gets 0% commission. There is no automatic retry for this specific gap today.

1. **Identify the affected payment.** A `payments` row with `payment_for = 'subscription'` and
   `payment_status = 'paid'`, where the corresponding rider's `subscription_active`/
   `subscription_expires_at` do not reflect it:
   ```sql
   SELECT p.id AS payment_id, p.rider_id, p.plan_id, p.final_amount, p.paid_at,
          r.subscription_active, r.subscription_expires_at, r.commission_waiver_active
   FROM public.payments p
   JOIN public.riders r ON r.id = p.rider_id
   WHERE p.payment_for = 'subscription'
     AND p.payment_status = 'paid'
     AND NOT EXISTS (
       SELECT 1 FROM public.rider_subscription_history h WHERE h.payment_id = p.id
     )
   ORDER BY p.paid_at DESC;
   ```
   No `rider_subscription_history` row for an already-paid subscription payment is the reliable
   signal — that insert only ever happens in the same code path as the entitlement activation
   itself (see `cashfree-webhook/index.ts`'s `rider_subscription_history` insert), so its absence
   means activation never completed.
2. **Look up the plan's duration** (never guess it — this must come from `subscription_plans`,
   the same source `cashfree-webhook`/`verify-payment` use):
   ```sql
   SELECT duration_hours FROM public.subscription_plans WHERE plan_id = 'the-payment-row-plan_id';
   ```
3. **Manually activate the entitlement**, computing `subscription_expires_at` from *now* (or from
   the rider's existing `subscription_expires_at` if it's still in the future — i.e. extend an
   active subscription rather than shortening it, exactly like `computeSubscriptionExpiry()` does):
   ```sql
   UPDATE public.riders
   SET commission_waiver_active = true,
       subscription_active = true,
       subscription_expires_at = GREATEST(NOW(), COALESCE(subscription_expires_at, NOW()))
                                  + (SELECT duration_hours FROM public.subscription_plans
                                     WHERE plan_id = 'the-payment-row-plan_id') * INTERVAL '1 hour'
   WHERE id = 'the-payment-row-rider_id';
   ```
4. **Record the history row** so this reconciliation is auditable and so the query in step 1 never
   flags this payment again:
   ```sql
   INSERT INTO public.rider_subscription_history
     (rider_id, amount, payment_status, payment_id, starts_at, expires_at, is_active)
   SELECT 'the-payment-row-rider_id', p.final_amount, 'paid', p.id, NOW(),
          r.subscription_expires_at, true
   FROM public.payments p, public.riders r
   WHERE p.id = 'the-payment-row-payment_id' AND r.id = 'the-payment-row-rider_id'
   ON CONFLICT DO NOTHING; -- idx_unique_subscription_payment on (payment_id) makes this idempotent
   ```

This procedure has no equivalent automatic trigger — it must be run manually per affected
payment, found via the step-1 query. This gap is tracked as Phase 5 Gap D; a root-cause fix
(narrowing the race itself) is a separate, not-yet-approved decision.

---

## 4. Secret Rotations & API Credentials Updates

To rotate third-party API credentials (e.g. rotating Cashfree keys or Google service accounts):

1. **Set New Secrets:** Use the Supabase CLI to update the variables:
   ```bash
   supabase secrets set CASHFREE_SECRET_KEY="new-secret-key"
   ```
2. **Verify Deployment:** Check the Edge Function logs to verify they are using the new secrets. The CLI automatically restarts the Edge Function runtime instances to apply the updated secrets immediately.
