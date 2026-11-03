import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { getProductionConfig, isFeatureEnabled } from "../_shared/production_config_cache.ts";

import { acceptOrderAtomically } from "./atomic_acceptance.ts";

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

    // Idempotent retries still pass server-side ownership/invariant checks.
    // A new acceptance retains the existing feature gates before the RPC.
    if (!(order.rider_id === rider_id && order.order_status === "accepted")) {
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
    }

    // The transaction runs inside this Edge Function. No RPC/schema migration is required.
    let acceptance;
    try {
      acceptance = await acceptOrderAtomically(order_id, rider_id, authData.user.id);
    } catch (error) {
      const code = (error as { code?: string }).code;
      const retryable = ["40001", "40P01", "55P03", "57014", "53300", "08006", "CONNECTION_CLOSED", "CONNECT_TIMEOUT", "ECONNRESET"].includes(code ?? "");
      console.error("accept-order transaction failed", { order_id, rider_id, code });
      return Response.json(
        { success: false, message: retryable ? "Acceptance is busy. Please retry." : "Unable to accept order", retryable },
        { status: retryable ? 503 : 500, headers: corsHeaders },
      );
    }
    const { http_status, ...responseBody } = acceptance;
    return Response.json(responseBody, { status: http_status, headers: corsHeaders });
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
