import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

// =====================================================
// SUPABASE
// =====================================================

const supabaseAdmin = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

// =====================================================
// CASHFREE
// =====================================================

const CASHFREE_SECRET_KEY = Deno.env.get("CASHFREE_SECRET_KEY")!;

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
// WEBHOOK SIGNATURE VERIFICATION
// Cashfree signs every webhook with:
//   base64(HMAC-SHA256(x-webhook-timestamp + rawBody, CASHFREE_SECRET_KEY))
// compared against the `x-webhook-signature` header. This MUST run against
// the raw, unparsed request body — parsing/re-serializing JSON can change
// whitespace and silently break the signature match.
// =====================================================

async function computeSignature(rawBody: string, timestamp: string, secret: string): Promise<string> {
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const mac = await crypto.subtle.sign("HMAC", key, encoder.encode(timestamp + rawBody));
  return btoa(String.fromCharCode(...new Uint8Array(mac)));
}

function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let result = 0;
  for (let i = 0; i < a.length; i++) {
    result |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return result === 0;
}

// =====================================================
// SUBSCRIPTION EXPIRY CALCULATION
// Kept byte-identical in intent to the logic in verify-payment/index.ts —
// both paths (webhook vs. client-triggered polling) can be the one that
// first observes a SUCCESS, so both must compute the same expiry.
//
// SECURITY FIX (see migration 20260726000002_subscription_plan_allowlist.sql): duration
// is now an exact hour count taken from the server-side subscription_plans allowlist
// (via payments.plan_id), never from client-supplied metadata.days — and expiry is a
// plain "+N hours from confirmed activation" instead of snapping to 23:59:59 IST.
// ₹40 = exactly 24 hours from the moment THIS webhook/verify-payment confirms the
// Cashfree payment server-side, not "until the end of the calendar day".
//
// Stacking is preserved: if the rider's existing subscription is still active, the new
// duration is added on top of its current expiry rather than restarting from now — this
// was the pre-existing intentional behavior, just re-expressed in exact hours instead of
// calendar days.
// =====================================================

