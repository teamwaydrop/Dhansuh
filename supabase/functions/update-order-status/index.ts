import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { HttpError, httpErrorResponse } from "../_shared/http_errors.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

// Constant-time string compare for OTP verification -- avoids leaking how many
// leading digits matched via response-time differences (defense-in-depth on
// top of the existing check_otp_lockout/log_otp_attempt rate-limiting).
function timingSafeEqualString(a: unknown, b: unknown): boolean {
  const sa = typeof a === "string" ? a : "";
  const sb = typeof b === "string" ? b : "";
  if (sa.length !== sb.length) return false;
  let mismatch = 0;
  for (let i = 0; i < sa.length; i++) {
    mismatch |= sa.charCodeAt(i) ^ sb.charCodeAt(i);
  }
  return mismatch === 0;
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", {
      headers: corsHeaders,
    });
  }

  try {
    // =====================================================
    // SUPABASE
    // =====================================================
    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    // =====================================================
    // BODY
    // =====================================================
    const body = await req.json();
    const {
      order_id,
      new_status,
      changed_by,
      cancel_reason,
      pickup_otp,
      delivery_otp,
      latitude,
      longitude,
      device_id,
      // Optional, personal_upi fare payments only -- driver-entered evidence for the disputes
      // flow (this payment method has no gateway confirmation of its own, see the payment-pending
      // guards below).
      fare_payment_reference,
      fare_payment_screenshot_url,
      // Driver's own declaration of which DIRECT method they actually collected via
      // ('personal_upi' | 'cash'), sent only on the payment_pending -> completed transition. This
      // is what the QR-based architecture relies on instead of the retired
      // fare_payment_attempted_at passenger-app gate -- the passenger may pay by scanning the
      // driver's uploaded Personal QR entirely outside the app, so the app can never assume it
      // observed every real payment attempt. Ignored/invalid values default to 'personal_upi'.
      // NEVER accepted as 'cashfree' -- that value can only ever be set by the real Cashfree
      // webhook, never declared by the driver.
      settlement_method,
    } = body;

    // =====================================================
    // VALIDATION
    // =====================================================
    if (!order_id) {
      throw new HttpError(400, "Order ID required");
    }
    if (!new_status) {
      throw new HttpError(400, "New status required");
    }

    // =====================================================
    // AUTH
    // =====================================================
    const token = req.headers.get("Authorization")?.replace("Bearer ", "");

    if (!token) {
      return new Response(
        JSON.stringify({ success: false, error: "Missing auth token" }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: 401 }
      );
    }

    // Auth resolution and the order fetch are independent of each other's result (order_id was
    // already validated above, before either starts) -- run concurrently instead of serially.
    // Same two checks, same precedence (auth checked first below, exactly as before, so an
    // invalid token still always yields 401 regardless of order_id), same responses either way;
    // only removes one round trip's worth of serial wait per call.
    //
    // The order select also embeds `riders(user_id)` (P1-F: reduces the OWNERSHIP CHECK below from
    // a separate round trip to a field already present on `order`) -- unambiguous single-FK embed,
    // same pattern already used elsewhere in this codebase (e.g. intercity_searching_screen.dart's
    // `riders(*)`). `order.riders` is only ever read for this one ownership field, never returned
    // to the caller (the response uses `updatedOrder`, from the separate post-update select below).
    const [{ data: authData, error: authError }, { data: order, error: orderError }] =
      await Promise.all([
        supabase.auth.getUser(token),
        supabase.from("orders").select("*, riders(user_id)").eq("id", order_id).single(),
      ]);

    if (authError || !authData.user) {
      return new Response(
        JSON.stringify({ success: false, error: "Unauthorized" }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: 401 }
      );
    }

    // =====================================================
    // FETCH ORDER
    // =====================================================
    if (orderError || !order) {
      throw new HttpError(404, "Order not found");
    }

    // =====================================================
    // OWNERSHIP CHECK
    // Caller must be either the order's own customer, or the rider currently assigned to it.
    // Both isPassenger/isDriver are always resolved (not short-circuited) -- the payment_pending ->
    // completed guard below needs to know specifically WHICH participant is calling, not just
    // "some participant called", to block passenger self-completion.
    // =====================================================
    const isPassenger = order.user_id === authData.user.id;
    // order.riders is the embedded rider row added to the order select above (null if
    // order.rider_id is null, exactly mirroring the old "if (order.rider_id) { fetch }" guard).
    const isDriver = order.riders?.user_id === authData.user.id;

    const isAuthorizedCaller = isPassenger || isDriver;

    if (!isAuthorizedCaller) {
      return new Response(
        JSON.stringify({ success: false, error: "Forbidden: not a participant on this order" }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: 403 }
      );
    }

    const currentStatus = order.order_status;

    // =====================================================
    // FLOW TRANSITIONS
    // =====================================================
    const rideTransitions = {
      created: ["searching", "cancelled"],
      // Fare boosts while searching go exclusively through the boost-order-fare edge function now
      // (server-computed, not a status transition this function handles) -- "searching" is no
      // longer a valid new_status from "searching" here.
      searching: ["accepted", "cancelled"],
      accepted: ["rider_arrived", "cancelled", "searching"],
      rider_arrived: ["ongoing", "cancelled"],
      // Every ride/ride_sharing/intercity_ride order now stops at payment_pending before
      // completing, regardless of how payment_mode was set at booking -- the passenger picks how
      // to actually settle the fare (UPI Apps / Cash / Cashfree backup) fresh at drop-off via
      // mark_fare_payment_attempted, not upfront at booking. See the completion guard below for
      // how each settlement method is confirmed.
      ongoing: ["payment_pending"],
      // Travel Together intercity rides insert an explicit "reached destination, generate
      // completion OTP" step before payment (see intercity_bookings_screen.dart's
      // _markRideArrived/_verifyOtp) -- local rides never enter this state. Additive: local rides
      // still go ongoing -> payment_pending directly, this only makes the OTP-gated leg of the
      // intercity_ride flow route through the same guarded payment_pending stop instead of a
      // direct-to-completed write.
      rider_at_drop: ["payment_pending"],
      payment_pending: ["completed"],
      completed: [],
      cancelled: [],
    };

    const parcelTransitions = {
      created: ["searching", "cancelled"],
      searching: ["accepted", "cancelled"],
      accepted: ["rider_arrived", "cancelled", "searching"],
      rider_arrived: ["picked_up", "cancelled"],
      picked_up: ["rider_at_drop"],
      // Local/intercity parcel delivery now stops at payment_pending before completing, mirroring
      // the ride flow's ongoing -> payment_pending stop -- the partner marking the drop finished no
      // longer completes the order directly; payment must be confirmed first (see the completion
      // guard below, which already handles cashfree/personal_upi/cash for both "completed" and
      // "delivered" generically).
      rider_at_drop: ["payment_pending"],
      payment_pending: ["delivered"],
      delivered: [],
      cancelled: [],
    };

    // =====================================================
    // PICK FLOW
    // =====================================================
    let transitions = rideTransitions;
    if (
      order.order_type === "local_parcel" ||
      order.order_type === "intercity_parcel" ||
      order.order_type === "batch_delivery" ||
      order.order_type === "food_delivery" ||
      order.order_type === "grocery_delivery"
    ) {
      transitions = parcelTransitions;
    }

    // =====================================================
    // VALIDATE TRANSITION
    // =====================================================
    const allowedTransitions = transitions[currentStatus] || [];
    if (!allowedTransitions.includes(new_status)) {
      throw new HttpError(
        400,
        `Invalid transition from ${currentStatus} to ${new_status}`,
        "INVALID_TRANSITION"
      );
    }

    // =====================================================
    // ROLE-SCOPED TRANSITION GUARD (P1 fix)
    // accepted -> "searching" is exclusively the ASSIGNED RIDER's own "cancel this accepted
    // order" action (see rider_active_order_screen.dart's targetStatus logic -- the only client
    // codepath that ever sends it): it detaches the rider, marks their assignment cancelled, and
    // re-triggers dispatch (see the "POST-UPDATE ACTIONS FOR CANCELLATION BY RIDER" block below).
    // Previously only isAuthorizedCaller (passenger OR driver) gated this, so a passenger calling
    // the function directly with new_status:"searching" could self-trigger the rider-cancellation
    // side effects, bypassing the normal passenger-cancellation path (new_status:"cancelled",
    // handled separately and correctly terminal, no redispatch). No passenger-facing screen has
    // ever sent this transition -- confirmed via a repo-wide search for its only call site -- so
    // restricting it to the driver changes no legitimate behavior.
    // =====================================================
    if (currentStatus === "accepted" && new_status === "searching" && !isDriver) {
      return new Response(
        JSON.stringify({ success: false, error: "Forbidden: only the assigned rider can cancel an accepted order this way" }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: 403 }
      );
    }

    // =====================================================
    // PAYMENT-PENDING COMPLETION GUARDS
    // NEVER TRUST FRONTEND: these rules are what actually make "the ride can't complete until the
    // fare is settled, and only the driver can attest to a direct settlement" real, rather than
    // just a UI convention the client happens to follow.
    //
    // QR-based direct-payment architecture: a passenger paying the driver's uploaded Personal QR
    // (or handing over cash, or scanning the driver's Cashfree QR) happens entirely OUTSIDE this
    // app -- WayDrop never observes the transfer itself for personal_upi/cash. There is therefore
    // no passenger-side "I attempted to pay" signal this guard can trust or require anymore
    // (the old fare_payment_attempted_at gate assumed the passenger always paid through the app's
    // own UPI-intent/cash button, which is no longer the primary path). The real control is:
    //   - 'cashfree': payment_status only ever flips to 'paid' via a real, server-verified Cashfree
    //     webhook/poll success (verify-payment/cashfree-webhook). Neither participant can
    //     self-report this, and the driver cannot override an order already on the 'cashfree' path.
    //   - 'personal_upi' / 'cash' (direct settlement): the ASSIGNED DRIVER's own "Confirm Payment
    //     Received" action IS the confirmation -- checked below via isDriver, never isPassenger.
    //     The driver declares which direct method via `settlement_method` in this same request.
    //
    // Legacy 'upi' (the retired direct-to-driver deep-link order type) is handled only so any order
    // already in-flight from before this change can still complete -- no new order can select it.
    // =====================================================
    const isLegacyUpiOrder = (order.payment_mode || "cash").toLowerCase() === "upi";

    // Set only inside the direct-settlement branch below, when the order didn't already have a
    // fare_payment_method on file (i.e. the driver's own QR screen is the first place this trip's
    // settlement method is ever recorded). Consumed by the UPDATE PAYLOAD section further down.
    let resolvedDirectSettlementMethod: "personal_upi" | "cash" | null = null;

    // The driver's "Confirm Payment Received" action resolves to this transition. Parcel orders
    // now stop at payment_pending too (rider_at_drop -> payment_pending -> delivered, mirroring
    // ongoing -> payment_pending -> completed for rides) -- "delivered" is included here so the
    // exact same cashfree/personal_upi/cash resolution and driver-only attestation applies to a
    // parcel's final "Confirm Payment Received" action, not just a ride's.
    if (currentStatus === "payment_pending" && (new_status === "completed" || new_status === "delivered")) {
      const fareMethod = order.fare_payment_method;

      if (fareMethod === "cashfree") {
        // Gateway-collected -- only real, server-verified Cashfree success can ever satisfy this.
        // The driver's tap here (after payment_status is already 'paid') is just closing out the
        // ride, not attesting to receipt -- still driver-only, since the passenger must never be
        // the one to flip order_status to completed.
        if (order.payment_status !== "paid") {
          throw new HttpError(
            400,
            "Cannot complete this order before the passenger's Cashfree payment has been confirmed",
            "PAYMENT_NOT_CONFIRMED"
          );
        }
        if (!isDriver) {
          throw new HttpError(403, "Only the assigned driver can complete this order.");
        }
      } else if (isLegacyUpiOrder && fareMethod == null) {
        if (!order.upi_payment_prompted_at) {
          throw new HttpError(
            400,
            "Cannot confirm UPI payment before the passenger has been prompted to pay",
            "PAYMENT_NOT_PROMPTED"
          );
        }
        if (!isDriver) {
          throw new HttpError(403, "Only the assigned driver can confirm UPI payment receipt.");
        }
      } else {
        // Direct settlement (personal_upi / cash, or not yet decided -- the driver's own QR
        // screen, not the passenger's app, is now the primary place this is ever chosen).
        // Passenger self-completion is never permitted here: money that supposedly reached the
        // driver directly can only ever be attested to by the driver who received it.
        if (!isDriver) {
          throw new HttpError(
            403,
            "Only the assigned driver can confirm receipt of a direct (Personal QR / Cash) payment."
          );
        }

        if (fareMethod !== "cash" && fareMethod !== "personal_upi") {
          // Nothing recorded yet (the common QR-flow case) -- take the driver's own declaration of
          // which direct method they collected via. Already fixed/recorded methods are left as-is
          // rather than let a later request silently relabel how the fare was actually collected.
          resolvedDirectSettlementMethod = settlement_method === "cash" ? "cash" : "personal_upi";
        }
        // payment_status/fare_payment_method are set below, as part of this same completion --
        // the driver's confirmation is itself the proof for a direct (driver-collected) settlement.
      }
    } else if (
      currentStatus === "rider_at_drop" &&
      new_status === "delivered" &&
      (order.order_type === "local_parcel" ||
        order.order_type === "intercity_parcel" ||
        order.order_type === "batch_delivery" ||
        order.order_type === "food_delivery" ||
        order.order_type === "grocery_delivery") &&
      (order.payment_mode || "cash").toLowerCase() === "online" &&
      order.payment_status !== "paid" &&
      order.fare_payment_method == null
    ) {
      // FIX (WayDrop parcel payment-record correctness audit): a parcel booked payment_mode='online'
      // has no mechanism anywhere in this app to ever actually collect that payment -- create-fare-qr
      // requires order_status='payment_pending', and parcelTransitions has no payment_pending step at
      // all. Previously this silently fell through to isDirectCollection=true further below WITHOUT
      // ever setting fare_payment_method/payment_status, leaving the order's own record internally
      // inconsistent: wallet/COD accounting already treated it as a direct (rider-collected)
      // settlement, but payment_status stayed 'pending' forever with no explicit attestation from
      // anyone. This does NOT change the financial outcome (isDirectCollection was, and remains, true
      // for this exact case) -- it makes the order's own record honest about it, using the identical
      // driver-declaration mechanism already proven safe for rides' direct-settlement branch above.
      // Unreachable for gateway-collected/cash/upi/already-recorded parcels -- payment_mode must be
      // 'online' AND still unpaid AND no fare_payment_method already on file.
      resolvedDirectSettlementMethod = settlement_method === "cash" ? "cash" : "personal_upi";
    }

    // =====================================================
    // OTP VALIDATION WITH LOCKOUT & ATTEMPT LOGGING
    // =====================================================
    if (
      order.order_type === "ride" ||
      order.order_type === "intercity_ride" ||
      order.order_type === "ride_sharing"
    ) {
      // rider_arrived -> ongoing requires pickup otp
      if (currentStatus === "rider_arrived" && new_status === "ongoing") {
        if (!pickup_otp) {
          throw new HttpError(400, "Pickup OTP required");
        }

        // Fetch user phone for verification
        const { data: userRecord } = await supabase
          .from("users")
          .select("phone")
          .eq("id", order.user_id)
          .single();
        const phone = userRecord?.phone || "";

        if (phone) {
          // Check Lockout
          const { data: lockoutCheck, error: lockoutErr } = await supabase.rpc(
            "check_otp_lockout",
            { p_phone: phone }
          );
          if (lockoutErr) {
            console.error("[StatusUpdate] Lockout check error:", lockoutErr);
          } else if (lockoutCheck?.locked) {
            throw new HttpError(429, lockoutCheck.message || "Account is locked for OTP verification.", "OTP_LOCKED");
          }
        }

        if (!timingSafeEqualString(pickup_otp, order.pickup_otp)) {
          if (phone) {
            await supabase.rpc("log_otp_attempt", {
              p_phone: phone,
              p_is_successful: false,
              p_action_type: "verify",
              p_otp_code: pickup_otp,
              p_client_ip: req.headers.get("x-real-ip") || req.headers.get("cf-connecting-ip") || null,
            });
          }
          throw new HttpError(400, "Invalid pickup OTP", "INVALID_OTP");
        } else {
          if (phone) {
            await supabase.rpc("log_otp_attempt", {
              p_phone: phone,
              p_is_successful: true,
              p_action_type: "verify",
              p_otp_code: pickup_otp,
              p_client_ip: req.headers.get("x-real-ip") || req.headers.get("cf-connecting-ip") || null,
            });
          }
        }
      }
    }

    if (
      order.order_type === "local_parcel" ||
      order.order_type === "intercity_parcel" ||
      order.order_type === "batch_delivery" ||
      order.order_type === "food_delivery" ||
      order.order_type === "grocery_delivery"
    ) {
      // rider_arrived -> picked_up requires pickup otp
      if (currentStatus === "rider_arrived" && new_status === "picked_up") {
        if (!pickup_otp) {
          throw new HttpError(400, "Pickup OTP required");
        }

        // Fetch user phone for verification
        const { data: userRecord } = await supabase
          .from("users")
          .select("phone")
          .eq("id", order.user_id)
          .single();
        const phone = userRecord?.phone || "";

        if (phone) {
          // Check Lockout
          const { data: lockoutCheck, error: lockoutErr } = await supabase.rpc(
            "check_otp_lockout",
            { p_phone: phone }
          );
          if (lockoutErr) {
            console.error("[StatusUpdate] Lockout check error:", lockoutErr);
          } else if (lockoutCheck?.locked) {
            throw new HttpError(429, lockoutCheck.message || "Account is locked for OTP verification.", "OTP_LOCKED");
          }
        }

        if (!timingSafeEqualString(pickup_otp, order.pickup_otp)) {
          if (phone) {
            await supabase.rpc("log_otp_attempt", {
              p_phone: phone,
              p_is_successful: false,
              p_action_type: "verify",
              p_otp_code: pickup_otp,
              p_client_ip: req.headers.get("x-real-ip") || req.headers.get("cf-connecting-ip") || null,
            });
          }
          throw new HttpError(400, "Invalid pickup OTP", "INVALID_OTP");
        } else {
          if (phone) {
            await supabase.rpc("log_otp_attempt", {
              p_phone: phone,
              p_is_successful: true,
              p_action_type: "verify",
              p_otp_code: pickup_otp,
              p_client_ip: req.headers.get("x-real-ip") || req.headers.get("cf-connecting-ip") || null,
            });
          }
        }
      }

      // rider_at_drop -> payment_pending requires delivery otp (verified at hand-off, before
      // payment -- delivered is now only reachable from payment_pending, see parcelTransitions).
      if (currentStatus === "rider_at_drop" && new_status === "payment_pending") {
        if (!delivery_otp) {
          throw new HttpError(400, "Delivery OTP required");
        }

        const phone = order.receiver_phone || "";

        if (phone) {
          // Check Lockout
          const { data: lockoutCheck, error: lockoutErr } = await supabase.rpc(
            "check_otp_lockout",
            { p_phone: phone }
          );
          if (lockoutErr) {
            console.error("[StatusUpdate] Lockout check error:", lockoutErr);
          } else if (lockoutCheck?.locked) {
            throw new HttpError(429, lockoutCheck.message || "Account is locked for OTP verification.", "OTP_LOCKED");
          }
        }

        if (!timingSafeEqualString(delivery_otp, order.delivery_otp)) {
          if (phone) {
            await supabase.rpc("log_otp_attempt", {
              p_phone: phone,
              p_is_successful: false,
              p_action_type: "verify",
              p_otp_code: delivery_otp,
              p_client_ip: req.headers.get("x-real-ip") || req.headers.get("cf-connecting-ip") || null,
            });
          }
          throw new HttpError(400, "Invalid delivery OTP", "INVALID_OTP");
        } else {
          if (phone) {
            await supabase.rpc("log_otp_attempt", {
              p_phone: phone,
              p_is_successful: true,
              p_action_type: "verify",
              p_otp_code: delivery_otp,
              p_client_ip: req.headers.get("x-real-ip") || req.headers.get("cf-connecting-ip") || null,
            });
          }
        }
      }
    }

    // =====================================================
    // TIMESTAMP UPDATES
    // =====================================================
    const timestampUpdates: Record<string, any> = {};

    if (new_status === "accepted") {
      timestampUpdates.accepted_at = new Date().toISOString();
      // NOTE: final_fare must never be overwritten here. create-order sets it once, correctly
      // (null unless a promo discount applies, in which case it's current_fare - discount) -- an
      // unconditional `final_fare = current_fare` on acceptance would silently erase that discount
      // for every promo order the instant a rider accepted it.
    }
    if (new_status === "rider_arrived" || new_status === "rider_at_pickup") {
      timestampUpdates.rider_arrived_at = new Date().toISOString();
    }
    if (new_status === "picked_up" || new_status === "ongoing") {
      timestampUpdates.picked_up_at = new Date().toISOString();
    }
    if (new_status === "rider_at_drop") {
      timestampUpdates.rider_at_drop_at = new Date().toISOString();
    }
    if (new_status === "completed" || new_status === "delivered") {
      timestampUpdates.completed_at = new Date().toISOString();
    }
    if (new_status === "cancelled") {
      timestampUpdates.cancelled_at = new Date().toISOString();
      timestampUpdates.cancel_reason = cancel_reason || null;
      // Issue 7 fix: derive the actor server-side from the already-resolved isDriver/isPassenger
      // (never trust a client-supplied value -- cancel-order's proxy doesn't even forward one).
      // Written in the SAME update as order_status so the AFTER trigger's NEW.* sees it with no
      // race, letting send_order_status_notifications_core report the correct actor per side.
      // orders.cancelled_by is cancelled_by_enum ('user' | 'rider' | 'admin' | 'system') -- there
      // is no 'passenger' label; the passenger/customer actor is represented as 'user'.
      timestampUpdates.cancelled_by = isDriver ? "rider" : (isPassenger ? "user" : null);
    }
    if (new_status === "searching") {
      // Reverting back to searching because rider cancelled
      timestampUpdates.accepted_at = null;
      timestampUpdates.rider_arrived_at = null;
      timestampUpdates.rider_id = null;
    }
    // Fare-boost-while-searching retries are handled exclusively by the boost-order-fare edge
    // function (server-computed), never by this one -- see the "searching" -> "searching" removal
    // from rideTransitions/parcelTransitions above.

    // =====================================================
    // UPDATE PAYLOAD
    // Completing/delivering via a direct (driver-collected) settlement is itself the driver's
    // confirmation that they were paid directly by the passenger (swiped on the collection sheet
    // at drop-off) — so payment_status flips to 'paid' in the same update rather than staying
    // 'pending' forever. A 'cashfree' settlement is excluded here -- its payment_status was
    // already set to 'paid' earlier, by the real Cashfree webhook, and the guard above already
    // required that before allowing this transition at all.
    //
    // fare_payment_method (the passenger's fresh choice at payment_pending) is the sole decider
    // whenever it's set -- always true for ride/ride_sharing/intercity_ride, which now always
    // pass through payment_pending regardless of booking-time payment_mode. Parcels haven't been
    // migrated to that flow yet and never set fare_payment_method, so they fall back to their
    // booking-time payment_mode exactly as before.
    // =====================================================
    const orderPaymentMode = (order.payment_mode || "cash").toLowerCase();
    // The order's fare_payment_method as of THIS request -- either already on file, or just
    // resolved above from the driver's own settlement_method declaration (QR-flow first-recording
    // case). Falls back to booking-time payment_mode only for parcels/legacy orders that never go
    // through payment_pending at all.
    const fareMethod = (order.fare_payment_method as string | null) ?? resolvedDirectSettlementMethod;
    const isDirectSettlement = fareMethod != null
      ? (fareMethod === "personal_upi" || fareMethod === "cash")
      : (orderPaymentMode === "cash" || orderPaymentMode === "upi");
    const isCompleting = new_status === "completed" || new_status === "delivered";

    const updatePayload: Record<string, any> = {
      order_status: new_status,
      updated_at: new Date().toISOString(),
      ...timestampUpdates,
    };

    if (isCompleting && resolvedDirectSettlementMethod) {
      updatePayload.fare_payment_method = resolvedDirectSettlementMethod;
    }

    if (isCompleting && isDirectSettlement) {
      updatePayload.payment_status = "paid";
    }

    // Direct (personal UPI / cash) settlements have no gateway confirmation -- this completion
    // call IS the confirmation. Record the audit trail the disputes flow needs; both fields are
    // optional and self-entered by the driver/passenger, since NPCI gives us no transaction
    // reference for a plain P2P push, and cash has no transaction reference at all.
    if (isCompleting && fareMethod != null && (fareMethod === "personal_upi" || fareMethod === "cash")) {
      updatePayload.fare_paid_at = new Date().toISOString();
      if (fare_payment_reference) updatePayload.fare_payment_reference = fare_payment_reference;
      if (fare_payment_screenshot_url) updatePayload.fare_payment_screenshot_url = fare_payment_screenshot_url;
    }

    // =====================================================
    // UPDATE ORDER
    // Optimistic lock: only succeed if order_status still matches what we
    // validated the transition against, so a concurrent/retried call for the
    // same transition (e.g. two "complete ride" calls) can't both pass and
    // both execute the wallet-credit block below.
    //
    // PERF FIX (migration 20260813000000, forensic incident on order 66759dad-b386-4814-8065-
    // c6f9182e5c01): for the two transitions that trigger the settlement chain (completed/delivered),
    // the update itself PLUS settle_rider_assignment PLUS subscription-waiver fare_breakdown PLUS
    // apply_order_government_tax PLUS credit_rider_for_completed_order PLUS the history insert are
    // now one atomic RPC call instead of up to 7 sequential round trips -- proven live to take upwards
    // of 80 seconds under contention. Every guard above this point (ownership, role-scoped transition
    // guard, payment-pending completion guards, OTP verification) is completely unchanged and already
    // ran before this point is reached -- the RPC only ever applies an already-fully-authorized
    // completion, mirroring complete_intercity_parcel_delivery's already-proven pattern. Every other
    // transition (accepted, rider_arrived, ongoing, payment_pending, rider_at_drop, cancelled,
    // searching, picked_up) is completely untouched -- still the exact same single `.update()` call.
    // =====================================================
    let updatedOrder: Record<string, any>;

    if (new_status === "completed" || new_status === "delivered") {
      const { data: settleResult, error: settleError } = await supabase.rpc("complete_order_and_settle", {
        p_order_id: order_id,
        p_new_status: new_status,
        p_previous_status: currentStatus,
        p_changed_by: changed_by || order.user_id || "system",
        p_fare_payment_method_to_set: (updatePayload.fare_payment_method as string | undefined) ?? null,
        p_mark_paid: updatePayload.payment_status === "paid",
        p_stamp_fare_paid_at: updatePayload.fare_paid_at != null,
        p_fare_payment_reference: (updatePayload.fare_payment_reference as string | undefined) ?? null,
        p_fare_payment_screenshot_url: (updatePayload.fare_payment_screenshot_url as string | undefined) ?? null,
      });

      if (settleError) {
        throw settleError;
      }
      if (!settleResult?.success) {
        // Preserve the RPC's own structured error code: CONFLICT is a benign, expected outcome of
        // a concurrent/duplicate completion request (double-tap, a timed-out retry, two devices)
        // -- it must surface as 409, not a generic 500, so the client can tell "safe to reconcile"
        // apart from an actual server failure.
        if (settleResult?.code === "CONFLICT") {
          throw new HttpError(409, "Order status changed by another request. Please retry.", "CONFLICT");
        }
        if (settleResult?.code === "INVALID_REQUEST") {
          throw new HttpError(400, settleResult?.message || "Failed to complete order", "INVALID_REQUEST");
        }
        // INTERNAL_ERROR or an unrecognized code -- genuinely unexpected, stays a 500.
        throw new Error(settleResult?.message || "Failed to complete order");
      }
      updatedOrder = settleResult.order;
    } else {
      const { data, error: updateError } = await supabase
        .from("orders")
        .update(updatePayload)
        .eq("id", order_id)
        .eq("order_status", currentStatus)
        .select()
        .single();

      if (updateError) {
        if (updateError.code === "PGRST116") {
          // Optimistic-lock miss -- another request already changed this order's status. Same
          // benign concurrent-request condition as the completion path above: 409, not 500.
          throw new HttpError(409, "Order status changed by another request. Please retry.", "CONFLICT");
        }
        throw updateError;
      }
      updatedOrder = data;
    }

    // =====================================================
    // PARCEL SECURITY COMPLIANCE LOGS
    // Phase M (E4b): this is a best-effort audit-log write -- its result is never read afterward,
    // its error was already non-fatal (caught, logged, never rethrown), it does not control order
    // state/payment/OTP/dispatch/notification, and no DB trigger exists on parcel_security_logs
    // (all confirmed in the Phase L audit). Reuses the SAME EdgeRuntime.waitUntil pattern already
    // established in this file for the start-dispatch trigger below -- the entire block (all four
    // conditional inserts, byte-for-byte unchanged) now runs inside a promise that is handed to
    // waitUntil instead of awaited directly, so it no longer blocks the HTTP response. If
    // EdgeRuntime is unavailable, it still fires in the background with the exact same best-effort
    // semantics the existing start-dispatch fallback already accepts.
    // =====================================================
    const parcelSecurityLogPromise = (async () => {
      const isParcel =
        updatedOrder.order_type === "local_parcel" ||
        updatedOrder.order_type === "intercity_parcel" ||
        updatedOrder.order_type === "batch_delivery" ||
        updatedOrder.order_type === "food_delivery" ||
        updatedOrder.order_type === "grocery_delivery";

      if (isParcel) {
        const ipAddress = req.headers.get("x-real-ip") || req.headers.get("cf-connecting-ip") || null;
        const finalDeviceId = device_id || null;

        // Transition: rider_arrived -> picked_up
        if (currentStatus === "rider_arrived" && new_status === "picked_up") {
          console.log(`[StatusUpdate] Logging compliance events for picked_up: pickup_otp_verified and parcel_handed_to_rider`);
          const eventLat = latitude ?? updatedOrder.pickup_lat;
          const eventLng = longitude ?? updatedOrder.pickup_lng;

          await supabase.from("parcel_security_logs").insert([
            {
              order_id: updatedOrder.id,
              sender_user_id: updatedOrder.user_id,
              rider_id: updatedOrder.rider_id,
              event_type: "pickup_otp_verified",
              latitude: eventLat,
              longitude: eventLng,
              event_latitude: eventLat,
              event_longitude: eventLng,
              ip_address: ipAddress,
              device_id: finalDeviceId,
              metadata: {
                otp_verified: true,
                otp_type: "pickup",
                verified_at: new Date().toISOString(),
                client_timestamp: new Date().toISOString(),
              }
            },
            {
              order_id: updatedOrder.id,
              sender_user_id: updatedOrder.user_id,
              rider_id: updatedOrder.rider_id,
              event_type: "parcel_handed_to_rider",
              latitude: eventLat,
              longitude: eventLng,
              event_latitude: eventLat,
              event_longitude: eventLng,
              ip_address: ipAddress,
              device_id: finalDeviceId,
              metadata: {
                client_timestamp: new Date().toISOString(),
              }
            }
          ]);
        }

        // Transition: picked_up -> rider_at_drop
        if (currentStatus === "picked_up" && new_status === "rider_at_drop") {
          console.log(`[StatusUpdate] Logging compliance event for rider_at_drop: rider_arrived_drop`);
          const eventLat = latitude ?? updatedOrder.destination_lat;
          const eventLng = longitude ?? updatedOrder.destination_lng;

          await supabase.from("parcel_security_logs").insert({
            order_id: updatedOrder.id,
            sender_user_id: updatedOrder.user_id,
            rider_id: updatedOrder.rider_id,
            event_type: "rider_arrived_drop",
            latitude: eventLat,
            longitude: eventLng,
            event_latitude: eventLat,
            event_longitude: eventLng,
            ip_address: ipAddress,
            device_id: finalDeviceId,
            metadata: {
              client_timestamp: new Date().toISOString(),
            }
          });
        }

        // Transition: rider_at_drop -> payment_pending (delivery OTP verified at hand-off, before
        // payment -- split from the "parcel_delivered" event below, which now only fires once the
        // order actually reaches its terminal "delivered" status after payment confirmation).
        if (currentStatus === "rider_at_drop" && new_status === "payment_pending") {
          console.log(`[StatusUpdate] Logging compliance event for payment_pending: delivery_otp_verified`);
          const eventLat = latitude ?? updatedOrder.destination_lat;
          const eventLng = longitude ?? updatedOrder.destination_lng;

          await supabase.from("parcel_security_logs").insert({
            order_id: updatedOrder.id,
            sender_user_id: updatedOrder.user_id,
            rider_id: updatedOrder.rider_id,
            event_type: "delivery_otp_verified",
            latitude: eventLat,
            longitude: eventLng,
            event_latitude: eventLat,
            event_longitude: eventLng,
            ip_address: ipAddress,
            device_id: finalDeviceId,
            metadata: {
              otp_verified: true,
              otp_type: "delivery",
              verified_at: new Date().toISOString(),
              client_timestamp: new Date().toISOString(),
            }
          });
        }

        // Transition: payment_pending -> delivered
        if (currentStatus === "payment_pending" && new_status === "delivered") {
          console.log(`[StatusUpdate] Logging compliance event for delivered: parcel_delivered`);
          const eventLat = latitude ?? updatedOrder.destination_lat;
          const eventLng = longitude ?? updatedOrder.destination_lng;

          await supabase.from("parcel_security_logs").insert({
            order_id: updatedOrder.id,
            sender_user_id: updatedOrder.user_id,
            rider_id: updatedOrder.rider_id,
            event_type: "parcel_delivered",
            latitude: eventLat,
            longitude: eventLng,
            event_latitude: eventLat,
            event_longitude: eventLng,
            ip_address: ipAddress,
            device_id: finalDeviceId,
            metadata: {
              client_timestamp: new Date().toISOString(),
            }
          });
        }
      }
    })().catch((e) => {
      console.error("[StatusUpdate] Error inserting parcel compliance logs:", e);
    });

    if (typeof (globalThis as any).EdgeRuntime !== "undefined") {
      (globalThis as any).EdgeRuntime.waitUntil(parcelSecurityLogPromise);
    }

    // =====================================================
    // STATE TRANSITION DISPATCH / CANCELLATION ACTIONS
    // =====================================================
    if (new_status === "cancelled") {
      const nowStr = new Date().toISOString();
      console.log(`[StatusUpdate] Order cancelled. Expiring all outstanding sent assignments/logs for order ${order_id}`);

      // Phase K (E1): these three writes are independent -- two touch disjoint row sets on
      // rider_assignments (assignment_status='sent' vs 'accepted' can never be the same row), the
      // third touches a different table entirely. None reads another's result, and none of their
      // results were checked before this change either -- run concurrently instead of serially.
      await Promise.all([
        supabase
          .from("rider_assignments")
          .update({
            assignment_status: "expired",
            responded_at: nowStr,
            updated_at: nowStr,
          })
          .eq("order_id", order_id)
          .eq("assignment_status", "sent"),

        supabase
          .from("rider_assignments")
          .update({
            assignment_status: "cancelled",
            responded_at: nowStr,
            updated_at: nowStr,
          })
          .eq("order_id", order_id)
          .eq("assignment_status", "accepted"),

        supabase
          .from("order_assignment_logs")
          .update({
            assignment_status: "expired",
            responded_at: nowStr,
          })
          .eq("order_id", order_id)
          .eq("assignment_status", "sent"),
      ]);
    }

    if (new_status === "accepted") {
      const nowStr = new Date().toISOString();
      const acceptedRiderId = updatedOrder.rider_id;
      console.log(`[StatusUpdate] Order accepted by ${acceptedRiderId}. Expiring all other outstanding sent assignments/logs for order ${order_id}`);

      if (acceptedRiderId) {
        // Phase K (E2): different tables, neither reads the other's result, and neither result was
        // checked before this change either -- run concurrently instead of serially.
        await Promise.all([
          supabase
            .from("rider_assignments")
            .update({
              assignment_status: "expired",
              updated_at: nowStr,
            })
            .eq("order_id", order_id)
            .neq("rider_id", acceptedRiderId)
            .eq("assignment_status", "sent"),

          supabase
            .from("order_assignment_logs")
            .update({
              assignment_status: "expired",
              responded_at: nowStr,
            })
            .eq("order_id", order_id)
            .neq("rider_id", acceptedRiderId)
            .eq("assignment_status", "sent"),
        ]);
      }
    }

    // =====================================================
    // POST-UPDATE ACTIONS FOR CANCELLATION BY RIDER
    // =====================================================
    if (new_status === "searching" && order.rider_id) {
      console.log(`update-order-status => Rider cancelled accepted order. Updating assignments and triggering dispatch. riderId: ${order.rider_id}`);
      const cancellingRiderId = order.rider_id;
      const now = new Date().toISOString();

      // Phase K (E3): these two writes are independent (different tables, neither reads the
      // other's result) -- run concurrently instead of serially. Each result is still captured and
      // logged individually, exactly as before -- Promise.all only rejects if a promise itself
      // throws, and these supabase-js calls resolve normally with {data, error} even on a DB-level
      // error, so this preserves the existing non-fatal, logged-not-thrown behavior exactly: a
      // failure in either write still never fails the request.
      const [{ error: assignmentError }, { error: logError }] = await Promise.all([
        // Update rider_assignments to cancelled
        supabase
          .from("rider_assignments")
          .update({
            assignment_status: "cancelled",
            responded_at: now,
            updated_at: now,
          })
          .eq("order_id", order_id)
          .eq("rider_id", cancellingRiderId)
          .eq("assignment_status", "accepted"),

        // Update order_assignment_logs to cancelled
        supabase
          .from("order_assignment_logs")
          .update({
            assignment_status: "cancelled",
            responded_at: now,
          })
          .eq("order_id", order_id)
          .eq("rider_id", cancellingRiderId)
          .eq("assignment_status", "accepted"),
      ]);

      if (assignmentError) {
        console.error("Error cancelling rider_assignment:", assignmentError);
      }

      if (logError) {
        console.error("Error cancelling order_assignment_logs:", logError);
      }

      // Trigger start-dispatch asynchronously
      const functionUrl = `${Deno.env.get("SUPABASE_URL")}/functions/v1/start-dispatch`;
      const dispatchPromise = fetch(functionUrl, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Authorization": `Bearer ${Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")}`,
          "apikey": Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
        },
        body: JSON.stringify({ order_id, is_background: true }),
      }).then(async (res) => {
        console.log("Async start-dispatch trigger status:", res.status);
      }).catch((err) => {
        console.error("Async start-dispatch trigger error:", err);
      });

      if (typeof (globalThis as any).EdgeRuntime !== "undefined") {
        (globalThis as any).EdgeRuntime.waitUntil(dispatchPromise);
      }
    }

    // =====================================================
    // UPDATE RIDER STATISTICS & WALLET/COD BALANCES
    // Consolidated into complete_order_and_settle (migration 20260813000000) as part of the same
    // atomic RPC call made above for completed/delivered -- settle_rider_assignment, the
    // subscription-waiver fare_breakdown, apply_order_government_tax, and
    // credit_rider_for_completed_order all already ran, inside that one RPC, before this point.
    // Nothing left to do here for this transition.
    // =====================================================

    // =====================================================
    // STATUS HISTORY
    // =====================================================
    // UPDATE TRAVEL PLANS STATUS ON COMPLETED INTERCITY RIDES/PARCELS
    // =====================================================
    if (
      (updatedOrder.order_type === "intercity_parcel" || updatedOrder.order_type === "intercity_ride") &&
      (new_status === "delivered" || new_status === "completed")
    ) {
      const acceptedRiderId = updatedOrder.rider_id;
      if (acceptedRiderId) {
        const { data: activeOrders, error: countErr } = await supabase
          .from("orders")
          .select("id")
          .eq("rider_id", acceptedRiderId)
          .eq("order_type", updatedOrder.order_type)
          .in("order_status", ["accepted", "rider_arrived", "ongoing", "rider_at_drop", "payment_pending"]);

        if (!countErr && (!activeOrders || activeOrders.length === 0)) {
          // Resolve THIS order's own travel plan by its intercity_requests link. Keying off
          // route_id (not the order's pickup/destination city) is required for Via-declared
          // plans, where the passenger frequently boards at an intermediate town and the order's
          // pickup_city no longer equals the plan's. Also transitions plans that the
          // booking-count trigger (20260617000001) has already flipped from 'active' to
          // 'fully_booked' -- for a single-seat plan that is the very first acceptance, so by
          // completion time the plan is almost never still 'active'. The old
          // `.eq("status","active")` + city match therefore left completed trips' plans stuck on
          // the traveller's Home screen indefinitely.
          const { data: reqRows } = await supabase
            .from("intercity_requests")
            .select("route_id")
            .eq("parcel_id", order_id)
            .not("route_id", "is", null);
          const routeIds = Array.from(
            new Set((reqRows || []).map((r: { route_id: string | null }) => r.route_id).filter(Boolean))
          ) as string[];

          if (routeIds.length > 0) {
            const { error: planErr } = await supabase
              .from("rider_travel_plans")
              .update({ status: "completed" })
              .in("id", routeIds)
              .eq("rider_id", acceptedRiderId)
              .in("status", ["active", "fully_booked"]);
            if (planErr) {
              console.error(`[StatusUpdate] Failed to complete travel plan(s) ${routeIds.join(",")}:`, planErr);
            } else {
              console.log(`[StatusUpdate] Marked travel plan(s) ${routeIds.join(",")} completed for rider ${acceptedRiderId}`);
            }
          } else {
            // Fallback for orders with no resolvable intercity_requests link -- endpoint-city
            // match, now also covering 'fully_booked'.
            await supabase
              .from("rider_travel_plans")
              .update({ status: "completed" })
              .eq("rider_id", acceptedRiderId)
              .in("status", ["active", "fully_booked"])
              .eq("pickup_city", updatedOrder.pickup_city)
              .eq("destination_city", updatedOrder.destination_city);
            console.log(`[StatusUpdate] Marked travel plans as completed for rider ${acceptedRiderId} on route ${updatedOrder.pickup_city} -> ${updatedOrder.destination_city} (city fallback)`);
          }
        }
      }
    }

    // =====================================================
    // SYNC THE LINKED intercity_requests NEGOTIATION ROW TO MATCH THE ORDER'S TERMINAL STATE
    // Nothing else in the app ever writes 'completed' to intercity_requests.status (verified by
    // grepping every call site) — this is the single place that makes it reachable, mirroring the
    // rider_travel_plans completion sync directly above. Scoped to rows still in an active booking
    // state (confirmed/paid/in_progress) so negotiation-stage rows (request_sent/discussion_started/
    // fare_agreed), which have their own expiry/reject handling, are left untouched for the
    // delivered/completed case.
    //
    // P2 fix: a CANCEL is different -- if the passenger cancels before the traveller ever
    // accepted (order still "searching", request still request_sent/discussion_started/
    // fare_agreed), this sync previously never ran (only confirmed/paid/in_progress matched),
    // leaving a permanent "ghost" Accept Request card on the traveller's Travel Plan screen for
    // an order that no longer exists. accept_intercity_request already blocks accepting it
    // (order_status != 'searching' -> ORDER_ALREADY_ASSIGNED), so this was never a financial/
    // overbooking risk -- just a stale-UI/confusing-error correctness bug. On cancel only, also
    // sync the three pre-acceptance statuses.
    //
    // cancelled_by_actor (migration 20260901000024): stamped in this SAME update, only on the
    // cancelled path, from the already-resolved server-side isDriver/isPassenger (never a
    // client-supplied value) -- identical derivation to orders.cancelled_by above, so
    // on_intercity_request_change()'s NEW.cancelled_by_actor = 'user' branch sees it with no race.
    // 'user' (not 'passenger') matches the same actor-attribution convention orders.cancelled_by
    // already uses: there is no 'passenger' label anywhere in this codebase, only 'user' | 'rider'
    // | 'admin' | 'system'. This column has no enum constraint of its own, but must still agree
    // with migration 20260901000024's trigger check or the self-attribution fix would silently
    // never fire. No other field in this update, no second write, no new notification -- the
    // existing dedup-suppression in send_order_status_notifications_core (migration
    // 20260901000025) and on_intercity_request_change's own single-notify-per-row shape are both
    // untouched.
    // =====================================================
    if (
      (updatedOrder.order_type === "intercity_parcel" || updatedOrder.order_type === "intercity_ride") &&
      (new_status === "delivered" || new_status === "completed" || new_status === "cancelled")
    ) {
      const syncedStatus = new_status === "cancelled" ? "cancelled" : "completed";
      const syncableStatuses = new_status === "cancelled"
        ? ["confirmed", "paid", "in_progress", "request_sent", "discussion_started", "fare_agreed"]
        : ["confirmed", "paid", "in_progress"];
      const { error: syncErr } = await supabase
        .from("intercity_requests")
        .update({
          status: syncedStatus,
          updated_at: new Date().toISOString(),
          ...(new_status === "cancelled"
            ? { cancelled_by_actor: isDriver ? "rider" : (isPassenger ? "user" : null) }
            : {}),
        })
        .eq("parcel_id", order_id)
        .in("status", syncableStatuses);

      if (syncErr) {
        console.error(`[StatusUpdate] Failed to sync intercity_requests status to ${syncedStatus} for order ${order_id}:`, syncErr);
      } else {
        console.log(`[StatusUpdate] Synced intercity_requests status to ${syncedStatus} for order ${order_id}`);
      }
    }

    // =====================================================
    // order_status_history.changed_by is NOT NULL. Callers that don't supply it (cancel-order's
    // server-to-server proxy; the intercity payment_pending confirmation) previously sent `null`
    // here -- supabase-js does not throw on a bare .insert() without checking `error`, so the
    // write silently failed and the transition's audit row was permanently lost even though the
    // transition itself already succeeded (production audit-trail investigation, 2026-08-07:
    // 241/285 cancelled orders were missing this row). Falls back to the order's own passenger id,
    // then the literal 'system' sentinel already used elsewhere (expire_stale_searching_orders(),
    // expire_stale_active_orders()) for server-initiated writes -- never changes what happened to
    // the order, only guarantees it gets recorded. Error is logged, not thrown, so this can never
    // change the response the caller already gets.
    //
    // Skipped for completed/delivered -- complete_order_and_settle already inserted this exact row
    // (same order_id/previous_status/new_status/changed_by) as part of its own atomic transaction;
    // inserting again here would double the audit trail for every single completion.
    //
    // Phase M (E4b): same reasoning as the parcel_security_logs conversion above -- result never
    // read afterward, error already non-fatal, no DB trigger on order_status_history (Phase L
    // audit) -- reuses the same established EdgeRuntime.waitUntil pattern instead of awaiting.
    if (new_status !== "completed" && new_status !== "delivered") {
      const historyPromise = supabase.from("order_status_history").insert({
        order_id,
        previous_status: currentStatus,
        new_status,
        changed_by: changed_by || order.user_id || "system",
      }).then(({ error: historyError }) => {
        if (historyError) {
          console.error("[StatusUpdate] order_status_history insert failed (non-fatal):", historyError);
        }
      });

      if (typeof (globalThis as any).EdgeRuntime !== "undefined") {
        (globalThis as any).EdgeRuntime.waitUntil(historyPromise);
      }
    }

    // =====================================================
    // RESPONSE
    // =====================================================
    return new Response(
      JSON.stringify({
        success: true,
        order: updatedOrder,
      }),
      {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
        status: 200,
      }
    );
  } catch (error) {
    console.error("UPDATE STATUS ERROR =>", error);
    return httpErrorResponse(error, corsHeaders);
  }
});
