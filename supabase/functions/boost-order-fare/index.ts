import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

// =====================================================================
// BOOST ORDER FARE
// The passenger's ONLY input is `additional_amount` -- how many more rupees they're offering on
// top of the order's current fare, a plain user preference (identical trust level to
// `max_boost_amount` already accepted at booking time in calculate-order-pricing). Every actual
// financial figure -- the GST split, the commission, the driver's earning, the boost breakdown,
// and the preserved promo discount -- is computed here, server-side, from the order's own stored
// gst_percentage/commission_percentage/actual_fare. The client never computes or supplies any of
// them; it only ever displays what this function returns.
// =====================================================================
serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    const body = await req.json();
    const { order_id, additional_amount } = body;

    if (!order_id) {
      throw new Error("Order ID required");
    }

    const boostRequest = Number(additional_amount);
    if (!Number.isFinite(boostRequest) || boostRequest <= 0) {
      throw new Error("additional_amount must be a positive, finite number");
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

    const { data: authData, error: authError } = await supabase.auth.getUser(token);
    if (authError || !authData.user) {
      return new Response(
        JSON.stringify({ success: false, error: "Unauthorized" }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: 401 }
      );
    }

    // =====================================================
    // FETCH ORDER
    // =====================================================
    const { data: order, error: orderError } = await supabase
      .from("orders")
      .select("*")
      .eq("id", order_id)
      .single();

    if (orderError || !order) {
      throw new Error("Order not found");
    }

    // Only the order's own passenger may boost it.
    if (order.user_id !== authData.user.id) {
      return new Response(
        JSON.stringify({ success: false, error: "Forbidden: not the owner of this order" }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: 403 }
      );
    }

    // A fare can only be boosted while still searching for a rider.
    if (order.order_status !== "searching") {
      throw new Error(`Cannot boost fare: order is currently "${order.order_status}", not searching`);
    }

    // =====================================================
    // SERVER-SIDE FINANCIAL CALCULATION
    // Delegated entirely to calculate_fare_breakdown -- the single canonical place (in the
    // database) where "given a new total fare + this order's own rates, compute the full
    // breakdown" is implemented. confirm_intercity_booking() (the intercity fare-negotiation path)
    // calls the exact same function, so there is exactly one implementation of this formula.
    // =====================================================
    const actualFare = Number(order.actual_fare || 0);
    const existingCurrentFare = Number(order.current_fare || 0);
    // final_fare is only ever set once a promo discount was applied at booking (current_fare minus
    // the discount) -- preserve that same discount amount across the boost instead of losing it.
    const existingFinalFare = order.final_fare !== null && order.final_fare !== undefined
      ? Number(order.final_fare)
      : existingCurrentFare;
    const promoDiscount = Math.max(0, existingCurrentFare - existingFinalFare);

    const gstPct = Number(order.gst_percentage || 5.0);
    const commPct = Number(order.commission_percentage || 0);

    // Sanity ceiling -- mirrors the effective (unenforced-elsewhere) cap the client UI already
    // used; prevents an absurd/overflowing value regardless of client input.
    const MAX_FARE_CEILING = 99999;

    const newCurrentFare = Number((existingCurrentFare + boostRequest).toFixed(2));
    if (newCurrentFare > MAX_FARE_CEILING) {
      throw new Error(`Boosted fare cannot exceed ₹${MAX_FARE_CEILING}`);
    }

    const { data: breakdown, error: breakdownError } = await supabase.rpc("calculate_fare_breakdown", {
      p_new_total_fare: newCurrentFare,
      p_actual_fare: actualFare,
      p_gst_percentage: gstPct,
      p_commission_percentage: commPct,
      p_promo_discount: promoDiscount,
    });

    if (breakdownError || !breakdown) {
      throw new Error(breakdownError?.message || "Failed to calculate fare breakdown");
    }

    // =====================================================
    // UPDATE ORDER
    // Optimistic lock: only applies if the order is still "searching" at write time (a rider may
    // have accepted in the moment between the read above and this write).
    // =====================================================
    const { data: updatedOrder, error: updateError } = await supabase
      .from("orders")
      .update({
        current_fare: breakdown.current_fare,
        final_fare: breakdown.final_fare,
        boost_percentage: breakdown.boost_percentage,
        boost_amount: breakdown.boost_amount,
        boost_rider_earning: breakdown.boost_rider_earning,
        boost_company_earning: breakdown.boost_company_earning,
        commission_amount: breakdown.commission_amount,
        gst_amount: breakdown.gst_amount,
        rider_earning: breakdown.rider_earning,
        // Restart the search window/timeout clock, exactly as the previous client-driven retry did.
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
      })
      .eq("id", order_id)
      .eq("order_status", "searching")
      .select()
      .single();

    if (updateError) {
      if (updateError.code === "PGRST116") {
        throw new Error("Order is no longer searching (a rider may have just accepted). Please retry.");
      }
      throw updateError;
    }

    await supabase.from("order_status_history").insert({
      order_id,
      previous_status: "searching",
      new_status: "searching",
      changed_by: authData.user.id,
    });

    // =====================================================
    // RE-TRIGGER DISPATCH ASYNCHRONOUSLY WITH THE NEW, HIGHER FARE
    // =====================================================
    const functionUrl = `${Deno.env.get("SUPABASE_URL")}/functions/v1/start-dispatch`;
    const dispatchPromise = fetch(functionUrl, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Authorization": `Bearer ${Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")}`,
        "apikey": Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
      },
      body: JSON.stringify({ order_id, is_background: true }),
    }).then((res) => {
      console.log("[BoostOrderFare] start-dispatch trigger status:", res.status);
    }).catch((err) => {
      console.error("[BoostOrderFare] start-dispatch trigger error:", err);
    });

    if (typeof (globalThis as any).EdgeRuntime !== "undefined") {
      (globalThis as any).EdgeRuntime.waitUntil(dispatchPromise);
    }

    return new Response(
      JSON.stringify({ success: true, order: updatedOrder }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: 200 }
    );
  } catch (error) {
    console.error("BOOST ORDER FARE ERROR =>", error);
    return new Response(
      JSON.stringify({ success: false, error: error.message || "Unknown error" }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: 500 }
    );
  }
});
