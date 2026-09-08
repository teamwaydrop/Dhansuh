import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "npm:@supabase/supabase-js@2";
import { fetchWithTimeout } from "../_shared/http.ts";
import { getProductionConfig, isFeatureEnabled } from "../_shared/production_config_cache.ts";

// =====================================================
// CORS
// =====================================================

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

// =====================================================
// SUPABASE
// =====================================================

const supabaseAdmin = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

// =====================================================
// CASHFREE (PRODUCTION ONLY. No sandbox branch, no CASHFREE_ENV switch.)
// =====================================================

const CASHFREE_APP_ID = Deno.env.get("CASHFREE_APP_ID")!;
const CASHFREE_SECRET_KEY = Deno.env.get("CASHFREE_SECRET_KEY")!;
const CASHFREE_BASE_URL = "https://api.cashfree.com/pg";
const CASHFREE_API_VERSION = "2025-01-01";

// Passenger fare payment_for values -- these replace the old direct-to-driver
// upi://pay deep link (which banks/NPCI reliably block: a driver's personal
// VPA receiving small repeated payments from many rotating passengers is
// exactly the pattern flagged as mule-account activity, regardless of which
// UPI app sends it). The fare is now collected into the platform's own
// Cashfree merchant account instead, same as any other ride-hailing app, and
// the driver is credited via their existing wallet + Cashfree Payouts
// withdrawal flow. These values already exist in the DB's payment_for_enum.
const ORDER_FARE_TYPES = new Set([
  "ride_order",
  "parcel_order",
  "intercity_ride_order",
  "intercity_parcel_order",
  "ride_sharing",
]);

// Government Tax Due repayment -- deliberately its own payment_for, distinct from
// 'subscription' (activates a commission-free plan) and every fare type above (settles one
// specific order). This one settles a rider's overall tax-due balance and activates nothing.
// See migration 20260726000003_government_tax_due_schema.sql.
const TAX_DUE_PAYMENT_FOR = "tax_due";

// "Cash to be Paid" (COD Settlement) -- the platform's commission share owed by a rider who
// settled a ride/parcel by collecting cash/personal-UPI directly (riders.cod_pending_amount).
// Same shape as tax_due: settles an overall balance, activates nothing, full-balance-only for
// this first implementation. See migration 20260808000011_cod_settlement_payment_flow.sql.
const COD_SETTLEMENT_PAYMENT_FOR = "cod_settlement";

// =====================================================
// PAYMENT CODE GENERATOR
// =====================================================

function generatePaymentCode(type: string) {
  const now = new Date();
  const date = now.toISOString().split("T")[0].replace(/-/g, "");
  const random = Math.floor(1000 + Math.random() * 9000);
  return `WDX-${type.toUpperCase()}-${date}-${random}`;
}

