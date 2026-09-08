import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

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
    // Never log Aadhaar/PAN/DL numbers or document URLs -- only non-sensitive
    // shape info, for debugging malformed requests.
    console.log("Create KYC request received", {
      hasUserId: !!body?.user_id,
      vehicleType: body?.vehicle_type,
    });

    // =========================================
    // 0. AUTHENTICATION & OWNERSHIP
    // A user may only submit/overwrite their OWN KYC record. The service-role
    // client below bypasses RLS entirely, so this check is the only thing
    // standing between "any caller with a valid JWT" and "write another
    // user's Aadhaar/PAN/DL". Never trust body.user_id for authorization --
    // it must match the authenticated caller's own id.
    // =========================================
    const authToken = req.headers.get("Authorization")?.replace("Bearer ", "");

    if (!authToken) {
      return Response.json(
        { success: false, message: "Missing auth token" },
        { status: 401, headers: corsHeaders }
      );
    }

    const { data: authData, error: authError } = await supabase.auth.getUser(authToken);

    if (authError || !authData.user) {
      return Response.json(
        { success: false, message: "Unauthorized" },
        { status: 401, headers: corsHeaders }
      );
    }

    if (!body.user_id || body.user_id !== authData.user.id) {
      return Response.json(
        { success: false, message: "Forbidden: cannot submit KYC for another user" },
        { status: 403, headers: corsHeaders }
      );
    }

    // =========================================
    // 1. STANDARD REQUIRED VALIDATION (Without RC Images)
    // =========================================
    const requiredFields = [
      "user_id",
      "full_name",
      "date_of_birth",
      "father_name",
      "vehicle_type",
      "vehicle_number",
      "aadhaar_number",
      "pan_number",
      "driving_license_number",
      "rider_image",
      "aadhaar_front_image",
      "aadhaar_back_image",
      "pan_front_image",
      "pan_back_image",
      "license_front_image",
      "license_back_image",
      "vehicle_image"
    ];

    for (const field of requiredFields) {
      if (
        body[field] === null ||
        body[field] === undefined ||
        String(body[field]).trim() === ""
      ) {
        return Response.json(
          {
            success: false,
            message: `${field} is required`,
          },
          {
            status: 400,
            headers: corsHeaders,
          }
        );
      }
    }

    // =========================================
    // 2. RC IMAGES - SMART EXTRACTION
    // Catching any possible spelling from frontend
    // =========================================
    const rcFrontPath = body.vehicle_rc_front_image || body.VECHILE_RC_front_image || body.rc_front_image || body.rc_front || body.vehicle_rc_front;
    const rcBackPath = body.vehicle_rc_back_image || body.VECHILE_RC_back_image || body.rc_back_image || body.rc_back || body.vehicle_rc_back;

    if (!rcFrontPath || String(rcFrontPath).trim() === "") {
      return Response.json(
        {
          success: false,
          message: "vehicle_rc_front_image is required (Not found in API payload)",
        },
        {
          status: 400,
          headers: corsHeaders,
        }
      );
    }

    if (!rcBackPath || String(rcBackPath).trim() === "") {
      return Response.json(
        {
          success: false,
          message: "vehicle_rc_back_image is required (Not found in API payload)",
        },
        {
          status: 400,
          headers: corsHeaders,
        }
      );
    }

    const {
      user_id,
      full_name,
      date_of_birth,
      father_name,
      vehicle_type,
      vehicle_number,
      aadhaar_number,
      pan_number,
      driving_license_number,
      rider_image,
      aadhaar_front_image,
      aadhaar_back_image,
      pan_front_image,
      pan_back_image,
      license_front_image,
      license_back_image,
      vehicle_image
    } = body;

    // =========================================
    // 3. DATE OF BIRTH VALIDATION
    // =========================================
    const dobStr = String(date_of_birth).trim();
    const dobRegex = /^\d{4}-\d{2}-\d{2}$/;
    if (!dobRegex.test(dobStr)) {
      return Response.json(
        {
          success: false,
          message: "Invalid Date of Birth format (must be YYYY-MM-DD)",
        },
        {
          status: 400,
          headers: corsHeaders,
        }
      );
    }

    const dob = new Date(dobStr);
    if (isNaN(dob.getTime())) {
      return Response.json(
        {
          success: false,
          message: "Invalid Date of Birth date value",
        },
        {
          status: 400,
          headers: corsHeaders,
        }
      );
    }

    // Check minimum age: 18 years
    const today = new Date();
    let age = today.getFullYear() - dob.getFullYear();
    const monthDiff = today.getMonth() - dob.getMonth();
    if (monthDiff < 0 || (monthDiff === 0 && today.getDate() < dob.getDate())) {
      age--;
    }

    if (age < 18) {
      return Response.json(
        {
          success: false,
          message: "You must be at least 18 years old to apply",
        },
        {
          status: 400,
          headers: corsHeaders,
        }
      );
    }

    // =========================================
    // 4. AADHAAR & PAN VALIDATION
    // =========================================
    const aadhaar = String(aadhaar_number).trim();
    if (aadhaar.length !== 12 || !/^[0-9]+$/.test(aadhaar)) {
      return Response.json(
        {
          success: false,
          message: "Invalid Aadhaar number (must be exactly 12 digits)",
        },
        {
          status: 400,
          headers: corsHeaders,
        }
      );
    }

    const pan = String(pan_number).trim().toUpperCase();
    const panRegex = /^[A-Z]{5}[0-9]{4}[A-Z]{1}$/;
    if (!panRegex.test(pan)) {
      return Response.json(
        {
          success: false,
          message: "Invalid PAN number format",
        },
        {
          status: 400,
          headers: corsHeaders,
        }
      );
    }

    // =========================================
    // 5. STORE BARE STORAGE PATHS (P1-2 fix: the rider_kyc bucket is now private --
    // see 20260731000004_rider_kyc_bucket_private.sql). Previously this generated and
    // stored a full public URL, which both baked in an assumption the bucket would
    // stay public and made every stored value dead once it didn't. Storing the bare
    // path decouples the DB row from the bucket's public/private state entirely --
    // every read site resolves a fresh signed URL on demand via
    // lib/shared/helpers/kyc_image_resolver.dart (Flutter) or an equivalent
    // server-side createSignedUrl() call (edge functions), gated by storage RLS.
    // Passed-through unchanged if already a full URL (defensive: a resubmission that
    // happens to echo back an old stored value should not be corrupted).
    // =========================================
    const publicRiderImage = rider_image;
    const publicAadhaarFront = aadhaar_front_image;
    const publicAadhaarBack = aadhaar_back_image;
    const publicPanFront = pan_front_image;
    const publicPanBack = pan_back_image;
    const publicLicenseFront = license_front_image;
    const publicLicenseBack = license_back_image;
    const publicVehicleImage = vehicle_image;

    // Pass the safely extracted RC paths through unchanged
    const publicRcFront = rcFrontPath;
    const publicRcBack = rcBackPath;

    // =========================================
    // 6. FETCH EXISTING KYC
    // =========================================
    const { data: existingKyc, error: existingError } = await supabase
      .from("rider_kyc")
      .select("*")
      .eq("user_id", user_id)
      .maybeSingle();

    if (existingError) {
      console.error(existingError);
      return Response.json(
        {
          success: false,
          message: "Failed to fetch existing KYC record",
        },
        {
          status: 400,
          headers: corsHeaders,
        }
      );
    }

    let kycId: string;
    let finalKycData: any;

    if (existingKyc) {
      // Block submission if not rejected (e.g. pending/approved)
      if (existingKyc.kyc_status !== "rejected") {
        return Response.json(
          {
            success: false,
            message: "KYC already submitted and is under review or approved",
          },
          {
            status: 400,
            headers: corsHeaders,
          }
        );
      }

      // Block submission if in cooldown period
      if (existingKyc.blocked_until) {
        const blockedUntil = new Date(existingKyc.blocked_until);
        if (blockedUntil > new Date()) {
          return Response.json(
            {
              success: false,
              message: "KYC re-upload temporarily blocked",
              blocked_until: existingKyc.blocked_until,
            },
            {
              status: 429,
              headers: corsHeaders,
            }
          );
        }
      }

      // Update rejected KYC
      const rejectionCount = (existingKyc.rejection_count ?? 0) + 1;
      let blockedUntil = null;
      if (rejectionCount >= 2) {
        const future = new Date();
        future.setDate(future.getDate() + 7);
        blockedUntil = future.toISOString();
      }

      const { data: updatedKyc, error: updateError } = await supabase
        .from("rider_kyc")
        .update({
          full_name,
          date_of_birth,
          father_name,
          vehicle_type,
          vehicle_number,
          aadhaar_number,
          pan_number: pan.toUpperCase(),
          driving_license_number,
          rider_image: publicRiderImage,
          aadhaar_front_image: publicAadhaarFront,
          aadhaar_back_image: publicAadhaarBack,
          pan_front_image: publicPanFront,
          pan_back_image: publicPanBack,
          license_front_image: publicLicenseFront,
          license_back_image: publicLicenseBack,
          vehicle_image: publicVehicleImage,
          VECHILE_RC_front_image: publicRcFront, // Correctly mapping to DB spelling
          VECHILE_RC_back_image: publicRcBack,   // Correctly mapping to DB spelling
          kyc_status: "resubmitted",
          activation_status: "inactive",
          rejection_reason: null,
          rejected_at: null,
          approved_at: null,
          rejection_count: rejectionCount,
          blocked_until: blockedUntil,
          updated_at: new Date().toISOString(),
        })
        .eq("id", existingKyc.id)
        .select()
        .single();

      if (updateError) {
        console.error("Update KYC Error:", updateError);
        return Response.json(
          {
            success: false,
            message: updateError.message,
          },
          {
            status: 400,
            headers: corsHeaders,
          }
        );
      }

      kycId = existingKyc.id;
      finalKycData = updatedKyc;
    } else {
      // Create new KYC
      const { data: newKyc, error: insertError } = await supabase
        .from("rider_kyc")
        .insert({
          user_id,
          full_name,
          date_of_birth,
          father_name,
          vehicle_type,
          vehicle_number,
          aadhaar_number,
          pan_number: pan.toUpperCase(),
          driving_license_number,
          rider_image: publicRiderImage,
          aadhaar_front_image: publicAadhaarFront,
          aadhaar_back_image: publicAadhaarBack,
          pan_front_image: publicPanFront,
          pan_back_image: publicPanBack,
          license_front_image: publicLicenseFront,
          license_back_image: publicLicenseBack,
          vehicle_image: publicVehicleImage,
          VECHILE_RC_front_image: publicRcFront, // Correctly mapping to DB spelling
          VECHILE_RC_back_image: publicRcBack,   // Correctly mapping to DB spelling
          kyc_status: "pending",
          activation_status: "inactive",
        })
        .select()
        .single();

      if (insertError) {
        console.error("Insert KYC Error:", insertError);

        // 23505 = unique_violation. This means a concurrent request for the
        // same user_id (e.g. a client retry fired while the original
        // request was still being processed) already inserted a row between
        // our existence check above and this insert. Report it the same
        // way as the "already exists" case above instead of a raw DB error,
        // so the client routes to the pending screen instead of showing a
        // confusing internal error -- and so we never end up with two
        // rider_kyc rows for one user.
        if (insertError.code === "23505") {
          return Response.json(
            {
              success: false,
              message: "KYC already submitted and is under review or approved",
            },
            {
              status: 409,
              headers: corsHeaders,
            }
          );
        }

        return Response.json(
          {
            success: false,
            message: insertError.message,
          },
          {
            status: 400,
            headers: corsHeaders,
          }
        );
      }

      kycId = newKyc.id;
      finalKycData = newKyc;
    }

    return Response.json(
      {
        success: true,
        message: existingKyc ? "KYC re-submitted successfully" : "KYC submitted successfully",
        data: finalKycData,
      },
      {
        headers: corsHeaders,
      }
    );
  } catch (e: any) {
    console.error(e);
    return Response.json(
      {
        success: false,
        message: e.message || "Internal server error",
      },
      {
        status: 500,
        headers: corsHeaders,
      }
    );
  }
});