// supabase/functions/process-verification-photo/index.ts

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
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

    // =====================================================
    // SSRF GUARD
    // Only allow fetching from this project's own public storage bucket
    // for parcel verification photos — never an arbitrary caller-supplied URL.
    // =====================================================
    const allowedPhotoUrlPrefix = `${Deno.env.get("SUPABASE_URL")}/storage/v1/object/public/parcel_images/`;
    if (!photo_url.startsWith(allowedPhotoUrlPrefix)) {
      return new Response(
        JSON.stringify({ success: false, error: "Invalid photo_url" }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: 400 }
      );
    }

    console.log(`[ProcessPhoto] Downloading image bytes from URL: ${photo_url}`);

    // 1. Download image bytes
    const imgRes = await fetchWithTimeout(photo_url, {}, 20000);
    if (!imgRes.ok) {
      throw new Error(`Failed to download image from storage (HTTP ${imgRes.status})`);
    }
    const arrayBuffer = await imgRes.arrayBuffer();

    // 2. Compute SHA-256 checksum
    console.log("[ProcessPhoto] Computing SHA-256 checksum server-side");
    const hashBuffer = await crypto.subtle.digest("SHA-256", arrayBuffer);
    const hashArray = Array.from(new Uint8Array(hashBuffer));
    const hashHex = hashArray.map(b => b.toString(16).padStart(2, '0')).join('');
    console.log(`[ProcessPhoto] SHA-256 hash computed: ${hashHex}`);

    // 3. Fetch order details to get sender user_id
    const { data: order, error: orderError } = await supabase
      .from("orders")
      .select("user_id, created_device_ref")
      .eq("id", order_id)
      .single();

    if (orderError || !order) {
      throw new Error("Order not found");
    }

    // 4. Log photo in order_parcel_photos
    const { data: photoLog, error: photoError } = await supabase
      .from("order_parcel_photos")
      .insert({
        order_id,
        rider_id,
        photo_url,
        photo_type,
        latitude: latitude || null,
        longitude: longitude || null,
        file_sha256: hashHex,
      })
      .select()
      .single();

    if (photoError) {
      throw photoError;
    }

    // 5. Update order verification status if it is a pickup photo
    if (photo_type === "pickup") {
      const { error: updateError } = await supabase
        .from("orders")
        .update({
          pickup_verification_completed: true,
          pickup_verification_completed_at: new Date().toISOString(),
        })
        .eq("id", order_id);

      if (updateError) {
        throw updateError;
      }
    }

    // Rider user_id to set as created_by. The ownership check above already fetched and verified
    // uploadingRider.user_id === authData.user.id, so re-querying riders here for the same value
    // was a redundant round trip (WayDrop Progressive Degradation Audit, finding EDGE-6) — reuse it.
    const riderUserId: string | null = authData.user.id;

    // Insert verification record
    const { error: verificationError } = await supabase
      .from("order_verifications")
      .insert({
        order_id,
        verification_type: photo_type,
        verification_status: "verified",
        photo_url,
        latitude: latitude || null,
        longitude: longitude || null,
        metadata: {
          file_sha256: hashHex,
          photo_log_id: photoLog.id,
          device_id: device_id || null,
        },
        created_by: riderUserId,
      });

    if (verificationError) {
      console.error("[ProcessPhoto] Error inserting verification record:", verificationError);
      throw verificationError;
    }

    // 6. Log security event in parcel_security_logs
    const ipAddress = req.headers.get("x-real-ip") || req.headers.get("cf-connecting-ip") || null;
    const { error: logError } = await supabase
      .from("parcel_security_logs")
      .insert({
        order_id,
        sender_user_id: order.user_id,
        rider_id,
        event_type: `${photo_type}_photo_uploaded`,
        latitude: latitude || null,
        longitude: longitude || null,
        event_latitude: latitude || null,
        event_longitude: longitude || null,
        ip_address: ipAddress,
        device_id: device_id || null,
        metadata: {
          photo_id: photoLog.id,
          photo_type,
          file_sha256: hashHex,
          client_timestamp: new Date().toISOString(),
        }
      });

    if (logError) {
      console.error("[ProcessPhoto] Error writing security log:", logError);
    }

    return new Response(
      JSON.stringify({
        success: true,
        file_sha256: hashHex,
        photo_log_id: photoLog.id,
      }),
      {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
        status: 200,
      }
    );
  } catch (error) {
    console.error("[ProcessPhoto] Error processing verification photo:", error);
    return new Response(
      JSON.stringify({
        success: false,
        error: isTimeoutError(error)
          ? "Timed out downloading the photo. Please try again."
          : (error.message || "Unknown error"),
      }),
      {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
        status: isTimeoutError(error) ? 504 : 500,
      }
    );
  }
});
