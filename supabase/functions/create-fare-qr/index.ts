import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "npm:@supabase/supabase-js@2";
import { fetchWithTimeout } from "../_shared/http.ts";
import { resolveCashfreeCustomerPhone } from "../_shared/customer_phone.ts";

// =====================================================
// Prepares the driver's "Cashfree QR" button on the payment_pending screen. Cashfree's only
// documented API that returns a raw, extractable UPI QR payload for a specific order is the "Order
// Pay"/Seamless S2S API (POST /pg/orders/sessions, payment_method.upi.channel = "qrcode") -- and
// that requires a separate, Cashfree-support-granted S2S approval this merchant account does not
// have: production calls have consistently failed with HTTP 400, code "s2s_enabled_not_approved",
// type "feature_not_enabled", message "POST/orders/pay is not enabled or approved. Please reach out
// to care@cashfree.com." Confirmed against Cashfree's current v2025-01-01 API reference and the
// flutter_cashfree_pg_sdk plugin source (its CFUPIPaymentBuilder only supports COLLECT/INTENT
// modes, no QR mode) that no other Cashfree endpoint exposes a raw QR payload -- so WayDrop cannot
// self-render a QR image without fabricating the payment payload itself, which it must never do.
//
// What Cashfree's standard, already-working hosted checkout DOES provide (POST /pg/orders --
// the exact same non-gated call create-payment already uses successfully for subscriptions and the
// passenger's "Pay Online Securely") is a built-in "Scan and Pay" UPI QR *inside its own checkout
// UI* -- a genuine, unique, per-order dynamic QR that Cashfree itself renders, not something
// WayDrop extracts or reconstructs. Setting order_meta.payment_methods: "upi" below restricts that
// checkout to UPI only (intent buttons + Scan-and-Pay), hiding cards/netbanking/wallet tabs. This
// function's job is just to create/reuse that order idempotently and hand back the
// payment_session_id the Flutter client needs to open it via CFWebCheckoutPaymentBuilder --
// identical in shape to what create-payment already returns. If order creation itself fails
// (network/API/account error), this returns qr_available:false with a single generic driver-facing
// reason (QR_UNAVAILABLE_MESSAGE) and falls back to Personal QR/Cash -- it never forwards Cashfree's
// raw error detail to the client; the full diagnostic is logged server-side and persisted to
// payments.metadata.cashfree_qr_last_error for engineering/support use only.
// =====================================================

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const supabaseAdmin = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

const CASHFREE_APP_ID = Deno.env.get("CASHFREE_APP_ID")!;
const CASHFREE_SECRET_KEY = Deno.env.get("CASHFREE_SECRET_KEY")!;
const CASHFREE_BASE_URL = "https://api.cashfree.com/pg";
const CASHFREE_API_VERSION = "2025-01-01";

// Single driver-facing message for every qr_available:false case, regardless of the underlying
// cause (account capability gap, transient network failure, unrecognized response shape, ...).
// The real cause (HTTP status, Cashfree error code/type/message) is logged via console.error and
// persisted to payments.metadata.cashfree_qr_last_error for engineering/support use -- it must
// never reach the driver's screen as raw API text, an HTTP status, or a JSON dump.
const QR_UNAVAILABLE_MESSAGE = "Cashfree QR is temporarily unavailable.";

const ORDER_FARE_TYPES = new Set([
  "ride_order",
  "parcel_order",
  "intercity_ride_order",
  "intercity_parcel_order",
  "ride_sharing",
]);

function paymentForFromOrderType(orderType: string): string | null {
  switch (orderType) {
    case "ride":
      return "ride_order";
    case "local_parcel":
      return "parcel_order";
    case "intercity_ride":
      return "intercity_ride_order";
    case "intercity_parcel":
      return "intercity_parcel_order";
    case "ride_sharing":
      return "ride_sharing";
    default:
      return null;
  }
}

