import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "npm:@supabase/supabase-js@2";
import { fetchWithTimeout } from "../_shared/http.ts";

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
// CASHFREE (PRODUCTION ONLY)
// =====================================================

const CASHFREE_APP_ID = Deno.env.get("CASHFREE_APP_ID")!;
const CASHFREE_SECRET_KEY = Deno.env.get("CASHFREE_SECRET_KEY")!;
const CASHFREE_BASE_URL = "https://api.cashfree.com/pg";
const CASHFREE_API_VERSION = "2025-01-01";

// Passenger fare payment_for values -- see create-payment/index.ts for why
// fares now go through Cashfree instead of a direct-to-driver upi://pay link.
const ORDER_FARE_TYPES = new Set([
  "ride_order",
  "parcel_order",
  "intercity_ride_order",
  "intercity_parcel_order",
  "ride_sharing",
]);

// Government Tax Due repayment -- see create-payment/index.ts.
const TAX_DUE_PAYMENT_FOR = "tax_due";

// "Cash to be Paid" (COD Settlement) -- see create-payment/index.ts.
const COD_SETTLEMENT_PAYMENT_FOR = "cod_settlement";

// =====================================================
// SUBSCRIPTION EXPIRY CALCULATION
// Kept in sync with the same logic in cashfree-webhook/index.ts — both
// paths can be the one that first observes a SUCCESS, so both must
// compute the same expiry.
//
// SECURITY FIX (see migration 20260726000002_subscription_plan_allowlist.sql): duration
// is now an exact hour count taken from the server-side subscription_plans allowlist
// (via payments.plan_id), never from client-supplied metadata.days — and expiry is a
// plain "+N hours from confirmed activation" instead of snapping to 23:59:59 IST. ₹40 =
// exactly 24 hours from the moment THIS function confirms the Cashfree payment
// server-side, not "until the end of the calendar day".
//
// NO-STACKING (Phase 14): every successful paid subscription starts a fresh window from ITS
// OWN activation time -- never extended onto a currently-active free trial or a still-active
// prior paid subscription. Stacking used to be preserved here deliberately; it is now removed
// because it produced exactly the reported bug -- a 24h purchase made while a 30-day free trial
// was still running became "active until 3 weeks from now" instead of +24h. create-payment/
// index.ts already rejects a purchase attempt outright while a PAID subscription is currently
// active, so stacking is never the desired outcome by the time this runs.
// =====================================================

function computeSubscriptionExpiry(
  rider: { subscription_active: boolean | null; subscription_expires_at: string | null } | null,
  durationHours: number,
  activationTime: Date,
): { startsStr: string; expiresStr: string } {
  const base = activationTime;
  const expires = new Date(base.getTime() + durationHours * 60 * 60 * 1000);
  return { startsStr: base.toISOString(), expiresStr: expires.toISOString() };
}

// =====================================================
// SUBSCRIPTION ENTITLEMENT (idempotent, self-healing)
// PHASE 7A FIX: entitlement activation (the `riders` UPDATE + the `rider_subscription_history`
// insert) is a separate, non-atomic step from marking the payment itself paid -- it can fail
// independently (a `riders` UPDATE error, a transient DB issue) without throwing, and the
// previous code never checked for that, so a failed entitlement UPDATE could be silently
// swallowed while a history row was still inserted regardless, making the one manual-recovery
// table unreliable. The idempotency signal for "has this payment's entitlement actually been
// applied" is now the EXISTENCE of a `rider_subscription_history` row for this exact payment_id
// -- not payments.payment_status -- so a webhook redelivery or a verify-payment re-poll can
// always tell the two states apart and self-heal instead of assuming "payment paid" already
// means "entitlement applied".
//
// The target expiry is computed and persisted to history EXACTLY ONCE, on first touch, before
// the `riders` UPDATE; every later call for the same payment_id reuses that stored value
// verbatim instead of recomputing/stacking again -- this is what prevents a partial-failure
// retry from extending a rider's expiry twice for one payment. Kept byte-identical in intent to
// the same function in cashfree-webhook/index.ts -- both paths can be the one that first
// observes/repairs entitlement for a given payment.
// =====================================================

