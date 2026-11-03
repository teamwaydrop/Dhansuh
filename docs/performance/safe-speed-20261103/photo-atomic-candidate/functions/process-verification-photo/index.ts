// supabase/functions/process-verification-photo/index.ts

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { isTimeoutError } from "../_shared/http.ts";
import { downloadPhotoBytes } from "../_shared/photo_download.ts";

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
      photo_type,
      photo_url,
      latitude,
      longitude,
      rider_id,
      device_id, // public device ref or raw id of rider
    } = body;

    if (!order_id) throw new Error("Order ID required");
    if (!photo_url) throw new Error("Photo URL required");
    if (!rider_id) throw new Error("Rider ID required");
    if (!photo_type) throw new Error("Photo type required");

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
    // OWNERSHIP CHECK
    // =====================================================
    const { data: uploadingRider, error: uploadingRiderError } = await supabase
      .from("riders")
      .select("user_id")
      .eq("id", rider_id)
      .single();

    if (uploadingRiderError || !uploadingRider) {
      return new Response(
        JSON.stringify({ success: false, error: "Rider not found" }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: 404 }
      );
    }

    if (uploadingRider.user_id !== authData.user.id) {
      return new Response(
        JSON.stringify({ success: false, error: "Forbidden: rider_id does not belong to authenticated user" }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: 403 }
      );
    }

    if (!["pickup", "dropoff"].includes(photo_type)) {
      return new Response(
        JSON.stringify({ success: false, error: "Invalid photo_type" }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: 400 }
      );
    }

    // =====================================================
    // SSRF GUARD
    // Only allow fetching from this project's own public storage bucket
    // for parcel verification photos — never an arbitrary caller-supplied URL.
    // =====================================================
    const allowedPhotoUrlPrefix = `${Deno.env.get("SUPABASE_URL")}/storage/v1/object/public/parcel_images/`;
    if (typeof photo_url !== "string" || !photo_url.startsWith(allowedPhotoUrlPrefix)) {
      return new Response(
        JSON.stringify({ success: false, error: "Invalid photo_url" }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: 400 }
      );
    }

    // Check order scope before paying for a Storage download/hash or service-role writes.
    const { data: order, error: orderError } = await supabase
      .from("orders")
      .select("user_id, created_device_ref, rider_id")
      .eq("id", order_id)
      .single();
    if (orderError && orderError.code !== "PGRST116") {
      return new Response(
        JSON.stringify({ success: false, error: "Unable to verify order. Please retry." }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: 503 }
      );
    }
    if (!order) {
      return new Response(
        JSON.stringify({ success: false, error: "Order not found" }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: 404 }
      );
    }
    if (order.rider_id !== rider_id) {
      return new Response(
        JSON.stringify({ success: false, error: "Forbidden: rider is not assigned to this order" }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: 403 }
      );
    }

    console.log("[ProcessPhoto] Downloading verification photo");

    // 1. Download image bytes
    const arrayBuffer = await downloadPhotoBytes(photo_url);

    // 2. Compute SHA-256 checksum
    console.log("[ProcessPhoto] Computing SHA-256 checksum server-side");
    const hashBuffer = await crypto.subtle.digest("SHA-256", arrayBuffer);
    const hashArray = Array.from(new Uint8Array(hashBuffer));
    const hashHex = hashArray.map(b => b.toString(16).padStart(2, '0')).join('');

    // Commit proof effects under one locked, assignment-checked transaction.
    const { data: proof, error: proofError } = await supabase.rpc("record_order_photo_proof_v1", {
      p_order_id: order_id,
      p_actor_user_id: authData.user.id,
      p_rider_id: rider_id,
      p_photo_type: photo_type,
      p_photo_url: photo_url,
      p_file_sha256: hashHex,
      p_latitude: latitude ?? null,
      p_longitude: longitude ?? null,
      p_device_id: device_id || null,
      p_ip_address: req.headers.get("x-real-ip") || req.headers.get("cf-connecting-ip") || null,
    });
    if (proofError || proof?.success !== true) {
      const status = proofError?.code === "42501" ? 403 : proofError?.code === "P0002" ? 404 : 503;
      return new Response(JSON.stringify({ success: false, error: status === 503 ? "Proof result is unconfirmed. Check proof status before retrying." : "Proof access denied or order unavailable." }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" }, status });
    }

    return new Response(
      JSON.stringify({
        success: true,
        file_sha256: hashHex,
        photo_log_id: proof.photo_log_id,
      }),
      {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
        status: 200,
      }
    );
  } catch (error) {
    console.error("[ProcessPhoto] Photo proof result could not be confirmed");
    return new Response(
      JSON.stringify({
        success: false,
        error: isTimeoutError(error)
          ? "Timed out downloading the photo. Please try again."
          : "Unable to confirm photo proof. Check proof status before retrying.",
      }),
      {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
        status: isTimeoutError(error) ? 504 : 500,
      }
    );
  }
});
