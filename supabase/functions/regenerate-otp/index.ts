import { serve } from "https://deno.land/std@0.224.0/http/server.ts";

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS")!)["default"],
);

function generateOtp(
  length = 4,
) {

  let otp = "";

  for (
    let i = 0;
    i < length;
    i++
  ) {

    otp += Math.floor(
      Math.random() * 10,
    ).toString();
  }

  return otp;
}

serve(async (req) => {

  if (req.method === "OPTIONS") {

    return new Response(
      "ok",
      {
        headers: corsHeaders,
      },
    );
  }

  try {

    const body =
      await req.json();

    const {
      order_id,
      otp_type,
      actor_type,
      reason,
    } = body;

    // =====================================================
    // VALIDATION
    // =====================================================

    if (
      !order_id ||
      !otp_type ||
      !actor_type
    ) {

      return Response.json(
        {
          success: false,
          message:
            "order_id, otp_type and actor_type required",
        },
        {
          status: 400,
          headers: corsHeaders,
        },
      );
    }

    if (
      otp_type !==
        "pickup" &&

      otp_type !==
        "delivery"
    ) {

      return Response.json(
        {
          success: false,
          message:
            "Invalid otp_type",
        },
        {
          status: 400,
          headers: corsHeaders,
        },
      );
    }

    if (
      actor_type !== "user" &&
      actor_type !== "rider"
    ) {

      return Response.json(
        {
          success: false,
          message:
            "Invalid actor_type",
        },
        {
          status: 400,
          headers: corsHeaders,
        },
      );
    }

    // =====================================================
    // AUTH
    // Identity is verified from the caller's own JWT below —
    // actor_user_id/actor_rider_id are no longer read from the
    // request body, since a client claim of "who I am" cannot be
    // trusted for an operation that regenerates OTP credentials.
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
    // FETCH ORDER
    // =====================================================

    const {
      data: order,
      error: orderError,
    } = await supabase

      .from("orders")

      .select("*")

      .eq("id", order_id)

      .single();

    if (
      orderError ||
      !order
    ) {

      return Response.json(
        {
          success: false,
          message:
            "Order not found",
        },
        {
          status: 404,
          headers: corsHeaders,
        },
      );
    }

    // =====================================================
    // ORDER STATE VALIDATION
    // =====================================================

    const currentStatus =
      order.order_status;

    // PICKUP OTP
    if (
      otp_type ===
      "pickup"
    ) {

      const allowedStatuses = [

        "accepted",

        "rider_arrived",

        "rider_at_pickup",
      ];

      if (
        !allowedStatuses.includes(
          currentStatus,
        )
      ) {

        return Response.json(
          {
            success: false,
            message:
              "Pickup OTP cannot be regenerated at this stage",
            current_status:
              currentStatus,
          },
          {
            status: 400,
            headers:
              corsHeaders,
          },
        );
      }
    }

    // DELIVERY OTP
    if (
      otp_type ===
      "delivery"
    ) {

      const allowedStatuses = [

        "picked_up",

        "rider_at_drop",
      ];

      if (
        !allowedStatuses.includes(
          currentStatus,
        )
      ) {

        return Response.json(
          {
            success: false,
            message:
              "Delivery OTP cannot be regenerated at this stage",
            current_status:
              currentStatus,
          },
          {
            status: 400,
            headers:
              corsHeaders,
          },
        );
      }
    }

    // =====================================================
    // PERMISSIONS
    // actor_user_id / actor_rider_id are resolved from the verified
    // session (authData.user.id), never from the request body.
    // =====================================================

    let verifiedActorUserId: string | null = null;
    let verifiedActorRiderId: string | null = null;

    if (
      actor_type ===
      "user"
    ) {

      if (
        order.user_id !==
        authData.user.id
      ) {

        return Response.json(
          {
            success: false,
            message:
              "Unauthorized user",
          },
          {
            status: 403,
            headers:
              corsHeaders,
          },
        );
      }

      verifiedActorUserId = authData.user.id;
    }

    if (
      actor_type ===
      "rider"
    ) {

      const { data: callerRider, error: callerRiderError } = await supabase
        .from("riders")
        .select("id")
        .eq("user_id", authData.user.id)
        .maybeSingle();

      if (
        callerRiderError ||
        !callerRider ||
        order.rider_id !== callerRider.id
      ) {

        return Response.json(
          {
            success: false,
            message:
              "Unauthorized rider",
          },
          {
            status: 403,
            headers:
              corsHeaders,
          },
        );
      }

      verifiedActorRiderId = callerRider.id;
    }

    // =====================================================
    // GENERATE OTP
    // =====================================================

    const newOtp =
      generateOtp(4);

    const updatePayload:
      Record<
        string,
        unknown
      > = {

        updated_at:
          new Date()
            .toISOString(),
      };

    if (
      otp_type ===
      "pickup"
    ) {

      updatePayload
        .pickup_otp =
        newOtp;

      updatePayload
        .pickup_otp_attempts =
        0;
    }

    if (
      otp_type ===
      "delivery"
    ) {

      updatePayload
        .delivery_otp =
        newOtp;

      updatePayload
        .delivery_otp_attempts =
        0;
    }

    // =====================================================
    // UPDATE ORDER
    // =====================================================

    const {
      data: updatedOrder,
      error: updateError,
    } = await supabase

      .from("orders")

      .update(
        updatePayload,
      )

      .eq(
        "id",
        order_id,
      )

      .select()

      .single();

    if (
      updateError
    ) {

      return Response.json(
        {
          success: false,
          message:
            "Unable to regenerate OTP",
          error:
            updateError,
        },
        {
          status: 500,
          headers:
            corsHeaders,
        },
      );
    }

    // =====================================================
    // LOG REGENERATE OTP REQUEST
    // =====================================================
    try {
      let targetPhone = "";
      if (otp_type === "pickup") {
        const { data: userRecord } = await supabase
          .from("users")
          .select("phone")
          .eq("id", order.user_id)
          .single();
        targetPhone = userRecord?.phone || "";
      } else {
        targetPhone = order.receiver_phone || "";
      }

      if (targetPhone) {
        await supabase.rpc("log_otp_attempt", {
          p_phone: targetPhone,
          p_is_successful: true,
          p_action_type: "request",
          p_otp_code: newOtp,
          p_client_ip: req.headers.get("x-real-ip") || req.headers.get("cf-connecting-ip") || null,
        });
        // Phase 5 F7: no longer logs the real phone number -- log_otp_attempt's own DB write
        // (unchanged, still receives targetPhone/newOtp for its existing lockout logic) is the
        // real record; this line is diagnostic-only.
        console.log("[RegenerateOTP] Logged OTP request attempt");
      }
    } catch (otpLogErr) {
      console.error("[RegenerateOTP] Error logging OTP request attempt:", otpLogErr);
    }

    // =====================================================
    // STATUS HISTORY
    // =====================================================

    await supabase

      .from(
        "order_status_history",
      )

      .insert({

        order_id:
          order_id,

        previous_status:
          currentStatus,

        new_status:
          currentStatus,

        changed_by:
          actor_type,

        changed_by_user_id:
          verifiedActorUserId,

        changed_by_rider_id:
          verifiedActorRiderId,

        changed_by_admin_id:
          null,

        notes:
          reason ||

          `${otp_type} OTP regenerated`,

        metadata: {

          otp_type:
            otp_type,

          regenerated:
            true,

          order_type:
            order.order_type,
        },
      });

    // =====================================================
    // RESPONSE
    // =====================================================

    return Response.json(
      {
        success: true,

        otp_type:
          otp_type,

        otp:
          newOtp,

        order:
          updatedOrder,
      },
      {
        status: 200,
        headers:
          corsHeaders,
      },
    );

  } catch (error) {

    console.error(
      "REGENERATE OTP ERROR:",
      error,
    );

    return Response.json(
      {
        success: false,
        message:
          String(error),
      },
      {
        status: 500,
        headers:
          corsHeaders,
      },
    );
  }
});