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
    // Never log Aadhaar/PAN/DL numbers -- only non-sensitive shape info.
    console.log("Validate KYC request received", {
      hasUserId: !!body?.user_id,
      vehicleType: body?.vehicle_type,
    });

    // =====================================
    // 0. AUTHENTICATION & OWNERSHIP
    // Mirrors create-rider-kyc/index.ts -- a caller may only validate/probe
    // their OWN KYC record. Never trust body.user_id for authorization.
    // =====================================
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
        { success: false, message: "Forbidden: cannot validate KYC for another user" },
        { status: 403, headers: corsHeaders }
      );
    }

    // =====================================
    // REQUIRED FIELDS
    // =====================================
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
    ];

    for (const field of requiredFields) {
      const value = body[field];
      if (
        value === null ||
        value === undefined ||
        String(value).trim() === ""
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
    } = body;

    // =====================================
    // DATE OF BIRTH VALIDATION
    // =====================================
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

    // =====================================
    // FULL NAME VALIDATION
    // =====================================
    if (String(full_name).trim().length < 3) {
      return Response.json(
        {
          success: false,
          message: "Invalid full name (minimum 3 characters)",
        },
        {
          status: 400,
          headers: corsHeaders,
        }
      );
    }

    // =====================================
    // FATHER NAME VALIDATION
    // =====================================
    if (String(father_name).trim().length < 3) {
      return Response.json(
        {
          success: false,
          message: "Invalid father name (minimum 3 characters)",
        },
        {
          status: 400,
          headers: corsHeaders,
        }
      );
    }

    // =====================================
    // VEHICLE TYPE VALIDATION
    // =====================================
    const allowedVehicles = ["bike", "auto", "cab"];
    if (!allowedVehicles.includes(vehicle_type)) {
      return Response.json(
        {
          success: false,
          message: "Invalid vehicle type. Allowed types: bike, auto, cab",
        },
        {
          status: 400,
          headers: corsHeaders,
        }
      );
    }

    // =====================================
    // VEHICLE NUMBER VALIDATION
    // =====================================
    if (String(vehicle_number).trim().length < 5) {
      return Response.json(
        {
          success: false,
          message: "Invalid vehicle number (minimum 5 characters)",
        },
        {
          status: 400,
          headers: corsHeaders,
        }
      );
    }

    // =====================================
    // AADHAAR VALIDATION
    // =====================================
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

    // =====================================
    // PAN VALIDATION
    // =====================================
    const pan = String(pan_number).trim().toUpperCase();
    const panRegex = /^[A-Z]{5}[0-9]{4}[A-Z]{1}$/;
    if (!panRegex.test(pan)) {
      return Response.json(
        {
          success: false,
          message: "Invalid PAN number format (e.g. ABCDE1234F)",
        },
        {
          status: 400,
          headers: corsHeaders,
        }
      );
    }

    // =====================================
    // DL VALIDATION
    // =====================================
    if (String(driving_license_number).trim().length < 5) {
      return Response.json(
        {
          success: false,
          message: "Invalid driving license number",
        },
        {
          status: 400,
          headers: corsHeaders,
        }
      );
    }

    // =====================================
    // CHECK EXISTING KYC
    // =====================================
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
          message: "Failed to verify existing KYC",
        },
        {
          status: 400,
          headers: corsHeaders,
        }
      );
    }

    // =====================================
    // EXISTING KYC CHECKS
    // =====================================
    if (existingKyc) {
      if (
        existingKyc.kyc_status === "pending" ||
        existingKyc.kyc_status === "under_review" ||
        existingKyc.kyc_status === "resubmitted"
      ) {
        return Response.json(
          {
            success: false,
            message: "KYC already under review",
          },
          {
            status: 409,
            headers: corsHeaders,
          }
        );
      }

      if (existingKyc.kyc_status === "approved") {
        return Response.json(
          {
            success: false,
            message: "KYC already approved",
          },
          {
            status: 409,
            headers: corsHeaders,
          }
        );
      }

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
    }

    return Response.json(
      {
        success: true,
        message: "Validation successful",
      },
      {
        headers: corsHeaders,
      }
    );
  } catch (e) {
    console.error(e);
    return Response.json(
      {
        success: false,
        message: "Internal server error",
      },
      {
        status: 500,
        headers: corsHeaders,
      }
    );
  }
});