function computeSubscriptionExpiry(
  rider: { subscription_active: boolean | null; subscription_expires_at: string | null } | null,
  durationHours: number,
  activationTime: Date,
): { startsStr: string; expiresStr: string } {
  // NO-STACKING (Phase 14): every successful paid subscription starts a fresh window from ITS
  // OWN activation time -- never extended onto a currently-active free trial or a still-active
  // prior paid subscription (previously the base was reassigned to the existing expiry while
  // still active, which is exactly the bug that turned a 24h purchase into "active until 3 weeks
  // from now" when stacked onto an active 30-day free trial). `rider` is intentionally unused now -- kept in the
  // signature only so the call site doesn't need to change. create-payment/index.ts already
  // rejects a purchase attempt outright while a PAID subscription is currently active, so
  // stacking is never the desired outcome by the time this runs.
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
// retry from extending a rider's expiry twice for one payment.
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
  try {
    // =================================================
    // RAW BODY + SIGNATURE VERIFICATION
    // Must happen before any JSON parsing.
    // =================================================

    const rawBody = await req.text();
    const timestamp = req.headers.get("x-webhook-timestamp");
    const signature = req.headers.get("x-webhook-signature");

    if (!timestamp || !signature) {
      console.error("[CashfreeWebhook] Missing signature headers");
      return new Response(JSON.stringify({ error: "Missing signature headers" }), { status: 400 });
    }

    const expectedSignature = await computeSignature(rawBody, timestamp, CASHFREE_SECRET_KEY);

    if (!timingSafeEqual(expectedSignature, signature)) {
      console.error("[CashfreeWebhook] Signature mismatch — rejecting webhook");
      return new Response(JSON.stringify({ error: "Invalid signature" }), { status: 400 });
    }

    const payload = JSON.parse(rawBody);

    // Phase 5 F6: log only non-sensitive diagnostic fields -- the full payload can carry customer
    // contact/payment-instrument details (Cashfree's order/customer_details block). `payload`
    // itself is untouched and still used unredacted for the real business logic below; only what
    // reaches the log line changes.
    console.log("CASHFREE WEBHOOK (verified) => ", {
      order_id: payload?.data?.order?.order_id,
      cf_payment_id: payload?.data?.payment?.cf_payment_id,
      payment_status: payload?.data?.payment?.payment_status,
      bank_reference: payload?.data?.payment?.bank_reference,
    });

    // =================================================
    // EXTRACT
    // =================================================

    const orderId = payload?.data?.order?.order_id;
    const transactionId = payload?.data?.payment?.cf_payment_id;
    const paymentStatus = payload?.data?.payment?.payment_status;
    const utr = payload?.data?.payment?.bank_reference;

    // =================================================
    // FIND PAYMENT
    // =================================================

    const { data: payment } = await supabaseAdmin
      .from("payments")
      .select("*")
      .eq("payment_code", orderId)
      .maybeSingle();

    if (!payment) {
      return new Response("PAYMENT NOT FOUND");
    }

    // Cashfree is scoped to driver subscriptions + passenger fare payments --
    // reject anything else as defense in depth even though create-payment no
    // longer creates Cashfree orders for any other payment_for.
    const isOrderFare = ORDER_FARE_TYPES.has(payment.payment_for);
    const isTaxDue = payment.payment_for === TAX_DUE_PAYMENT_FOR;
    const isCodSettlement = payment.payment_for === COD_SETTLEMENT_PAYMENT_FOR;
    if (payment.payment_for !== "subscription" && !isOrderFare && !isTaxDue && !isCodSettlement) {
      console.error(`[CashfreeWebhook] Unexpected payment_for "${payment.payment_for}" — ignoring`);
      return new Response("IGNORED");
    }

    // =================================================
    // IDEMPOTENCY
    // =================================================

    if (payment.payment_status === "paid") {
      // PHASE 7A FIX: subscription entitlement is a separate, non-atomic step from the payment
      // itself being marked paid -- it can fail independently (see applySubscriptionEntitlement
      // above). Every other payment type here is already safely idempotent past this point
      // (order-fare completion is scoped to order_status='payment_pending'; tax_due/
      // cod_settlement use their own atomically-guarded RPCs), so they keep the original
      // fast-path return unchanged.
      if (payment.payment_for === "subscription") {
        await applySubscriptionEntitlement(payment, "[CashfreeWebhook]");
        return new Response("OK");
      }
      return new Response("ALREADY PROCESSED");
    }

    // =================================================
    // SUCCESS
    // =================================================

    if (paymentStatus === "SUCCESS") {
      await supabaseAdmin
        .from("payments")
        .update({
          payment_status: "paid",
          gateway_transaction_id: transactionId,
          webhook_received: true,
          webhook_payload: payload,
          paid_at: new Date().toISOString(),
          updated_at: new Date().toISOString(),
          metadata: {
            ...(payment.metadata ?? {}),
            utr_number: utr,
          },
        })
        .eq("id", payment.id);

      if (isOrderFare) {
        // ===============================================
        // ORDER FARE FLOW
        // `reference_id` on the payment is the order id. Mark it paid --
        // real, gateway-confirmed payment. order_status is left untouched;
        // that stays owned by the driver's swipe via update-order-status,
        // which gates completion on this exact payment_status flip for
        // 'online' orders.
        //
        // RACE FIX (identical to verify-payment's own fix -- this webhook and that poll can race
        // on the exact same payment): fare_payment_method stays null on the order for the entire
        // window a Cashfree checkout is in flight, so update-order-status's payment_pending->
        // completed guard can let the driver close the order out directly (cash/personal_upi)
        // before this webhook lands. Scoping this update to order_status still being
        // 'payment_pending' stops a late Cashfree success from overwriting an order the driver
        // already closed out a different way -- the payments row itself (updated above,
        // unconditionally) is still correctly marked 'paid' regardless, so the money is never
        // silently lost from records, it just needs manual reconciliation instead of corrupting
        // the order's settlement history.
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
          console.error("[CashfreeWebhook] Order payment_status update error:", orderUpdateError);
        } else if (!orderFareUpdate) {
          console.error(
            `[CashfreeWebhook] Cashfree payment ${payment.id} confirmed SUCCESS for order ${payment.reference_id}, ` +
            `but the order was no longer 'payment_pending' (already completed via a different settlement method). ` +
            `Order record left untouched to avoid corrupting its settlement history -- this payment needs MANUAL REVIEW/refund.`,
          );
        }
      } else if (isTaxDue) {
        // ===============================================
        // GOVERNMENT TAX DUE REPAYMENT FLOW
        // apply_government_tax_payment() is idempotent (unique index on payment_id where
        // entry_type='TAX_PAYMENT') and decrements government_tax_due_balance with an atomic
        // column-delta UPDATE -- safe against this webhook firing twice, and against racing
        // verify-payment's poll for the exact same payment (see that function for the identical
        // call). Never blindly sets the balance to 0 -- a liability added concurrently by another
        // order completing is preserved.
        // ===============================================
        const { error: taxPaymentError } = await supabaseAdmin.rpc("apply_government_tax_payment", {
          p_rider_id: payment.rider_id,
          p_payment_id: payment.id,
          p_amount: payment.final_amount,
        });

        if (taxPaymentError) {
          console.error("[CashfreeWebhook] Government Tax Due payment application error:", taxPaymentError);
        }
      } else if (isCodSettlement) {
        // ===============================================
        // COD SETTLEMENT ("Cash to be Paid") REPAYMENT FLOW
        // apply_cod_settlement_payment() is idempotent (unique index on payment_id where
        // entry_type='COD_SETTLEMENT_PAYMENT') and decrements cod_pending_amount with an atomic
        // column-delta UPDATE -- safe against this webhook firing twice, and against racing
        // verify-payment's poll for the exact same payment (see that function for the identical
        // call). Never blindly sets the balance to 0 -- a liability added concurrently by another
        // order completing is preserved.
        // ===============================================
        const { error: codSettlementError } = await supabaseAdmin.rpc("apply_cod_settlement_payment", {
          p_rider_id: payment.rider_id,
          p_payment_id: payment.id,
          p_amount: payment.final_amount,
        });

        if (codSettlementError) {
          console.error("[CashfreeWebhook] COD Settlement payment application error:", codSettlementError);
        }
      } else {
        // ===============================================
        // SUBSCRIPTION FLOW
        // ===============================================
        await applySubscriptionEntitlement(payment, "[CashfreeWebhook]");
      }
    } else {
      // =================================================
      // FAILED
      // =================================================

      await supabaseAdmin
        .from("payments")
        .update({
          payment_status: "failed",
          webhook_received: true,
          webhook_payload: payload,
          failure_reason: payload?.data?.payment?.payment_message ?? "Payment failed",
        })
        .eq("id", payment.id);
    }

    return new Response("OK");
  } catch (e) {
    console.error("[CashfreeWebhook] Internal error:", e);
    return new Response(
      JSON.stringify({ error: e.toString() }),
      { status: 500 },
    );
  }
});
