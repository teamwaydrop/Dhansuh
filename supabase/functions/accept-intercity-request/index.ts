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
  let request_id: any;
  let riderUserId: any;

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return Response.json(
        { success: false, code: "UNAUTHORIZED", message: "Missing authorization header." },
        { status: 401, headers: corsHeaders }
      );
    }

    const token = authHeader.replace("Bearer ", "");
    const { data: { user }, error: userError } = await supabase.auth.getUser(token);

    if (userError || !user) {
      return Response.json(
        { success: false, code: "UNAUTHORIZED", message: "Invalid or expired authorization token." },
        { status: 401, headers: corsHeaders }
      );
    }
    riderUserId = user.id;

    const body = await req.json();
    request_id = body.request_id;

    if (!request_id) {
      return Response.json(
        { success: false, code: "INVALID_REQUEST", message: "request_id is required." },
        { status: 400, headers: corsHeaders }
      );
    }

    // =====================================================
    // PHASE 4 PRODUCTION CONTROL: server-side feature-flag enforcement
    // =====================================================
    // Mirrors the same production_config gate now enforced in accept-order for local ride/parcel
    // acceptance -- accept-intercity-request is the sole edge function that finalizes a NEW
    // intercity match (public.accept_intercity_request transitions the linked order from
    // "searching" to "accepted" and the request from its negotiation status to "confirmed"; see
    // that function's own ORDER_ALREADY_ASSIGNED guard, which already returns cleanly without a
    // write for any order not still "searching"). It never touches an order already
    // accepted/ongoing/payment_pending/completed -- those only ever progress through
    // update-order-status, which stays intentionally ungated. Checked after auth/request_id
    // validation, before the RPC call that would perform that one NEW-match write. A
    // config-fetch failure fails open (isFeatureEnabled defaults to true), matching every other
    // production_config enforcement point in this codebase (create-order, create-payment,
    // send-push-notification, accept-order).
    const productionConfig = await getProductionConfig(supabase);
    if (!isFeatureEnabled(productionConfig, "intercity_enabled")) {
      return Response.json(
        { success: false, code: "FEATURE_DISABLED", message: "Intercity booking is temporarily unavailable. Please try again later." },
        { status: 503, headers: corsHeaders }
      );
    }

    // Call database transactional RPC
    const { data: rpcResult, error: rpcError } = await supabase.rpc("accept_intercity_request", {
      p_request_id: request_id,
      p_rider_user_id: user.id,
    });

    if (rpcError) {
      console.error("RPC execution error:", { request_id, riderUserId, error: rpcError });
      return Response.json(
        { success: false, code: "DATABASE_ERROR", message: rpcError.message },
        { status: 500, headers: corsHeaders }
      );
    }

    if (!rpcResult || rpcResult.success !== true) {
      const code = rpcResult?.code || "INVALID_REQUEST";
      const message = rpcResult?.message || "Accept request failed.";
      // WRONG_SERVICE_MODE (public.accept_intercity_request's service-mode
      // gate, added alongside 20260718000012) is a permissions rejection,
      // not a generic bad-request — surface it as 403.
      const status = code === "WRONG_SERVICE_MODE" ? 403 : 400;
      return Response.json(
        { success: false, code, message },
        { status, headers: corsHeaders }
      );
    }

    // Decoupled side effects: Trigger FCM notifications if any (already partly automated via DB triggers)
    try {
      // Trigger analytics or external side-effect notifications asynchronously here if needed
      // Failure of notifications or external logs should not rollback database changes.
    } catch (sideEffectErr) {
      console.error("Non-blocking side-effect error:", { request_id, riderUserId, error: sideEffectErr });
    }

    return Response.json(
      {
        success: true,
        code: rpcResult.code,
        order_id: rpcResult.order_id,
        request_id: rpcResult.request_id,
      },
      { status: 200, headers: corsHeaders }
    );

  } catch (error) {
    console.error("Edge function crash error:", { request_id, riderUserId, error });
    return Response.json(
      { success: false, code: "SERVER_ERROR", message: String(error) },
      { status: 500, headers: corsHeaders }
    );
  }
});
