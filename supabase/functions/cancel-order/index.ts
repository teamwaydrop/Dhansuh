// supabase/functions/cancel-order/index.ts
//
// This function did not exist (C10). Six Flutter screens already call
// 'cancel-order' and, on a 404, silently fall back to an unvalidated raw
// `orders.update({order_status:'cancelled'})` with no transition check, no
// ownership check, and no assignment cleanup.
//
// Fix: implement 'cancel-order' as a thin, identity-preserving proxy to the
// already-hardened update-order-status function (new_status: 'cancelled').
// This is a deliberate design choice, not a shortcut — update-order-status
// already has JWT auth, ownership verification (caller must be the order's
// user OR its assigned rider), status-transition validation (rejects
// cancelling from an in-progress state like 'ongoing'/'picked_up'), rider
// assignment/log cleanup, and order_status_history audit logging. Duplicating
// that logic here would risk the two implementations drifting out of sync;
// proxying guarantees cancellation is always exactly as safe as any other
// status transition.

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { fetchWithTimeout, isTimeoutError } from "../_shared/http.ts";

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
    const token = req.headers.get("Authorization")?.replace("Bearer ", "");

    if (!token) {
      return new Response(
        JSON.stringify({ success: false, error: "Missing auth token" }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: 401 }
      );
    }

    const body = await req.json();
    const { order_id, cancel_reason } = body;

    if (!order_id) {
      return new Response(
        JSON.stringify({ success: false, error: "order_id required" }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: 400 }
      );
    }

    const functionUrl = `${Deno.env.get("SUPABASE_URL")}/functions/v1/update-order-status`;

    const proxiedResponse = await fetchWithTimeout(
      functionUrl,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          // Forward the caller's OWN token (not the service-role key), so
          // update-order-status's ownership check runs against the real,
          // authenticated caller — exactly as if they had called it directly.
          "Authorization": `Bearer ${token}`,
          "apikey": Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
        },
        body: JSON.stringify({
          order_id,
          new_status: "cancelled",
          cancel_reason: cancel_reason || "Cancelled by user",
        }),
      },
      20000,
    );

    const data = await proxiedResponse.json();

    return new Response(JSON.stringify(data), {
      status: proxiedResponse.status,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (error) {
    console.error("CANCEL ORDER ERROR:", error);
    if (isTimeoutError(error)) {
      return new Response(
        JSON.stringify({
          success: false,
          error: "Cancellation is taking longer than expected. Please check the order status and try again.",
        }),
        {
          status: 504,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        }
      );
    }
    return new Response(
      JSON.stringify({
        success: false,
        error: String(error),
      }),
      {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      }
    );
  }
});