async function applySubscriptionEntitlement(
  payment: { id: string; rider_id: string; plan_id: string | null; final_amount: number },
  logPrefix: string,
): Promise<void> {
  const { data: existingHistory, error: existingHistoryError } = await supabaseAdmin
    .from("rider_subscription_history")
    .select("id, expires_at")
    .eq("payment_id", payment.id)
    .maybeSingle();

  if (existingHistoryError) {
    console.error(`${logPrefix} rider_subscription_history lookup error for payment ${payment.id}:`, existingHistoryError.code, existingHistoryError.message);
    return;
  }

  if (existingHistory) {
    // Already recorded for this exact payment -- self-heal riders to the SAME stored expiry
    // rather than recomputing, in case only the riders UPDATE failed on an earlier delivery.
    const { error: healError } = await supabaseAdmin
      .from("riders")
      .update({
        commission_waiver_active: true,
        subscription_active: true,
        subscription_expires_at: existingHistory.expires_at,
      })
      .eq("id", payment.rider_id);

    if (healError) {
      console.error(`${logPrefix} entitlement self-heal UPDATE failed for payment ${payment.id}, rider ${payment.rider_id}:`, healError.code, healError.message);
    }
    return;
  }

  const { data: rider, error: riderError } = await supabaseAdmin
    .from("riders")
    .select("id, subscription_active, subscription_expires_at")
    .eq("id", payment.rider_id)
    .maybeSingle();

  if (riderError) {
    console.error(`${logPrefix} rider profile fetch error for payment ${payment.id}:`, riderError.code, riderError.message);
  }

  // SECURITY FIX (unchanged from before this fix): duration comes ONLY from the server-side
  // subscription_plans allowlist, looked up via payments.plan_id -- never from client-supplied
  // metadata.days. If plan_id is missing/unknown, entitlement is NOT activated with a
  // fabricated/guessed duration -- logged loudly for manual investigation instead.
  const planId = payment.plan_id;
  let plan: { duration_hours: number } | null = null;
  if (planId) {
    const { data: planRow, error: planError } = await supabaseAdmin
      .from("subscription_plans")
      .select("duration_hours")
      .eq("plan_id", planId)
      .maybeSingle();
    if (planError) console.error(`${logPrefix} plan lookup error for payment ${payment.id}:`, planError.code, planError.message);
    plan = planRow ?? null;
  }

  if (!plan) {
    console.error(`${logPrefix} payment ${payment.id} is paid but has no valid plan_id ("${planId}") -- subscription NOT activated. Needs manual investigation.`);
    return;
  }

  const { startsStr, expiresStr } = computeSubscriptionExpiry(rider ?? null, plan.duration_hours, new Date());

  const { error: historyInsertError } = await supabaseAdmin.from("rider_subscription_history").insert({
    rider_id: payment.rider_id,
    amount: payment.final_amount,
    payment_status: "paid",
    payment_id: payment.id,
    starts_at: startsStr,
    expires_at: expiresStr,
    is_active: true,
  });

  if (historyInsertError) {
    if (historyInsertError.code === "23505") {
      // idx_unique_subscription_payment (public.rider_subscription_history(payment_id),
      // 20260529000000_baseline_foundational_schema.sql) already makes a duplicate payment_id
      // insert impossible at the DB level -- this is the losing side of a genuine
      // webhook/verify-payment race, not a failure. The winning side already applied (or is
      // applying) entitlement for this exact payment; nothing further to do here.
      console.log(`${logPrefix} payment ${payment.id} history insert was a duplicate (idx_unique_subscription_payment) -- another delivery already recorded it. Idempotent, no action needed.`);
    } else {
      console.error(`${logPrefix} rider_subscription_history insert failed for payment ${payment.id}, rider ${payment.rider_id}:`, historyInsertError.code, historyInsertError.message, "-- entitlement NOT applied this delivery, will retry on next delivery.");
    }
    return;
  }

  const { error: riderUpdateError } = await supabaseAdmin
    .from("riders")
    .update({
      commission_waiver_active: true,
      subscription_active: true,
      subscription_expires_at: expiresStr,
    })
    .eq("id", payment.rider_id);

  if (riderUpdateError) {
    console.error(`${logPrefix} riders UPDATE failed for payment ${payment.id}, rider ${payment.rider_id}:`, riderUpdateError.code, riderUpdateError.message, "-- history recorded, will self-heal on next delivery.");
  }
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

    // =================================================
    // BODY
    // =================================================

    const body = await req.json();
    const { payment_code } = body;

    if (!payment_code) {
      return new Response(
        JSON.stringify({ error: "payment_code required" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    // =================================================
    // FIND PAYMENT
    // =================================================

    const { data: payment, error: paymentError } = await supabaseAdmin
      .from("payments")
      .select("*")
      .eq("payment_code", payment_code)
      .maybeSingle();

    if (paymentError) {
      console.error('PAYMENT FETCH ERROR:', paymentError);
      return Response.json(
        { success: false, verified: false, payment_status: 'pending' },
        { status: 200 },
      );
    }

    if (!payment) {
      return Response.json(
        { success: true, verified: false, payment_status: 'pending' },
        { status: 200 },
      );
    }

    // =================================================
    // OWNERSHIP CHECK (P2 fix): payment_code is a semi-predictable
    // "WDX-<TYPE>-<yyyymmdd>-<4-digit>" code, not a secret -- without this check any
    // authenticated user who obtained (or guessed) another user's payment_code could read
    // their full payment row (amount, gateway transaction id, metadata) and re-trigger a
    // Cashfree poll for it. Order-fare/subscription/tax_due payments are owned either by
    // the paying passenger (payments.user_id) or the paying rider (payments.rider_id, via
    // that rider's own user_id) -- never by anyone else.
    // =================================================
    let isOwner = payment.user_id === authData.user.id;
    if (!isOwner && payment.rider_id) {
      const { data: ownRider } = await supabaseAdmin
        .from("riders")
        .select("id")
        .eq("id", payment.rider_id)
        .eq("user_id", authData.user.id)
        .maybeSingle();
      isOwner = ownRider != null;
    }

    if (!isOwner) {
      return new Response(
        JSON.stringify({ error: "Forbidden: not the owner of this payment" }),
        { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    const isOrderFare = ORDER_FARE_TYPES.has(payment.payment_for);
    const isTaxDue = payment.payment_for === TAX_DUE_PAYMENT_FOR;
    const isCodSettlement = payment.payment_for === COD_SETTLEMENT_PAYMENT_FOR;

    if (payment.payment_for !== "subscription" && !isOrderFare && !isTaxDue && !isCodSettlement) {
      return new Response(
        JSON.stringify({ error: "This payment type is not verifiable via Cashfree" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    // =================================================
    // ALREADY PAID
    // =================================================

    if (payment.payment_status === "paid") {
      // PHASE 7A FIX: don't just report success -- ensure entitlement actually reflects this
      // paid payment (self-heals a prior delivery that only partially completed it). No need
      // to re-verify with Cashfree again here; our own DB already confirms this payment is
      // paid. Every other payment type is already safely idempotent past this point (order-fare
      // completion is scoped to order_status='payment_pending'; tax_due/cod_settlement use
      // their own atomically-guarded RPCs), so only subscription needs this extra step.
      if (payment.payment_for === "subscription") {
        await applySubscriptionEntitlement(payment, "[VerifyPayment]");
      }
      return new Response(
        JSON.stringify({ success: true, payment_status: "paid", already_verified: true, payment }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    // =================================================
    // VERIFY FROM CASHFREE
    // =================================================

    const verifyResponse = await fetchWithTimeout(
      `${CASHFREE_BASE_URL}/orders/${payment.gateway_order_id}/payments`,
      {
        method: "GET",
        headers: {
          "Content-Type": "application/json",
          "x-client-id": CASHFREE_APP_ID,
          "x-client-secret": CASHFREE_SECRET_KEY,
          "x-api-version": CASHFREE_API_VERSION,
        },
      },
      10000,
    );

    const verifyData = await verifyResponse.json();

    if (!verifyResponse.ok) {
      return new Response(
        JSON.stringify({ error: "Cashfree verification failed", details: verifyData }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    // =================================================
    // FIND SUCCESS PAYMENT
    // =================================================

    const successfulPayment = verifyData.find((item: any) => item.payment_status === "SUCCESS");

    if (successfulPayment) {
      let actualMethod = "upi";
      if (successfulPayment.payment_method) {
        if (successfulPayment.payment_method.upi) {
          actualMethod = "upi";
        } else if (successfulPayment.payment_method.card) {
          actualMethod = "card";
        } else if (successfulPayment.payment_method.wallet || successfulPayment.payment_method.app) {
          actualMethod = "wallet";
        } else if (successfulPayment.payment_method.netbanking) {
          actualMethod = "card";
        }
      }

      await supabaseAdmin
        .from("payments")
        .update({
          payment_status: "paid",
          payment_method: actualMethod,
          gateway_transaction_id: successfulPayment.cf_payment_id,
          paid_at: new Date().toISOString(),
          webhook_received: true,
          webhook_payload: successfulPayment,
          updated_at: new Date().toISOString(),
          metadata: {
            ...(payment.metadata ?? {}),
            verified_manually: true,
            utr_number: successfulPayment?.bank_reference ?? null,
          },
        })
        .eq("id", payment.id);

      if (isOrderFare) {
        // ===============================================
        // ORDER FARE FLOW
        // `reference_id` on the payment is the order id. Mark it paid here --
        // this is a real, gateway-confirmed payment, not the passenger's own
        // self-report -- order_status itself is left untouched; that stays
        // owned by the driver's swipe via update-order-status, which gates
        // completion on this exact payment_status flip for 'online' orders.
        //
        // RACE FIX: this Cashfree confirmation and the driver's own "Confirm Payment Received"
        // (personal_upi/cash) completion in update-order-status can race -- fare_payment_method
        // stays null on the order for the entire window a Cashfree checkout is in flight (this is
        // the first write to it), so update-order-status's payment_pending->completed guard falls
        // into its direct-settlement branch and lets the driver close the order out as cash/UPI
        // with no awareness a Cashfree payment might resolve moments later. Without a guard here,
        // that later Cashfree success would silently overwrite fare_payment_method to 'cashfree'
        // on an order the driver already closed out directly -- corrupting the settlement record
        // on top of the underlying double-charge, which itself needs a real refund (out of scope
        // for a DB write -- see docs/07_Payments.md). Scoping this update to order_status still
        // being 'payment_pending' means a late Cashfree success can never touch an order that has
        // already moved on; the payments row itself (updated above, unconditionally) is still
        // correctly marked 'paid' either way, so the money is never silently lost from records --
        // it just needs manual reconciliation instead of corrupting the order.
        // ===============================================
        const { data: orderFareUpdate, error: orderUpdateError } = await supabaseAdmin
          .from("orders")
          .update({
            payment_status: "paid",
            fare_payment_method: "cashfree",
            fare_paid_at: new Date().toISOString(),
            updated_at: new Date().toISOString(),
          })
          .eq("id", payment.reference_id)
          .eq("order_status", "payment_pending")
          .select("id")
          .maybeSingle();

        if (orderUpdateError) {
          console.error("[VerifyPayment] Order payment_status update error:", orderUpdateError);
        } else if (!orderFareUpdate) {
          console.error(
            `[VerifyPayment] Cashfree payment ${payment.id} confirmed SUCCESS for order ${payment.reference_id}, ` +
            `but the order was no longer 'payment_pending' (already completed via a different settlement method). ` +
            `Order record left untouched to avoid corrupting its settlement history -- this payment needs MANUAL REVIEW/refund.`,
          );
        }
      } else if (isTaxDue) {
        // ===============================================
        // GOVERNMENT TAX DUE REPAYMENT FLOW
        // Identical call/idempotency guarantee as cashfree-webhook's own tax_due branch -- this
        // poll and that webhook can race on the exact same payment, and apply_government_tax_
        // payment() (unique index on payment_id where entry_type='TAX_PAYMENT') guarantees only
        // one of them actually applies the credit.
        // ===============================================
        const { error: taxPaymentError } = await supabaseAdmin.rpc("apply_government_tax_payment", {
          p_rider_id: payment.rider_id,
          p_payment_id: payment.id,
          p_amount: payment.final_amount,
        });

        if (taxPaymentError) {
          console.error("[VerifyPayment] Government Tax Due payment application error:", taxPaymentError);
        }
      } else if (isCodSettlement) {
        // ===============================================
        // COD SETTLEMENT ("Cash to be Paid") REPAYMENT FLOW
        // Identical call/idempotency guarantee as cashfree-webhook's own cod_settlement branch --
        // this poll and that webhook can race on the exact same payment, and
        // apply_cod_settlement_payment() (unique index on payment_id where
        // entry_type='COD_SETTLEMENT_PAYMENT') guarantees only one of them actually applies the
        // credit.
        // ===============================================
        const { error: codSettlementError } = await supabaseAdmin.rpc("apply_cod_settlement_payment", {
          p_rider_id: payment.rider_id,
          p_payment_id: payment.id,
          p_amount: payment.final_amount,
        });

        if (codSettlementError) {
          console.error("[VerifyPayment] COD Settlement payment application error:", codSettlementError);
        }
      } else {
        // ===============================================
        // SUBSCRIPTION FLOW
        // ===============================================
        await applySubscriptionEntitlement(payment, "[VerifyPayment]");
      }

      return new Response(
        JSON.stringify({ success: true, payment_status: "paid", verified: true }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    // =================================================
    // CHECK FAILED PAYMENTS
    // =================================================

    const failedPayment = verifyData.find(
      (item: any) =>
        item.payment_status === "FAILED" ||
        item.payment_status === "CANCELLED" ||
        item.payment_status === "USER_DROPPED",
    );

    if (failedPayment) {
      await supabaseAdmin
        .from("payments")
        .update({
          payment_status: "failed",
          failure_reason: failedPayment.payment_message || failedPayment.payment_status || "Payment failed",
          updated_at: new Date().toISOString(),
        })
        .eq("id", payment.id);

      return new Response(
        JSON.stringify({ success: true, payment_status: "failed", verified: false }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    // =================================================
    // PAYMENT STILL PENDING
    // =================================================

    return new Response(
      JSON.stringify({ success: true, payment_status: "pending", verified: false }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  } catch (e) {
    return new Response(
      JSON.stringify({ error: "Internal server error", details: e.toString() }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  }
});