// =====================================================
// SERVER
// =====================================================

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    // =================================================
    // AUTH
    // =================================================

    const token = req.headers.get("Authorization")?.replace("Bearer ", "");

    if (!token) {
      return new Response(
        JSON.stringify({ error: "Missing auth token" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    const { data: authData, error: authError } = await supabaseAdmin.auth.getUser(token);

    if (authError || !authData.user) {
      return new Response(
        JSON.stringify({ error: "Unauthorized" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    const user = authData.user;

    // =================================================
    // BODY
    // =================================================

    const body = await req.json();

    const {
      payment_for,
      amount,
      reference_id,
      rider_id,
      payment_method,
      metadata,
      plan_id,
    } = body;

    // =================================================
    // VALIDATION
    // =================================================

    const isOrderFare = ORDER_FARE_TYPES.has(payment_for);
    const isTaxDue = payment_for === TAX_DUE_PAYMENT_FOR;
    const isCodSettlement = payment_for === COD_SETTLEMENT_PAYMENT_FOR;

    if (payment_for !== "subscription" && !isOrderFare && !isTaxDue && !isCodSettlement) {
      return new Response(
        JSON.stringify({ error: `Unsupported payment_for value: ${payment_for}` }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    if (!rider_id && !isOrderFare) {
      return new Response(
        JSON.stringify({ error: "rider_id is required for this payment type" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    // =================================================
    // PHASE 1 PRODUCTION CONTROL: server-side feature-flag enforcement
    // =================================================
    // create-payment is the single, central entry point for every payment type this app creates
    // (order fares, subscriptions, tax due, COD settlement), so it is the safest central place to
    // enforce these two flags rather than duplicating the check elsewhere. A config-fetch failure
    // fails open (isFeatureEnabled defaults to true) so a production_config outage can never itself
    // block payments.
    //
    // payments_enabled is the master kill switch for ALL payment creation. subscriptions_enabled is
    // additionally required only for payment_for === 'subscription' -- an order-fare/tax-due/COD
    // payment is unaffected by it.
    const productionConfig = await getProductionConfig(supabaseAdmin);
    if (!isFeatureEnabled(productionConfig, "payments_enabled")) {
      return new Response(
        JSON.stringify({ error: "Payments are temporarily unavailable. Please try again later." }),
        { status: 503, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }
    if (payment_for === "subscription" && !isFeatureEnabled(productionConfig, "subscriptions_enabled")) {
      return new Response(
        JSON.stringify({ error: "Subscriptions are temporarily unavailable. Please try again later." }),
        { status: 503, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    // =================================================
    // AMOUNT — for an order fare, NEVER trust the client-supplied `amount`.
    // Look the order up server-side and derive the total from
    // final_fare ?? current_fare, exactly the same "payableFare" semantics
    // the client uses for display -- mirrors the existing "never trust the
    // frontend for money" pattern already used in create-order/index.ts.
    // =================================================

    let order: Record<string, unknown> | null = null;
    let finalAmount: number;
    let baseAmount: number;
    let gstAmount: number;
    let companyEarning: number;
    let orderRiderId: string | null = null;
    let subscriptionPlanId: string | null = null;

    if (isOrderFare) {
      if (!reference_id) {
        return new Response(
          JSON.stringify({ error: "reference_id (order id) is required for fare payments" }),
          { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } },
        );
      }

      const { data: orderRow, error: orderError } = await supabaseAdmin
        .from("orders")
        .select("*")
        .eq("id", reference_id)
        .eq("user_id", user.id)
        .single();

      if (orderError || !orderRow) {
        return new Response(
          JSON.stringify({ error: "Order not found" }),
          { status: 404, headers: { ...corsHeaders, "Content-Type": "application/json" } },
        );
      }

      if (orderRow.payment_mode !== "online") {
        return new Response(
          JSON.stringify({ error: "This order is not set up for online payment" }),
          { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } },
        );
      }

      if (orderRow.payment_status === "paid") {
        return new Response(
          JSON.stringify({ error: "This order has already been paid" }),
          { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } },
        );
      }

      order = orderRow;
      finalAmount = Number(orderRow.final_fare ?? orderRow.current_fare ?? 0);
      gstAmount = Number(orderRow.gst_amount || 0);
      baseAmount = Number((finalAmount - gstAmount).toFixed(2));
      companyEarning = Number(orderRow.commission_amount || 0);
      orderRiderId = orderRow.rider_id ?? null;

      if (!finalAmount || finalAmount <= 0) {
        return new Response(
          JSON.stringify({ error: "Order has no payable fare" }),
          { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } },
        );
      }
    } else if (isTaxDue) {
      // GOVERNMENT TAX DUE REPAYMENT — the client may only ask to "pay my tax due"; it never
      // supplies (or influences) the amount. The server reads the rider's own real-time
      // government_tax_due_balance and charges exactly that -- full outstanding balance only for
      // this first implementation (no partial-payment support yet). rider_id is verified to
      // belong to the authenticated caller so nobody can pay down -- or even look up -- a
      // different rider's balance through this endpoint.
      if (!rider_id) {
        return new Response(
          JSON.stringify({ error: "rider_id is required for tax due payments" }),
          { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } },
        );
      }

      const { data: taxRider, error: taxRiderError } = await supabaseAdmin
        .from("riders")
        .select("id, user_id, government_tax_due_balance")
        .eq("id", rider_id)
        .single();

      if (taxRiderError || !taxRider) {
        return new Response(
          JSON.stringify({ error: "Rider not found" }),
          { status: 404, headers: { ...corsHeaders, "Content-Type": "application/json" } },
        );
      }

      if (taxRider.user_id !== user.id) {
        return new Response(
          JSON.stringify({ error: "Forbidden: rider_id does not belong to authenticated user" }),
          { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } },
        );
      }

      const dueBalance = Number(taxRider.government_tax_due_balance || 0);
      if (!dueBalance || dueBalance <= 0) {
        return new Response(
          JSON.stringify({ error: "No outstanding Government Tax Due to pay" }),
          { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } },
        );
      }

      // Not a fare -- no GST decomposition applies. Not company revenue either (see
      // apply_government_tax_payment(); this payments row's own company_earning stays 0 so it is
      // never counted as such in payments-table-derived reporting).
      finalAmount = dueBalance;
      baseAmount = dueBalance;
      gstAmount = 0;
      companyEarning = 0;
    } else if (isCodSettlement) {
      // COD SETTLEMENT ("Cash to be Paid") -- same shape as tax_due: the client may only ask to
      // "pay my cash dues"; it never supplies (or influences) the amount. The server reads the
      // rider's own real-time cod_pending_amount and charges exactly that -- full outstanding
      // balance only for this first implementation (no partial-payment support yet). rider_id is
      // verified to belong to the authenticated caller so nobody can pay down -- or even look up --
      // a different rider's balance through this endpoint.
      if (!rider_id) {
        return new Response(
          JSON.stringify({ error: "rider_id is required for COD settlement payments" }),
          { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } },
        );
      }

      const { data: codRider, error: codRiderError } = await supabaseAdmin
        .from("riders")
        .select("id, user_id, cod_pending_amount")
        .eq("id", rider_id)
        .single();

      if (codRiderError || !codRider) {
        return new Response(
          JSON.stringify({ error: "Rider not found" }),
          { status: 404, headers: { ...corsHeaders, "Content-Type": "application/json" } },
        );
      }

      if (codRider.user_id !== user.id) {
        return new Response(
          JSON.stringify({ error: "Forbidden: rider_id does not belong to authenticated user" }),
          { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } },
        );
      }

      const codDue = Number(codRider.cod_pending_amount || 0);
      if (!codDue || codDue <= 0) {
        return new Response(
          JSON.stringify({ error: "No outstanding cash dues to pay" }),
          { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } },
        );
      }

      // Not a fare -- no GST decomposition applies. Not newly-recognized company revenue here
      // either -- the commission this represents was already recognized as company_earning at
      // order-completion time (credit_rider_for_completed_order); this payment just collects it.
      finalAmount = codDue;
      baseAmount = codDue;
      gstAmount = 0;
      companyEarning = 0;
    } else {
      // SUBSCRIPTION — amount/duration are NEVER derived from the client. `plan_id` is
      // the only subscription-related value the client may specify; the real charge
      // amount comes exclusively from the subscription_plans allowlist (see migration
      // 20260726000002_subscription_plan_allowlist.sql). The client's own `amount` body
      // field (if present, e.g. for local display) is ignored entirely here. Duration is
      // derived later, at activation time, from THIS plan_id via the same table
      // (cashfree-webhook/verify-payment) — never from client-supplied metadata.days.
      if (!plan_id || typeof plan_id !== "string") {
        return new Response(
          JSON.stringify({ error: "plan_id is required for subscription payments" }),
          { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } },
        );
      }

      // SECURITY FIX (required for vehicle-specific pricing below): unlike tax_due/cod_settlement
      // above, this branch never verified that the client-supplied rider_id actually belongs to
      // the authenticated caller. Without this, the vehicle-verification check below would be
      // meaningless (a caller could supply any rider_id whose KYC vehicle happens to be cheaper),
      // and — independent of this feature — a subscription's entitlement could be pointed at an
      // arbitrary rider_id.
      const { data: subRider, error: subRiderError } = await supabaseAdmin
        .from("riders")
        .select("id, user_id, subscription_active, subscription_expires_at, free_trial_expires_at")
        .eq("id", rider_id)
        .single();

      if (subRiderError || !subRider) {
        return new Response(
          JSON.stringify({ error: "Rider not found" }),
          { status: 404, headers: { ...corsHeaders, "Content-Type": "application/json" } },
        );
      }

      if (subRider.user_id !== user.id) {
        return new Response(
          JSON.stringify({ error: "Forbidden: rider_id does not belong to authenticated user" }),
          { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } },
        );
      }

      // NO-STACKING / DOUBLE-SUBSCRIPTION GUARD (Phase 14): a rider with a currently-active PAID
      // subscription may not buy another one until it expires -- "Subscribe becomes available
      // again only after expiry" is a backend rule, not just a Flutter UI gate. Buying WHILE ON
      // THE FREE TRIAL is still allowed (the approved product rule) -- it just never stacks onto
      // the trial's expiry (see computeSubscriptionExpiry() in cashfree-webhook/verify-payment).
      // The currently-active entitlement is the free trial iff subscription_expires_at exactly
      // equals the permanent, never-reset free_trial_expires_at bookkeeping column (set once by
      // the one-time free-trial grant flow and never touched by a paid purchase now that
      // purchases never stack onto it) -- anything else while subscription_active is a paid
      // entitlement. This branch only ever READS free_trial_expires_at -- it never writes to it
      // or any other free_trial_* column.
      const isCurrentlyActive = subRider.subscription_active === true &&
        subRider.subscription_expires_at != null &&
        new Date(subRider.subscription_expires_at) > new Date();
      const isCurrentlyOnFreeTrial = isCurrentlyActive &&
        subRider.free_trial_expires_at != null &&
        subRider.subscription_expires_at === subRider.free_trial_expires_at;
      if (isCurrentlyActive && !isCurrentlyOnFreeTrial) {
        return new Response(
          JSON.stringify({
            error: `You already have an active subscription until ${subRider.subscription_expires_at}. ` +
              "A new purchase is only allowed after it expires.",
          }),
          { status: 409, headers: { ...corsHeaders, "Content-Type": "application/json" } },
        );
      }

      const { data: plan, error: planError } = await supabaseAdmin
        .from("subscription_plans")
        .select("plan_id, amount, duration_hours, is_active, vehicle_type")
        .eq("plan_id", plan_id)
        .eq("is_active", true)
        .maybeSingle();

      if (planError || !plan) {
        console.error("[CreatePayment] Unknown/inactive subscription plan_id:", plan_id, planError);
        return new Response(
          JSON.stringify({ error: "Unknown or inactive subscription plan" }),
          { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } },
        );
      }

      // VEHICLE-SPECIFIC PRICING: a plan tied to a specific vehicle_type may only be purchased by
      // a rider who genuinely has that vehicle verified — the rider's primary KYC vehicle
      // (rider_kyc, only if kyc_status='approved') or an additional approved row in
      // rider_vehicles. No fallback to any other plan/price on mismatch or missing verification —
      // fail closed with 403, never silently substitute a different vehicle's price.
      if (plan.vehicle_type) {
        const { data: kycRow } = await supabaseAdmin
          .from("rider_kyc")
          .select("vehicle_type, kyc_status")
          .eq("user_id", subRider.user_id)
          .maybeSingle();

        const { data: extraVehicles } = await supabaseAdmin
          .from("rider_vehicles")
          .select("vehicle_type")
          .eq("rider_id", rider_id)
          .eq("status", "approved");

        const verifiedVehicleTypes = new Set<string>();
        if (kycRow && kycRow.kyc_status === "approved" && kycRow.vehicle_type) {
          verifiedVehicleTypes.add(kycRow.vehicle_type);
        }
        for (const v of extraVehicles || []) {
          if (v.vehicle_type) verifiedVehicleTypes.add(v.vehicle_type);
        }

        if (!verifiedVehicleTypes.has(plan.vehicle_type)) {
          return new Response(
            JSON.stringify({ error: "Selected vehicle is not verified for this account" }),
            { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } },
          );
        }
      }

      subscriptionPlanId = plan.plan_id;
      finalAmount = Number(plan.amount);
      baseAmount = Number((finalAmount / 1.18).toFixed(2));
      gstAmount = Number((finalAmount - baseAmount).toFixed(2));
      companyEarning = baseAmount;
    }

    // =================================================
    // CHECK DUPLICATE PAYMENT
    // BUG FIX (mirrors create-fare-qr's identical, already-shipped fix): a pending row's Cashfree
    // order/session is only valid for a limited window. This used to hand back that same
    // session_id forever regardless of whether Cashfree still considered it ACTIVE -- exactly the
    // "Payment Cancelled -> Retry Payment -> stuck on a dead session forever" loop create-fare-qr
    // was fixed for, except this path (subscription / passenger "Pay Online Securely" / tax due)
    // never received the same fix. This was the actual cause of "Pay ₹40 Subscription" retries
    // never completing: any hiccup on the first attempt permanently poisoned every retry with an
    // already-expired session. Now the existing order's live status is checked against Cashfree
    // itself before reuse -- never trusting the local 'pending' row alone.
    // =================================================

    // reference_id is null for subscription and tax_due (there is no order to reference) --
    // .eq("reference_id", null) serializes to the literal filter "eq.null", which does not match
    // Postgres NULL (that requires "is.null"), so this lookup must branch on nullness explicitly.
    // Without this, subscription/tax_due retries never find their own still-pending row here and
    // silently skip the live-session-reuse check just added above, for exactly the two payment
    // types this audit covers.
    let duplicateQuery = supabaseAdmin
      .from("payments")
      .select("*")
      .eq("user_id", user.id)
      .eq("payment_for", payment_for)
      .eq("payment_status", "pending");

    duplicateQuery = reference_id
      ? duplicateQuery.eq("reference_id", reference_id)
      : duplicateQuery.is("reference_id", null);

    let { data: existingPayment } = await duplicateQuery.maybeSingle();

    // STALE-PENDING-PAYMENT PROTECTION: the lookup above matches on user_id/payment_for/status
    // alone, so a still-ACTIVE pending payment from an EARLIER attempt -- for a different
    // plan_id, or at an amount that has since changed -- would otherwise be reused verbatim,
    // handing the caller a Cashfree session for a value they did not just request (e.g. UI shows
    // the current daily_bike price of ₹39, but an old still-ACTIVE ₹40 pending session gets
    // reused; or UI shows a current government_tax_due_balance/cod_pending_amount of ₹22.75, but
    // an old still-ACTIVE ₹65.75 pending session gets reused). A pending payment of these types is
    // only ever safe to reuse if it was created for the SAME authoritative amount being requested
    // right now (plus, for subscription only, the SAME plan_id). `finalAmount` is already that
    // authoritative value for all three: plan.amount for subscription, the freshly-read
    // government_tax_due_balance for tax_due, the freshly-read cod_pending_amount for
    // cod_settlement (see the branches above). Scoped to exactly these three types --
    // order-fare already scopes correctly via reference_id (the order's own id).
    const requiresAmountMatch = payment_for === "subscription" || isTaxDue || isCodSettlement;
    if (existingPayment && requiresAmountMatch) {
      const planMismatch = payment_for === "subscription" && existingPayment.plan_id !== subscriptionPlanId;
      const amountMismatch = Number(existingPayment.final_amount).toFixed(2) !== finalAmount.toFixed(2);
      if (planMismatch || amountMismatch) {
        const failureReason = payment_for === "subscription"
          ? "subscription_plan_or_amount_changed"
          : isTaxDue
          ? "tax_due_amount_changed"
          : "cod_settlement_amount_changed";
        console.log(
          "[CreatePayment] Existing pending payment is stale (plan/amount changed) -- " +
          "superseding it instead of reusing.",
          {
            paymentFor: payment_for,
            existingPlanId: existingPayment.plan_id,
            existingAmount: existingPayment.final_amount,
            requestedPlanId: subscriptionPlanId,
            requestedAmount: finalAmount,
          },
        );
        await supabaseAdmin
          .from("payments")
          .update({ payment_status: "failed", failure_reason: failureReason })
          .eq("id", existingPayment.id)
          .eq("payment_status", "pending");
        existingPayment = null;
      }
    }

    if (existingPayment && existingPayment.gateway_order_id) {
      try {
        const statusResponse = await fetchWithTimeout(
          `${CASHFREE_BASE_URL}/orders/${existingPayment.gateway_order_id}`,
          {
            method: "GET",
            headers: {
              "x-client-id": CASHFREE_APP_ID,
              "x-client-secret": CASHFREE_SECRET_KEY,
              "x-api-version": CASHFREE_API_VERSION,
            },
          },
          10000,
        );
        const statusData = await statusResponse.json();

        if (statusResponse.ok && statusData?.order_status === "ACTIVE") {
          // Still a live, payable session -- safe to hand back as-is.
          return new Response(
            JSON.stringify({
              success: true,
              duplicate: true,
              payment_id: existingPayment.id,
              payment_code: existingPayment.payment_code,
              order_id: existingPayment.gateway_order_id,
              payment_session_id: statusData.payment_session_id
                || existingPayment.metadata?.cashfree?.payment_session_id
                || null,
              cashfree_env: "production",
            }),
            { headers: { ...corsHeaders, "Content-Type": "application/json" } },
          );
        }

        if (statusResponse.ok && statusData?.order_status === "PAID") {
          // Real money already moved on this exact order -- our own webhook/poll just hasn't
          // caught up yet. NEVER mint a second Cashfree order for it (that would risk a genuine
          // duplicate charge). Hand back the same (now-unpayable) session_id rather than null --
          // Flutter's startPayment() requires a non-null session_id to proceed at all, and
          // PaymentProcessingScreen's own realtime/poll verification (which independently re-checks
          // Cashfree via verify-payment) will observe the true "paid" status and resolve to success
          // within its existing 5s/10s cycle even if the stale session itself can't be reopened.
          return new Response(
            JSON.stringify({
              success: true,
              duplicate: true,
              payment_id: existingPayment.id,
              payment_code: existingPayment.payment_code,
              order_id: existingPayment.gateway_order_id,
              payment_session_id: existingPayment.metadata?.cashfree?.payment_session_id || null,
              cashfree_env: "production",
            }),
            { headers: { ...corsHeaders, "Content-Type": "application/json" } },
          );
        }

        // EXPIRED / TERMINATED / TERMINATION_REQUESTED / anything else non-ACTIVE/non-PAID: this
        // session can no longer be completed. Close the old row and fall through to mint a
        // genuinely fresh Cashfree order below instead of handing back a dead session.
        console.log(
          "[CreatePayment] Existing Cashfree order is no longer usable (status:",
          statusData?.order_status,
          ") for payment", existingPayment.id, "-- creating a fresh one.",
        );
        await supabaseAdmin
          .from("payments")
          .update({ payment_status: "failed", failure_reason: "cashfree_session_expired" })
          .eq("id", existingPayment.id)
          .eq("payment_status", "pending");
      } catch (statusCheckError) {
        // Cashfree status-check itself unreachable -- best effort, fall back to the existing
        // session rather than blocking the caller entirely on a transient network blip.
        console.error("[CreatePayment] Cashfree order-status check failed:", statusCheckError);
        return new Response(
          JSON.stringify({
            success: true,
            duplicate: true,
            payment_id: existingPayment.id,
            payment_code: existingPayment.payment_code,
            order_id: existingPayment.gateway_order_id,
            payment_session_id: existingPayment.metadata?.cashfree?.payment_session_id || null,
            cashfree_env: "production",
          }),
          { headers: { ...corsHeaders, "Content-Type": "application/json" } },
        );
      }
    }

    // =================================================
    // GENERATE PAYMENT CODE
    // =================================================

    const paymentCode = generatePaymentCode(payment_for);

    // =================================================
    // INSERT PAYMENT (BEFORE calling Cashfree)
    // BUG #5 FIX: previously this row was only inserted after a successful Cashfree response,
    // so any Cashfree-side error (including a slow/ambiguous one where Cashfree had, in fact,
    // already created the order) left zero local record of the attempt -- silently orphaning
    // the Cashfree order and defeating the CHECK DUPLICATE PAYMENT query above on every retry
    // (nothing existed for it to find). Recording the attempt as "pending" up front, before the
    // Cashfree call, means a failure below now updates this same row instead of never existing
    // at all -- retries can see it. ("pending" -- not "processing" -- because payment_status_enum
    // (supabase/migrations/20260529000000_baseline_foundational_schema.sql:181-189) has no
    // "processing" member; its only members are pending/paid/failed/refunded/partial_refund/
    // cash_collected/cash_pending_settlement. "pending" is exactly the value the pre-fix code
    // already used once Cashfree succeeded, so this reuses an existing, already-relied-upon state
    // rather than inventing a new one.)
    // =================================================

    const { data: payment, error: paymentInsertError } = await supabaseAdmin
      .from("payments")
      .insert({
        payment_code: paymentCode,
        user_id: user.id,
        rider_id: isOrderFare ? orderRiderId : rider_id,
        payment_for,
        reference_id,
        plan_id: subscriptionPlanId,
        amount: baseAmount,
        gst_amount: gstAmount,
        final_amount: finalAmount,
        platform_fee: 0,
        rider_earning: isOrderFare ? Number((order as Record<string, unknown>)?.rider_earning || 0) : 0,
        company_earning: companyEarning,
        payment_method,
        payment_gateway: "cashfree",
        gateway_order_id: null,
        payment_status: "pending",
        metadata: metadata ?? {},
      })
      .select()
      .single();

    if (paymentInsertError || !payment) {
      console.error("[CreatePayment] Payment DB insert failed:", paymentInsertError);
      return new Response(
        JSON.stringify({ error: "Payment DB insert failed" }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    // =================================================
    // CASHFREE ORDER PAYLOAD
    // =================================================

    const orderPayload = {
      order_id: paymentCode,
      order_amount: finalAmount,
      order_currency: "INR",
      customer_details: {
        customer_id: user.id,
        customer_name: user.user_metadata?.full_name ?? "WayDropX User",
        customer_email: user.email ?? "support@waydropx.com",
        customer_phone: user.phone ?? "9999999999",
      },
    };

    // =================================================
    // CREATE CASHFREE ORDER
    // =================================================

    const cashfreeResponse = await fetchWithTimeout(`${CASHFREE_BASE_URL}/orders`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-client-id": CASHFREE_APP_ID,
        "x-client-secret": CASHFREE_SECRET_KEY,
        "x-api-version": CASHFREE_API_VERSION,
      },
      body: JSON.stringify(orderPayload),
    }, 15000);

    const cashfreeData = await cashfreeResponse.json();

    if (!cashfreeResponse.ok) {
      console.error("[CreatePayment] Cashfree order failed:", cashfreeData);

      // Update the same row instead of leaving it stuck as "pending" with no Cashfree order behind
      // it forever -- this keeps a queryable record of exactly what Cashfree returned.
      await supabaseAdmin
        .from("payments")
        .update({
          payment_status: "failed",
          failure_reason: "cashfree_order_creation_failed",
          metadata: {
            ...(payment.metadata ?? {}),
            cashfree_error: cashfreeData,
          },
          updated_at: new Date().toISOString(),
        })
        .eq("id", payment.id);

      return new Response(
        JSON.stringify({ error: "Cashfree order failed" }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    // =================================================
    // UPDATE PAYMENT WITH CASHFREE ORDER DETAILS
    // Same row from the insert above -- never a second insert for this attempt.
    // =================================================

    const { data: updatedPayment, error: paymentUpdateError } = await supabaseAdmin
      .from("payments")
      .update({
        gateway_order_id: cashfreeData.order_id,
        payment_status: "pending",
        metadata: {
          ...(payment.metadata ?? {}),
          cashfree: cashfreeData,
        },
        updated_at: new Date().toISOString(),
      })
      .eq("id", payment.id)
      .select()
      .single();

    if (paymentUpdateError || !updatedPayment) {
      console.error("[CreatePayment] Payment DB update failed:", paymentUpdateError);
      return new Response(
        JSON.stringify({ error: "Payment DB update failed" }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    // =================================================
    // SUCCESS
    // =================================================

    return new Response(
      JSON.stringify({
        success: true,
        payment_id: updatedPayment.id,
        payment_code: paymentCode,
        payment_session_id: cashfreeData.payment_session_id,
        order_id: cashfreeData.order_id,
        cashfree_env: "production",
      }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  } catch (e) {
    console.error("[CreatePayment] Internal server error:", e);
    return new Response(
      JSON.stringify({ error: "Internal server error" }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  }
});