function generatePaymentCode(type: string) {
  const now = new Date();
  const date = now.toISOString().split("T")[0].replace(/-/g, "");
  const random = Math.floor(1000 + Math.random() * 9000);
  return `WDXQR-${type.toUpperCase()}-${date}-${random}`;
}

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
      return Response.json({ success: false, message: "Missing auth token" }, { status: 401, headers: corsHeaders });
    }

    const { data: authData, error: authError } = await supabaseAdmin.auth.getUser(token);
    if (authError || !authData.user) {
      return Response.json({ success: false, message: "Unauthorized" }, { status: 401, headers: corsHeaders });
    }
    const user = authData.user;

    // =================================================
    // BODY
    // =================================================
    const body = await req.json();
    const orderId = body?.order_id;
    if (!orderId) {
      return Response.json({ success: false, message: "order_id is required" }, { status: 400, headers: corsHeaders });
    }

    // =================================================
    // FETCH ORDER + AUTHORIZE (passenger or assigned driver only)
    // =================================================
    const { data: order, error: orderError } = await supabaseAdmin
      .from("orders")
      .select("*")
      .eq("id", orderId)
      .single();

    if (orderError || !order) {
      return Response.json({ success: false, message: "Order not found" }, { status: 404, headers: corsHeaders });
    }

    let isAuthorized = order.user_id === user.id;
    if (!isAuthorized && order.rider_id) {
      const { data: assignedRider } = await supabaseAdmin
        .from("riders")
        .select("user_id")
        .eq("id", order.rider_id)
        .single();
      isAuthorized = assignedRider?.user_id === user.id;
    }
    if (!isAuthorized) {
      return Response.json({ success: false, message: "Forbidden: not a participant on this order" }, { status: 403, headers: corsHeaders });
    }

    if (order.order_status !== "payment_pending") {
      return Response.json(
        { success: false, message: "This order is not awaiting fare payment right now." },
        { status: 400, headers: corsHeaders },
      );
    }

    const paymentFor = paymentForFromOrderType(order.order_type);
    if (!paymentFor || !ORDER_FARE_TYPES.has(paymentFor)) {
      return Response.json({ success: false, message: "Unsupported order type for Cashfree QR" }, { status: 400, headers: corsHeaders });
    }

    // =================================================
    // CANONICAL FARE -- never client-supplied. Same payableFare semantics as everywhere else
    // (final_fare when a promo discount applied, else current_fare).
    // =================================================
    const finalAmount = Number(order.final_fare ?? order.current_fare ?? 0);
    if (!finalAmount || finalAmount <= 0) {
      return Response.json({ success: false, message: "Order has no payable fare" }, { status: 400, headers: corsHeaders });
    }

    // =================================================
    // REUSE AN EXISTING PENDING PAYMENT (same idempotency key as create-payment: one payment row
    // per passenger+payment_for+order). Reuses the same Cashfree order/payment_session_id rather
    // than minting a second one for the same fare -- both the driver and passenger may open
    // "Cashfree QR"/"Pay Online Securely" more than once for the same order.
    //
    // BUG FIX (real-device "Payment Cancelled -> Retry Payment -> temporarily unavailable"): a
    // reused row's Cashfree order session is only ever valid for a limited window. Previously this
    // handed back that same session_id forever -- a driver who cancelled once and immediately
    // tapped "Cashfree QR" again (before the 5s/10s verify-payment poll had a chance to observe the
    // cancellation and flip payment_status to 'failed') was handed the exact same, now-expired
    // session on every subsequent attempt. Now the existing order's live status is checked against
    // Cashfree itself before reuse -- never trusting the local 'pending' row alone.
    // =================================================
    const { data: existingPayment } = await supabaseAdmin
      .from("payments")
      .select("*")
      .eq("user_id", order.user_id)
      .eq("payment_for", paymentFor)
      .eq("reference_id", orderId)
      // payment_status_enum has no "processing" member (pending/paid/failed/refunded/
      // partial_refund/cash_collected/cash_pending_settlement only, see
      // 20260529000000_baseline_foundational_schema.sql:181-189) -- filtering with .in() against
      // an unknown enum literal makes Postgres reject the whole query (invalid input value for
      // enum), which made this SELECT throw on every single call, breaking the driver's
      // "Cashfree QR" button outright regardless of whether a pending payment existed.
      .eq("payment_status", "pending")
      .maybeSingle();

    let paymentRow = existingPayment;
    let cashfreeOrderId: string | null = existingPayment?.gateway_order_id ?? null;
    let paymentSessionId: string | null = existingPayment?.metadata?.cashfree?.payment_session_id ?? null;

    if (paymentRow && cashfreeOrderId) {
      try {
        const statusResponse = await fetchWithTimeout(`${CASHFREE_BASE_URL}/orders/${cashfreeOrderId}`, {
          method: "GET",
          headers: {
            "x-client-id": CASHFREE_APP_ID,
            "x-client-secret": CASHFREE_SECRET_KEY,
            "x-api-version": CASHFREE_API_VERSION,
          },
        }, 10000);
        const statusData = await statusResponse.json();

        if (statusResponse.ok && statusData?.order_status === "ACTIVE") {
          // Still a live, scannable session -- safe to hand back as-is.
          paymentSessionId = statusData.payment_session_id ?? paymentSessionId;
        } else if (statusResponse.ok && statusData?.order_status === "PAID") {
          // Passenger already paid this exact order; our own webhook/poll just hasn't caught up
          // yet. Never mint a second Cashfree order for an already-paid fare -- surface as
          // unavailable-for-a-new-QR so the caller falls back to the existing
          // webhook/poll-driven "waiting for confirmation" state instead of double-charging.
          console.log("[CreateFareQr] Existing Cashfree order already PAID for order", orderId, "-- not creating a new one.");
          return Response.json(
            { success: true, qr_available: false, reason: "Payment already received for this order." },
            { status: 200, headers: corsHeaders },
          );
        } else {
          // EXPIRED / TERMINATED / TERMINATION_REQUESTED / anything else non-ACTIVE: this session
          // can no longer be completed by the passenger. Mark it closed locally and fall through
          // to mint a genuinely fresh Cashfree order below instead of handing back a dead session.
          console.log("[CreateFareQr] Existing Cashfree order is no longer ACTIVE (status:", statusData?.order_status, ") for order", orderId, "-- creating a fresh one.");
          await supabaseAdmin
            .from("payments")
            .update({ payment_status: "failed", failure_reason: "cashfree_session_expired" })
            .eq("id", paymentRow.id)
            .eq("payment_status", "pending");
          paymentRow = null;
          cashfreeOrderId = null;
          paymentSessionId = null;
        }
      } catch (statusCheckError) {
        // Cashfree status-check itself unreachable -- best effort, fall back to the existing
        // session rather than blocking the driver entirely on a transient network blip.
        console.error("[CreateFareQr] Cashfree order-status check failed:", statusCheckError);
      }
    }

    if (!paymentRow) {
      const paymentCode = generatePaymentCode(paymentFor);
      const gstAmount = Number(order.gst_amount || 0);
      const baseAmount = Number((finalAmount - gstAmount).toFixed(2));
      const companyEarning = Number(order.commission_amount || 0);

      // The Cashfree customer for a fare QR is the PASSENGER who owes the fare (order.user_id),
      // not necessarily the caller of this function -- the assigned driver is also allowed to
      // open the QR. Resolve the passenger's real verified phone from auth.users.phone (mirrored
      // to public.users.phone) so Cashfree checkout shows "Payment Options for +91 <their number>"
      // instead of the old hardcoded "+91 9999999999". Reviewer bypass passenger (is_anonymous)
      // keeps the test number; a passenger with no phone on file falls back to Personal QR/Cash
      // rather than being shown an invented number.
      const resolvedPhone = await resolveCashfreeCustomerPhone(supabaseAdmin, order.user_id);
      if (resolvedPhone.phone === null) {
        console.error("[CreateFareQr] No phone on file for passenger", order.user_id, "on order", orderId, "-- cannot create Cashfree QR.");
        return Response.json(
          { success: true, qr_available: false, reason: QR_UNAVAILABLE_MESSAGE },
          { status: 200, headers: corsHeaders },
        );
      }
      const customerPhone = resolvedPhone.phone;

      const orderPayload = {
        order_id: paymentCode,
        order_amount: finalAmount,
        order_currency: "INR",
        customer_details: {
          customer_id: order.user_id,
          customer_name: "WayDropX User",
          customer_email: "support@waydropx.com",
          customer_phone: customerPhone,
        },
        // Restricts the hosted checkout that opens to UPI only (intent apps + Cashfree's own
        // "Scan and Pay" QR tab) -- hides cards/netbanking/wallet, since this button is
        // specifically the QR-for-a-passenger-to-scan experience, not a general checkout.
        order_meta: {
          payment_methods: "upi",
        },
      };

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
        // Full Cashfree error body stays server-side (logs only) and is now actually persisted to
        // a queryable row (previously only claimed in comments/docs, never written) so
        // engineering/support can see the exact Cashfree code/type/message behind a driver's
        // "temporarily unavailable" report without needing Edge Function log access.
        console.error("[CreateFareQr] Cashfree order creation failed:", cashfreeData);
        await supabaseAdmin.from("payments").insert({
          payment_code: generatePaymentCode(`${paymentFor}_FAILED`),
          user_id: order.user_id,
          rider_id: order.rider_id,
          payment_for: paymentFor,
          reference_id: orderId,
          amount: baseAmount,
          gst_amount: gstAmount,
          final_amount: finalAmount,
          platform_fee: 0,
          rider_earning: Number(order.rider_earning || 0),
          company_earning: companyEarning,
          payment_method: "cashfree",
          payment_gateway: "cashfree",
          payment_status: "failed",
          failure_reason: "cashfree_order_creation_failed",
          metadata: { cashfree_qr_last_error: cashfreeData },
        });
        return Response.json(
          { success: true, qr_available: false, reason: QR_UNAVAILABLE_MESSAGE },
          { status: 200, headers: corsHeaders },
        );
      }

      cashfreeOrderId = cashfreeData.order_id;
      paymentSessionId = cashfreeData.payment_session_id;

      const { data: inserted, error: insertError } = await supabaseAdmin
        .from("payments")
        .insert({
          payment_code: paymentCode,
          user_id: order.user_id,
          rider_id: order.rider_id,
          payment_for: paymentFor,
          reference_id: orderId,
          amount: baseAmount,
          gst_amount: gstAmount,
          final_amount: finalAmount,
          platform_fee: 0,
          rider_earning: Number(order.rider_earning || 0),
          company_earning: companyEarning,
          // payment_method_enum has no 'cashfree_qr' value -- 'cashfree' is the correct enum member;
          // the metadata.cashfree_qr block (written once the QR is fetched below) is what actually
          // distinguishes "checkout" vs "QR" payment_method rows for reporting.
          payment_method: "cashfree",
          payment_gateway: "cashfree",
          gateway_order_id: cashfreeOrderId,
          payment_status: "pending",
          metadata: { cashfree: cashfreeData },
        })
        .select()
        .single();

      if (insertError?.code === "23505") {
        // Race guard: idx_unique_pending_payment (user_id, payment_for, reference_id) WHERE
        // payment_status='pending' already exists at the DB level (baseline schema) but this
        // function never actually handled the resulting unique-violation -- it surfaced as a bare
        // "Failed to record payment" 500 instead of gracefully reusing the winner. Fixed here: a
        // concurrent call (driver + passenger both opening a Cashfree QR/checkout for the same fare
        // at the same instant) that lost the race now re-reads and hands back the winner's session
        // instead of erroring or minting a second Cashfree order for the same fare.
        const { data: winner } = await supabaseAdmin
          .from("payments")
          .select("*")
          .eq("user_id", order.user_id)
          .eq("payment_for", paymentFor)
          .eq("reference_id", orderId)
          // See the identical fix/comment above -- "processing" is not a valid payment_status_enum
          // value.
          .eq("payment_status", "pending")
          .maybeSingle();
        if (!winner) {
          console.error("[CreateFareQr] Unique violation on insert but no winner row found:", insertError);
          return Response.json({ success: false, message: "Failed to record payment" }, { status: 500, headers: corsHeaders });
        }
        paymentRow = winner;
        cashfreeOrderId = winner.gateway_order_id;
        paymentSessionId = winner.metadata?.cashfree?.payment_session_id ?? null;
      } else if (insertError || !inserted) {
        console.error("[CreateFareQr] Payment DB insert failed:", insertError);
        return Response.json({ success: false, message: "Failed to record payment" }, { status: 500, headers: corsHeaders });
      } else {
        paymentRow = inserted;
      }
    }

    if (!paymentSessionId) {
      console.error("[CreateFareQr] No active Cashfree payment session for order", orderId);
      return Response.json(
        { success: true, qr_available: false, reason: QR_UNAVAILABLE_MESSAGE },
        { status: 200, headers: corsHeaders },
      );
    }

    // =================================================
    // SUCCESS -- hand back exactly what the Flutter client needs to open Cashfree's own
    // UPI-restricted hosted checkout via CFWebCheckoutPaymentBuilder (same shape create-payment
    // already returns for the passenger's "Pay Online Securely" checkout). Cashfree renders its own
    // "Scan and Pay" QR inside that checkout for this exact order/amount -- WayDrop never sees or
    // constructs a raw QR payload itself.
    // =================================================
    return Response.json(
      {
        success: true,
        qr_available: true,
        payment_session_id: paymentSessionId,
        amount: finalAmount,
        payment_id: paymentRow.id,
        payment_code: paymentRow.payment_code,
        order_id: cashfreeOrderId,
      },
      { headers: corsHeaders },
    );
  } catch (e) {
    console.error("[CreateFareQr] Internal server error:", e);
    return Response.json({ success: false, message: "Internal server error" }, { status: 500, headers: corsHeaders });
  }
});
