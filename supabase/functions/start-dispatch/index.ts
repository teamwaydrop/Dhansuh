import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.118.0";
import { fetchBufferedWithTimeout } from "../_shared/http.ts";
import { dispatchRpc, runDurableDispatch } from "./durable_dispatch.ts";

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
    // =====================================================
    // SUPABASE
    // =====================================================
    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
      {global: {fetch: (input: RequestInfo | URL, init?: RequestInit) => fetchBufferedWithTimeout(input, init ?? {}, 15000)}},
    );

    // =====================================================
    // BODY
    // =====================================================
    const body = await req.json();
    const order_id = body.order_id;

    if (!order_id) {
      return new Response(
        JSON.stringify({
          success: false,
          message: "order_id required",
        }),
        {
          status: 400,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        },
      );
    }

    // =====================================================
    // AUTH
    // Accepts either the service-role key (internal server-to-server
    // chaining/background triggers) or a valid end-user JWT (client-side
    // "boost"/retry search calls).
    // =====================================================
    const token = req.headers.get("Authorization")?.replace("Bearer ", "");

    if (!token) {
      return new Response(
        JSON.stringify({ success: false, message: "Missing auth token" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    const isServiceRoleCaller = token === Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

    if (!isServiceRoleCaller) {
      const { data: authData, error: authError } = await supabase.auth.getUser(token);
      if (authError || !authData.user) {
        return new Response(
          JSON.stringify({ success: false, message: "Unauthorized" }),
          { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } },
        );
      }

      // OWNERSHIP CHECK (P2 fix): a non-service-role caller (client-side "boost"/retry
      // search calls) could previously trigger a dispatch pass for ANY order_id, not just
      // their own -- low-impact (this only forces a harmless, idempotent rider-matching
      // pass, never returns/mutates sensitive data to the caller), but still a real
      // resource-abuse gap with no legitimate use. Only the order's own passenger or its
      // currently assigned rider may trigger it.
      const { data: ownedOrder } = await supabase
        .from("orders")
        .select("id, user_id, rider_id")
        .eq("id", order_id)
        .maybeSingle();

      if (!ownedOrder) {
        return new Response(
          JSON.stringify({ success: false, message: "Order not found" }),
          { status: 404, headers: { ...corsHeaders, "Content-Type": "application/json" } },
        );
      }

      const isPassenger = ownedOrder.user_id === authData.user.id;
      let isAssignedRider = false;
      if (!isPassenger && ownedOrder.rider_id) {
        const { data: ownRider } = await supabase
          .from("riders")
          .select("id")
          .eq("id", ownedOrder.rider_id)
          .eq("user_id", authData.user.id)
          .maybeSingle();
        isAssignedRider = ownRider != null;
      }

      if (!isPassenger && !isAssignedRider) {
        return new Response(
          JSON.stringify({ success: false, message: "Forbidden: not a participant on this order" }),
          { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } },
        );
      }
    }

    // Request coalescing and every offer/state/expiry write are transactional SQL.
    // No unsafe REST mutation or raw HTTP self-chain fallback remains.
    if (body.is_background !== true) {
      const result = await dispatchRpc(supabase, 'request_order_dispatch', {p_order_id: order_id});
      return Response.json({success: true, ...result}, {headers: corsHeaders});
    }
    const result = await runDurableDispatch(supabase, order_id);
    return Response.json(result, {headers: corsHeaders});
  } catch (_) {
    return Response.json({success: false, retryable: true, code: 'DISPATCH_STORAGE_UNAVAILABLE'},
      {status: 503, headers: corsHeaders});
  }
});
