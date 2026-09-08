import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

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

  try {
    const body = await req.json();
    const { order_id, rider_id, rejection_reason } = body;

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

    const { data: authData, error: authError } = await supabase.auth.getUser(token);

    if (authError || !authData.user) {
      return Response.json(
        { success: false, message: "Unauthorized" },
        { status: 401, headers: corsHeaders },
      );
    }

    // =====================================================
    // OWNERSHIP CHECK
    // =====================================================
    const { data: rejectingRider, error: rejectingRiderError } = await supabase
      .from("riders")
      .select("user_id")
      .eq("id", rider_id)
      .single();

    if (rejectingRiderError || !rejectingRider) {
      return Response.json(
        { success: false, message: "Rider not found" },
        { status: 404, headers: corsHeaders },
      );
    }

    if (rejectingRider.user_id !== authData.user.id) {
      return Response.json(
        { success: false, message: "Forbidden: rider_id does not belong to authenticated user" },
        { status: 403, headers: corsHeaders },
      );
    }

    // =====================================================
    // FETCH ORDER
    // =====================================================
    // P8 FIX #5 (reject-order query optimization): the only field this function ever reads off
    // `order` is order_status (the status-gate check below and its echo in the 400 response) --
    // the object is never returned whole, spread, or forwarded to any helper/RPC (verified by
    // grepping every `order.` access in this file), so unlike accept-order's idempotent-response
    // path (P8 Fix #2), there is no consumer contract requiring the full row here.
    const { data: order, error: orderError } = await supabase
      .from("orders")
      .select("order_status")
      .eq("id", order_id)
      .single();

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
    // VALIDATE ORDER STATE
    // =====================================================
    if (order.order_status !== "searching") {
      return Response.json(
        {
          success: false,
          message: "Order no longer available for rejection",
          current_status: order.order_status,
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
      .select("*")
      .eq("order_id", order_id)
      .eq("rider_id", rider_id)
      .order("created_at", { ascending: false })
      .limit(1)
      .maybeSingle();

    if (assignmentError) {
      console.error("[Reject] Error fetching assignment:", assignmentError);
      return Response.json(
        {
          success: false,
          message: "Unable to fetch assignment",
        },
        {
          status: 500,
          headers: corsHeaders,
        },
      );
    }

    if (!assignment) {
      console.log(`[Reject] Assignment not found for order ${order_id} and rider ${rider_id}. Creating new rejected assignment.`);
      const nowStr = new Date().toISOString();
      
      const { error: insertError } = await supabase
        .from("rider_assignments")
        .insert({
          order_id: order_id,
          rider_id: rider_id,
          assignment_round: 1,
          assignment_status: "rejected",
          sent_at: nowStr,
          responded_at: nowStr,
          updated_at: nowStr,
          response_type: "rejected",
          last_response_at: nowStr,
          hidden_until: new Date(Date.now() + 4 * 60 * 1000).toISOString(),
        });

      if (insertError) {
        console.error("[Reject] Error inserting new rejected assignment:", insertError);
        return Response.json(
          {
            success: false,
            message: "Unable to create rejection assignment",
          },
          {
            status: 500,
            headers: corsHeaders,
          },
        );
      }

      // Also create log entry
      await supabase
        .from("order_assignment_logs")
        .insert({
          order_id: order_id,
          rider_id: rider_id,
          assignment_round: 1,
          assignment_status: "rejected",
          sent_at: nowStr,
          responded_at: nowStr,
          rejection_reason: rejection_reason || "Declined by rider from available list",
        });

      return Response.json(
        {
          success: true,
          rejected: true,
          created: true,
        },
        {
          status: 200,
          headers: corsHeaders,
        },
      );
    }

    // =====================================================
    // IDEMPOTENCY & RE-REJECTION
    // =====================================================
    if (assignment.assignment_status === "rejected") {
      console.log(`[Reject] Assignment already rejected. Updating timestamps to reset cooldown.`);
      const nowStr = new Date().toISOString();
      const { error: updateAssignmentError } = await supabase
        .from("rider_assignments")
        .update({
          responded_at: nowStr,
          updated_at: nowStr,
          response_type: "rejected",
          last_response_at: nowStr,
          hidden_until: new Date(Date.now() + 4 * 60 * 1000).toISOString(),
        })
        .eq("id", assignment.id);

      if (updateAssignmentError) {
        console.error("[Reject] Error updating already-rejected assignment:", updateAssignmentError);
        return Response.json(
          {
            success: false,
            message: "Unable to update rejection",
          },
          {
            status: 500,
            headers: corsHeaders,
          },
        );
      }

      await supabase
        .from("order_assignment_logs")
        .insert({
          order_id: order_id,
          rider_id: rider_id,
          assignment_round: assignment.assignment_round || 1,
          assignment_status: "rejected",
          sent_at: assignment.sent_at || nowStr,
          responded_at: nowStr,
          rejection_reason: rejection_reason || "Declined by rider again",
        });

      return Response.json(
        {
          success: true,
          rejected: true,
          updated: true,
        },
        {
          status: 200,
          headers: corsHeaders,
        },
      );
    }

    // =====================================================
    // VALIDATE ASSIGNMENT STATE
    // =====================================================
    if (assignment.assignment_status !== "sent" && assignment.assignment_status !== "expired") {
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

    // =====================================================
    // UPDATE ASSIGNMENT
    // =====================================================
    const now = new Date().toISOString();

    const { error: updateAssignmentError } = await supabase
      .from("rider_assignments")
      .update({
        assignment_status: "rejected",
        responded_at: now,
        updated_at: now,
        response_type: "rejected",
        last_response_at: now,
        hidden_until: new Date(Date.now() + 4 * 60 * 1000).toISOString(),
      })
      .eq("id", assignment.id);

    if (updateAssignmentError) {
      console.error("[Reject] Error rejecting assignment:", updateAssignmentError);
      return Response.json(
        {
          success: false,
          message: "Unable to reject assignment",
        },
        {
          status: 500,
          headers: corsHeaders,
        },
      );
    }

    // =====================================================
    // UPDATE ASSIGNMENT LOGS
    // =====================================================
    await supabase
      .from("order_assignment_logs")
      .update({
        assignment_status: "rejected",
        responded_at: now,
        rejection_reason: rejection_reason || "Rejected by rider",
      })
      .eq("order_id", order_id)
      .eq("rider_id", rider_id)
      .eq("assignment_status", "sent");

    // =====================================================
    // CHECK REMAINING ACTIVE ASSIGNMENTS
    // =====================================================
    const { data: remainingAssignments, error: remainingError } = await supabase
      .from("rider_assignments")
      .select("id")
      .eq("order_id", order_id)
      .eq("assignment_status", "sent");

    if (remainingError) {
      return Response.json(
        {
          success: false,
          message: "Unable to validate remaining assignments",
        },
        {
          status: 500,
          headers: corsHeaders,
        },
      );
    }

    // =====================================================
    // REDISPATCH IF NO ACTIVE ASSIGNMENTS
    // =====================================================
    // Since start-dispatch manages the rounds loop internally and polls for status changes,
    // we no longer trigger overlapping/duplicate dispatch instances from reject-order.
    const redispatched = false;
    const dispatchResponse = null;

    // =====================================================
    // RESPONSE
    // =====================================================
    return Response.json(
      {
        success: true,
        rejected: true,
        redispatched: redispatched,
        dispatch: dispatchResponse,
      },
      {
        status: 200,
        headers: corsHeaders,
      },
    );
  } catch (error) {
    console.error("REJECT ORDER ERROR:", error);
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
