import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { getProductionConfig, isFeatureEnabled } from "../_shared/production_config_cache.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", {
      headers: corsHeaders,
    });
  }

  // Hoisted out of the try block (Phase 5 F5: logging-only) so the catch-all error handler below
  // can include them for diagnosis -- no change to any value, validation, or control flow, only to
  // where these two references are declared.
  let order_id: any;
  let rider_id: any;

  try {
    const body = await req.json();
    order_id = body.order_id;
    rider_id = body.rider_id;

    if (!order_id || !rider_id) {
      return Response.json(
        {
          success: false,
          message: "order_id and rider_id required",
        },
        {
          status: 400,
          headers: corsHeaders,
        },
      );
    }

    // =====================================================
    // AUTH
    // =====================================================
    const token = req.headers.get("Authorization")?.replace("Bearer ", "");

    if (!token) {
      return Response.json(
        { success: false, message: "Missing auth token" },
        { status: 401, headers: corsHeaders },
      );
    }

    // Auth resolution and the order fetch are independent of each other's result (order_id was
    // already validated above, before either starts) -- run concurrently instead of serially.
    // Same two checks, same precedence (auth checked first below, exactly as before, so an
    // invalid token still always yields 401 regardless of order_id), same responses either way;
    // only removes one round trip's worth of serial wait per call on this rider-accept hot path.
    const [{ data: authData, error: authError }, { data: order, error: orderError }] =
      await Promise.all([
        supabase.auth.getUser(token),
        supabase.from("orders").select("*").eq("id", order_id).single(),
      ]);

    if (authError || !authData.user) {
      return Response.json(
        { success: false, message: "Unauthorized" },
        { status: 401, headers: corsHeaders },
      );
    }

    // =====================================================
    // FETCH ORDER
    // =====================================================
    if (orderError || !order) {
      return Response.json(
        {
          success: false,
          message: "Order not found",
        },
        {
          status: 404,
          headers: corsHeaders,
        },
      );
    }

    // =====================================================
    // IDEMPOTENCY
    // =====================================================
    if (order.rider_id === rider_id && order.order_status === "accepted") {
      return Response.json(
        {
          success: true,
          idempotent: true,
          message: "Order already accepted by this rider",
          order,
        },
        {
          status: 200,
          headers: corsHeaders,
        },
      );
    }

    // =====================================================
    // PHASE 3 PRODUCTION CONTROL: server-side feature-flag enforcement
    // =====================================================
    // Extends the same flags already enforced at order-creation time (create-order) to the
    // moment a rider finalizes acceptance of a NEW dispatch. This is deliberately checked here --
    // not in update-order-status -- because accepting is a "start something new" action exactly
    // analogous to creating an order (a bug found this vertical should also stop new matches from
    // being finalized), whereas update-order-status governs the rest of an ALREADY-accepted
    // order's lifecycle (rider_arrived/ongoing/completed/cancelled) and must keep working
    // regardless of these flags -- disabling ride_booking_enabled must never strand an
    // already-in-progress trip. Checked AFTER the idempotency check above (so a retried
    // acceptance of an order this same rider already holds always succeeds, exactly like before
    // this fix) and BEFORE the status-validation check below that gates a genuinely NEW
    // acceptance. A config-fetch failure fails open (isFeatureEnabled defaults to true), matching
    // every other Phase 1/3 enforcement point.
    const productionConfig = await getProductionConfig(supabase);
    if (order.order_type === "ride") {
      if (
        !isFeatureEnabled(productionConfig, "local_rides_enabled") ||
        !isFeatureEnabled(productionConfig, "ride_booking_enabled")
      ) {
        return Response.json(
          { success: false, message: "Ride booking is temporarily unavailable. Please try again later." },
          { status: 503, headers: corsHeaders },
        );
      }
    } else if (order.order_type === "local_parcel") {
      if (!isFeatureEnabled(productionConfig, "parcel_enabled")) {
        return Response.json(
          { success: false, message: "Parcel booking is temporarily unavailable. Please try again later." },
          { status: 503, headers: corsHeaders },
        );
      }
    } else if (order.order_type === "intercity_ride" || order.order_type === "intercity_parcel") {
      if (!isFeatureEnabled(productionConfig, "intercity_enabled")) {
        return Response.json(
          { success: false, message: "Intercity booking is temporarily unavailable. Please try again later." },
          { status: 503, headers: corsHeaders },
        );
      }
    }

    // =====================================================
    // ORDER STATUS VALIDATION
    // =====================================================
    if (order.order_status !== "searching") {
      return Response.json(
        {
          success: false,
          message: "Order no longer available",
          current_status: order.order_status,
        },
        {
          status: 400,
          headers: corsHeaders,
        },
      );
    }

    // =====================================================
    // FETCH RIDER
    // =====================================================
    const { data: rider, error: riderError } = await supabase
      .from("riders")
      .select("id, user_id, service_mode, account_status, subscription_active, subscription_expires_at")
      .eq("id", rider_id)
      .single();

    if (riderError || !rider) {
      return Response.json(
        {
          success: false,
          message: "Rider not found",
        },
        {
          status: 404,
          headers: corsHeaders,
        },
      );
    }

    // =====================================================
    // OWNERSHIP CHECK
    // =====================================================
    if (rider.user_id !== authData.user.id) {
      return Response.json(
        {
          success: false,
          message: "Forbidden: rider_id does not belong to authenticated user",
        },
        {
          status: 403,
          headers: corsHeaders,
        },
      );
    }

    // =====================================================
    // SERVICE MODE VALIDATION
    // =====================================================
    // Mirrors the DB-layer canonical classification (public.get_required_service_mode)
    // so this never disagrees with the orders.rider_id guard trigger that
    // will ultimately accept/reject this same write.
    const requiresIntercityMode =
      order.order_type === "intercity_ride" ||
      order.order_type === "intercity_parcel" ||
      (order.order_type === "ride" && (order.distance_meters ?? 0) > 20000);
    const requiredMode = requiresIntercityMode ? "intercity" : "local";

    if (rider.service_mode !== requiredMode) {
      return Response.json(
        {
          success: false,
          code: "WRONG_SERVICE_MODE",
          message: rider.service_mode === null
            ? "Choose a Service Mode in your Profile before accepting orders."
            : `Switch to ${requiredMode === "local" ? "Local Rides" : "Intercity Traveller"} mode to accept this order.`,
        },
        {
          status: 403,
          headers: corsHeaders,
        },
      );
    }

    // =====================================================
    // RIDER STATUS VALIDATION
    // =====================================================
    if (rider.user_id === order.user_id) {
      return Response.json(
        {
          success: false,
          message: "You cannot accept your own order",
        },
        {
          status: 400,
          headers: corsHeaders,
        },
      );
    }

    if (rider.account_status !== "online") {
      return Response.json(
        {
          success: false,
          message: "Rider not online",
        },
        {
          status: 400,
          headers: corsHeaders,
        },
      );
    }

    // =====================================================
    // GOVERNMENT TAX DUE THRESHOLD / COD LIMIT / ACTIVE ORDER CHECK
    // These three RPCs are independent read-only eligibility checks -- none of their inputs
    // depend on another's result (all take only rider_id, already validated above) -- so they run
    // concurrently instead of serially. Each result is then evaluated below in the exact same
    // order as before, so precedence (which blocking reason is reported first when more than one
    // applies) and every response/message/error-handling path are unchanged; this only removes two
    // round trips' worth of serial wait per call on this rider-accept hot path.
    //
    // GOVERNMENT TAX DUE THRESHOLD
    // A rider at/above the configured threshold must not receive/accept NEW work through any
    // path -- this mirrors the same server-side gate already applied in find_nearby_riders(),
    // assign_nearby_searching_orders_to_rider(), and accept_intercity_request() (see migration
    // 20260726000004). It never affects an order this rider already has accepted/in-progress --
    // only a NEW acceptance attempt is blocked here.
    //
    // COD (CASH ON DELIVERY) LIMIT
    // Server-side mirror of the tax-due gate above, and of find_nearby_riders() /
    // assign_nearby_searching_orders_core() (see migration 20260808000002) -- previously
    // cod_pending_amount >= cod_limit was only ever checked client-side (rider_orders_screen.dart's
    // acceptOrder()), which a direct call to this function bypassed entirely.
    //
    // ACTIVE ORDER CHECK
    // Calls public.rider_is_on_active_trip() directly (20260720000004) instead of re-implementing
    // it inline -- this comment used to say "Mirrors ..." while actually maintaining a separate,
    // drifted copy that never included payment_pending (found during the Issue 1 payment_pending
    // busy-state investigation; fixed alongside find_nearby_riders,
    // trigger_assign_nearby_orders_on_rider_freed, and prevent_local_ride_assignment_to_busy_rider
    // in 20260825000000_payment_pending_busy_state_fix.sql). Same semantics as before for every
    // other status: a local job is busy from the moment it's accepted; an intercity/long-distance
    // job accepted-but-"Waiting for Travel Day" (trip_started_at still null) does not block
    // accepting a different local job in the meantime.
    // =====================================================
    const [
      { data: isBlockedByTaxDue, error: taxBlockError },
      { data: isBlockedByCodLimit, error: codBlockError },
      { data: hasActiveTrip, error: activeOrdersError },
    ] = await Promise.all([
      supabase.rpc("is_rider_blocked_by_tax_due", { p_rider_id: rider_id }),
      supabase.rpc("is_rider_blocked_by_cod_limit", { p_rider_id: rider_id }),
      supabase.rpc("rider_is_on_active_trip", { p_rider_id: rider_id }),
    ]);

    if (taxBlockError) {
      console.error("accept-order => TAX DUE THRESHOLD CHECK ERROR:", { order_id, rider_id, error: taxBlockError });
    } else if (isBlockedByTaxDue === true) {
      return Response.json(
        {
          success: false,
          code: "TAX_DUE_THRESHOLD_BLOCKED",
          message: "New orders are paused because your Government Tax Due has reached the limit. Pay the due amount to continue receiving orders.",
        },
        {
          status: 403,
          headers: corsHeaders,
        },
      );
    }

    if (codBlockError) {
      console.error("accept-order => COD LIMIT CHECK ERROR:", { order_id, rider_id, error: codBlockError });
    } else if (isBlockedByCodLimit === true) {
      return Response.json(
        {
          success: false,
          code: "COD_LIMIT_EXCEEDED",
          message: "You've reached your cash collection limit. Please settle your pending cash amount to resume receiving orders.",
        },
        {
          status: 403,
          headers: corsHeaders,
        },
      );
    }

    if (activeOrdersError) {
      return Response.json(
        {
          success: false,
          message: "Unable to validate active rides",
        },
        {
          status: 500,
          headers: corsHeaders,
        },
      );
    }

    if (hasActiveTrip) {
      return Response.json(
        {
          success: false,
          message: "Rider already has an active order",
        },
        {
          status: 400,
          headers: corsHeaders,
        },
      );
    }

    // =====================================================
    // FETCH ASSIGNMENT
    // =====================================================
    const { data: assignment, error: assignmentError } = await supabase
      .from("rider_assignments")
      .select("id, assignment_status")
      .eq("order_id", order_id)
      .eq("rider_id", rider_id)
      .order("created_at", { ascending: false })
      .limit(1)
      .maybeSingle();

    if (assignmentError) {
      return Response.json(
        {
          success: false,
          message: "Unable to validate assignment",
        },
        {
          status: 500,
          headers: corsHeaders,
        },
      );
    }

    // =====================================================
    // ASSIGNMENT VALIDATION & STATUS CHECKS
    // =====================================================
    const now = new Date();

    if (assignment) {
      // =====================================================
      // ASSIGNMENT STATUS VALIDATION
      // =====================================================
      const allowedStatuses = ["sent", "accepted_by_user", "rejected", "expired"];
      if (!allowedStatuses.includes(assignment.assignment_status)) {
        return Response.json(
          {
            success: false,
            message: "Assignment already handled",
            assignment_status: assignment.assignment_status,
          },
          {
            status: 400,
            headers: corsHeaders,
          },
        );
      }
    }

    // =====================================================
    // ACCEPT ASSIGNMENT / UPSERT
    // =====================================================
    let finalAssignment = assignment;

    if (!assignment) {
      const nowStr = now.toISOString();
      const { data: newAssignment, error: insertError } = await supabase
        .from("rider_assignments")
        .insert({
          order_id: order_id,
          rider_id: rider_id,
          assignment_round: 1,
          assignment_status: "accepted",
          sent_at: nowStr,
          responded_at: nowStr,
          accepted_at: nowStr,
          updated_at: nowStr,
          response_type: "accepted",
          last_response_at: nowStr,
          estimated_earnings: order.rider_earning,
        })
        .select()
        .single();

      if (insertError || !newAssignment) {
        return Response.json(
          {
            success: false,
            message: "Unable to create assignment for acceptance",
            error: insertError,
          },
          {
            status: 500,
            headers: corsHeaders,
          },
        );
      }
      finalAssignment = newAssignment;
    } else {
      const { error: assignmentUpdateError } = await supabase
        .from("rider_assignments")
        .update({
          assignment_status: "accepted",
          responded_at: now.toISOString(),
          updated_at: now.toISOString(),
          response_type: "accepted",
          last_response_at: now.toISOString(),
        })
        .eq("id", assignment.id);

      if (assignmentUpdateError) {
        return Response.json(
          {
            success: false,
            message: "Unable to update assignment",
            error: assignmentUpdateError,
          },
          {
            status: 500,
            headers: corsHeaders,
          },
        );
      }
      finalAssignment = {
        ...assignment,
        assignment_status: "accepted",
        responded_at: now.toISOString(),
        updated_at: now.toISOString(),
        response_type: "accepted",
        last_response_at: now.toISOString(),
      };
    }

    // Phase I (WayDrop accept-order latency pass): these two writes are independent -- different
    // tables, neither reads the other's result, and nothing downstream depends on either before the
    // order UPDATE below -- so they run concurrently instead of serially. Same two calls, same
    // filters, same fire-and-forget error handling (neither result was checked before, and still
    // isn't now -- a failure in either must not block acceptance, exactly as before), just removes
    // one round trip's worth of serial wait per call on this rider-accept hot path.
    await Promise.all([
      supabase
        .from("rider_assignments")
        .update({
          assignment_status: "expired",
          updated_at: now.toISOString(),
          response_type: "ignored",
          last_response_at: now.toISOString(),
        })
        .eq("order_id", order_id)
        .neq("rider_id", rider_id)
        .eq("assignment_status", "sent"),
      supabase
        .from("order_assignment_logs")
        .update({
          assignment_status: "expired",
          responded_at: now.toISOString(),
        })
        .eq("order_id", order_id)
        .neq("rider_id", rider_id)
        .eq("assignment_status", "sent"),
    ]);

    // =====================================================
    // UPDATE ORDER STATUS
    // Delegated to calculate_fare_breakdown -- the single canonical place (in the database) where
    // "given a new total fare + this order's own rates, compute the full breakdown" is
    // implemented. boost-order-fare and confirm_intercity_booking() call the exact same function,
    // so there is exactly one implementation of this formula.
    //
    // BUG FIX: this previously read `finalAssignment.estimated_earnings` first. That column is the
    // DRIVER's own post-commission take-home snapshot (every writer sets it from order.rider_earning
    // -- see start-dispatch's assignment inserts and the dispatch-matching migrations), used only for
    // "did the fare change since this driver last saw it" re-notification comparisons. It is never
    // the passenger's payable total. Feeding it into calculate_fare_breakdown as p_new_total_fare
    // silently overwrote current_fare/final_fare (and therefore payableFare, and the amount sent to
    // Google Pay) from the GST-inclusive total down to the driver's earnings figure the instant a
    // driver accepted -- e.g. a real ₹21 total (₹20 subtotal + 5% GST) collapsing to ₹18 (₹20
    // subtotal - 10% commission) on every acceptance, since no negotiation ever happens at plain
    // accept-order (only boost-order-fare and confirm_intercity_booking are allowed to change the
    // total). The order's own current_fare is the only correct input here; recomputing the
    // breakdown against it still lets commission_amount/rider_earning update correctly for the
    // accepting rider's actual subscription status below.
    const finalFare = order.current_fare;
    const gstPct = order.gst_percentage ?? 5.0;
    const commPct = order.commission_percentage ?? 10.0;

    // Check if rider has active Waydrop MAX subscription
    const hasActiveSubscription =
      rider.subscription_active === true &&
      rider.subscription_expires_at &&
      new Date(rider.subscription_expires_at) > new Date();
    const effectiveCommPct = hasActiveSubscription ? 0 : commPct;

    // Preserve any promo discount already locked in (final_fare is only ever current_fare minus a
    // promo discount, otherwise equal to it) -- this negotiated/possibly-boosted acceptance fare
    // must not silently drop it.
    const existingCurrentFare = Number(order.current_fare || 0);
    const existingFinalFare = order.final_fare !== null && order.final_fare !== undefined
      ? Number(order.final_fare)
      : existingCurrentFare;
    const promoDiscount = Math.max(0, existingCurrentFare - existingFinalFare);

    const { data: breakdown, error: breakdownError } = await supabase.rpc("calculate_fare_breakdown", {
      p_new_total_fare: finalFare,
      p_actual_fare: order.actual_fare,
      p_gst_percentage: gstPct,
      p_commission_percentage: effectiveCommPct,
      p_promo_discount: promoDiscount,
    });

    if (breakdownError || !breakdown) {
      return Response.json(
        { success: false, message: breakdownError?.message || "Failed to calculate fare breakdown" },
        { status: 500, headers: corsHeaders },
      );
    }

    const { data: updatedOrder, error: orderUpdateError } = await supabase
      .from("orders")
      .update({
        order_status: "accepted",
        rider_id: rider_id,
        accepted_at: now.toISOString(),
        updated_at: now.toISOString(),
        current_fare: breakdown.current_fare,
        final_fare: breakdown.final_fare,
        commission_amount: breakdown.commission_amount,
        gst_amount: breakdown.gst_amount,
        rider_earning: breakdown.rider_earning,
        subscription_commission_waived: hasActiveSubscription,
      })
      .eq("id", order_id)
      .eq("order_status", "searching") // optimistic lock: only accept if still searching
      .select()
      .maybeSingle();

    if (orderUpdateError) {
      return Response.json(
        {
          success: false,
          message: "Unable to update order status",
          error: orderUpdateError,
        },
        {
          status: 500,
          headers: corsHeaders,
        },
      );
    }

    if (!updatedOrder) {
      // The optimistic lock matched zero rows: another rider already accepted
      // this order (or it changed state) between our read and this write.
      const { data: latestOrder } = await supabase
        .from("orders")
        .select("order_status")
        .eq("id", order_id)
        .maybeSingle();

      const alreadyTaken = latestOrder?.order_status === "accepted";

      return Response.json(
        {
          success: false,
          message: alreadyTaken
            ? "Order already accepted by another rider"
            : "Order no longer available",
          current_status: latestOrder?.order_status ?? null,
        },
        {
          status: 409,
          headers: corsHeaders,
        },
      );
    }

    // =====================================================
    // UPDATE OR INSERT ASSIGNMENT LOG
    // =====================================================
    const { data: existingLog } = await supabase
      .from("order_assignment_logs")
      .select("id")
      .eq("order_id", order_id)
      .eq("rider_id", rider_id)
      .limit(1)
      .maybeSingle();

    if (existingLog) {
      await supabase
        .from("order_assignment_logs")
        .update({
          assignment_status: "accepted",
          responded_at: now.toISOString(),
        })
        .eq("order_id", order_id)
        .eq("rider_id", rider_id);
    } else {
      await supabase
        .from("order_assignment_logs")
        .insert({
          order_id: order_id,
          rider_id: rider_id,
          assignment_round: 1,
          assignment_status: "accepted",
          sent_at: now.toISOString(),
          responded_at: now.toISOString(),
        });
    }

    // =====================================================
    // RESPONSE
    // =====================================================
    return Response.json(
      {
        success: true,
        order: updatedOrder,
        assignment: finalAssignment,
      },
      {
        status: 200,
        headers: corsHeaders,
      },
    );
  } catch (error) {
    console.error("ACCEPT ORDER ERROR:", { order_id, rider_id, error });
    // A malformed request body (req.json() throwing) is a client mistake, not a server failure --
    // was previously indistinguishable from a genuine crash once it fell into this catch-all 500.
    if (error instanceof SyntaxError) {
      return Response.json(
        { success: false, message: "Malformed request body" },
        { status: 400, headers: corsHeaders },
      );
    }
    return Response.json(
      {
        success: false,
        message: "Internal server error",
      },
      {
        status: 500,
        headers: corsHeaders,
      },
    );
  }
});
