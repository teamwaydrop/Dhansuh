// supabase/functions/bypass-verification-photo/index.ts
//
// Root-cause fix: rider_active_order_screen.dart's _bypassVerification() used to insert into
// order_verifications AND update orders.pickup_verification_completed directly from the client
// using the rider's own JWT, subject to their RLS policies. Any drift between the order's live
// rider_id and what RLS can resolve for the caller (or any future RLS tightening) surfaces as a
// raw "permission denied" error with no recovery path for the rider mid-delivery. This function
// mirrors process-verification-photo's own auth pattern (JWT auth.getUser + ownership check)
// but performs the actual writes with the service role, exactly like the primary (non-bypass)
// photo path already does -- so bypass can never fail on RLS.
//
// PROVENANCE NOTE (Phase 5 Gap E, added when this file was committed to the repo): this source
// was downloaded read-only from the live production deployment (v8) during a Phase 4/5 audit --
// it had been deployed directly to production without ever being committed here. The content
// below is byte-identical to what is currently live; committing it is a version-control/provenance
// fix only, not a behavior change. It has NOT been redeployed as part of that commit -- redeploying
// it (even though it would be a no-op in behavior) is a separate, not-yet-approved decision.

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", {
      headers: corsHeaders,
    });
  }

  try {
    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    const body = await req.json();
    const {
      order_id,
      verification_type,
      reason,
      latitude,
      longitude,
      device_id,
    } = body;

    if (!order_id) throw new Error("Order ID required");
    if (!verification_type || !["pickup", "dropoff"].includes(verification_type)) {
      throw new Error("verification_type must be 'pickup' or 'dropoff'");
    }
    if (!reason || String(reason).trim().length < 5) {
      throw new Error("A bypass reason of at least 5 characters is required");
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
    // OWNERSHIP CHECK -- caller must be the rider currently assigned to this order
    // =====================================================
    const { data: order, error: orderError } = await supabase
      .from("orders")
      .select("id, rider_id")
      .eq("id", order_id)
      .single();

    if (orderError || !order) {
      return new Response(
        JSON.stringify({ success: false, error: "Order not found" }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: 404 }
      );
    }

    if (!order.rider_id) {
      return new Response(
        JSON.stringify({ success: false, error: "Order has no assigned rider" }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: 403 }
      );
    }

    const { data: assignedRider, error: riderError } = await supabase
      .from("riders")
      .select("user_id")
      .eq("id", order.rider_id)
      .single();

    if (riderError || !assignedRider) {
      return new Response(
        JSON.stringify({ success: false, error: "Assigned rider not found" }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: 404 }
      );
    }

    if (assignedRider.user_id !== authData.user.id) {
      return new Response(
        JSON.stringify({ success: false, error: "Forbidden: you are not the rider assigned to this order" }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: 403 }
      );
    }

    // =====================================================
    // WRITE (service role -- same trust level as process-verification-photo)
    // =====================================================
    const { error: verificationError } = await supabase
      .from("order_verifications")
      .insert({
        order_id,
        verification_type,
        verification_status: "bypassed",
        photo_url: null,
        latitude: latitude || null,
        longitude: longitude || null,
        metadata: {
          bypass_reason: reason,
          device_id: device_id || null,
          bypassed_at: new Date().toISOString(),
        },
        created_by: authData.user.id,
      });

    if (verificationError) {
      console.error("[BypassVerification] Error inserting verification record:", verificationError);
      throw verificationError;
    }

    if (verification_type === "pickup") {
      const { error: updateError } = await supabase
        .from("orders")
        .update({
          pickup_verification_completed: true,
          pickup_verification_completed_at: new Date().toISOString(),
        })
        .eq("id", order_id);

      if (updateError) {
        console.error("[BypassVerification] Error updating order:", updateError);
        throw updateError;
      }
    }

    return new Response(
      JSON.stringify({ success: true }),
      {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
        status: 200,
      }
    );
  } catch (error) {
    console.error("[BypassVerification] Error processing bypass:", error);
    return new Response(
      JSON.stringify({
        success: false,
        error: error.message || "Unknown error",
      }),
      {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
        status: 500,
      }
    );
  }
});
