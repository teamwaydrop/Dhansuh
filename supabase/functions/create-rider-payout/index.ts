import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

// Reasonable UPI VPA format check -- "name@handle", handle letters only, no Cashfree/gateway
// verification involved (see the self-certification check below for why).
const UPI_VPA_REGEX = /^[a-zA-Z0-9.\-_]{2,256}@[a-zA-Z][a-zA-Z0-9]{1,64}$/;

// =====================================================
// CASHFREE PAYOUT SIGNATURE GENERATION (RSA-OAEP 2FA)
// =====================================================
async function importPublicKey(pem: string): Promise<CryptoKey> {
  const pemHeader = "-----BEGIN PUBLIC KEY-----";
  const pemFooter = "-----END PUBLIC KEY-----";
  const pemBody = pem
    .replace(pemHeader, "")
    .replace(pemFooter, "")
    .replace(/\s+/g, "");

  const binaryDerString = atob(pemBody);
  const binaryDer = new Uint8Array(binaryDerString.length);
  for (let i = 0; i < binaryDerString.length; i++) {
    binaryDer[i] = binaryDerString.charCodeAt(i);
  }

  return await crypto.subtle.importKey(
    "spki",
    binaryDer,
    {
      name: "RSA-OAEP",
      hash: "SHA-1",
    },
    true,
    ["encrypt"]
  );
}

async function generateSignature(clientId: string, pemKey: string): Promise<string> {
  const timestamp = Math.floor(Date.now() / 1000).toString();
  const dataString = `${clientId}.${timestamp}`;
  const dataBytes = new TextEncoder().encode(dataString);

  const publicKey = await importPublicKey(pemKey);
  const encryptedBuffer = await crypto.subtle.encrypt(
    { name: "RSA-OAEP" },
    publicKey,
    dataBytes
  );

  const encryptedBytes = new Uint8Array(encryptedBuffer);
  let binaryString = "";
  for (let i = 0; i < encryptedBytes.length; i++) {
    binaryString += String.fromCharCode(encryptedBytes[i]);
  }
  return btoa(binaryString);
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return Response.json(
        { success: false, message: "Authorization header is required" },
        { status: 401, headers: corsHeaders }
      );
    }

    const token = authHeader.replace("Bearer ", "").trim();
    const { data: { user }, error: authError } = await supabase.auth.getUser(token);

    if (authError || !user) {
      return Response.json(
        { success: false, message: "Unauthorized or invalid session" },
        { status: 401, headers: corsHeaders }
      );
    }

    if (req.method === "DELETE") {
      console.log("Delete Payout request received for user:", user.id);
      const { error: deleteError } = await supabase
        .from("rider_payout_accounts")
        .delete()
        .eq("user_id", user.id);

      if (deleteError) {
        return Response.json(
          { success: false, message: `Failed to delete payout details: ${deleteError.message}` },
          { status: 500, headers: corsHeaders }
        );
      }

      return Response.json(
        { success: true, message: "Payout details deleted successfully" },
        { status: 200, headers: corsHeaders }
      );
    }
  
    const body = await req.json();
    console.log("Create Rider Payout payload received for user:", user.id);

    // =========================================
    // GENERAL REQUIRED VALIDATIONS
    // =========================================
    const generalRequired = ["beneficiary_name", "beneficiary_phone", "payout_method"];
    for (const field of generalRequired) {
      if (
        body[field] === null ||
        body[field] === undefined ||
        String(body[field]).trim() === ""
      ) {
        return Response.json(
          { success: false, message: `${field.replace("_", " ")} is required` },
          { status: 400, headers: corsHeaders }
        );
      }
    }

    const {
      beneficiary_name,
      beneficiary_email,
      beneficiary_phone,
      payout_method,
      account_number,
      ifsc_code,
      upi_vpa,
      // Driver's explicit "this UPI ID belongs to me" confirmation -- required, in this same
      // request, whenever a upi_vpa is submitted (see the check below). This is what replaces
      // Cashfree VPA Verification as the source of truth for whether personal_upi can be offered
      // to passengers: our merchant account doesn't have access to Cashfree's Validate Payout
      // capability (a separately-licensed "Verification Suite" feature), so we no longer depend
      // on it at all, and never fake a gateway verification we can't perform.
      upi_self_certified,
    } = body;

    if (payout_method !== "bank_account" && payout_method !== "upi") {
      return Response.json(
        { success: false, message: "Invalid payout method (must be bank_account or upi)" },
        { status: 400, headers: corsHeaders }
      );
    }

    // Method-specific validations
    let accNum: string | null = null;
    let ifsc: string | null = null;
    let upiVpa: string | null = null;

    if (payout_method === "bank_account") {
      if (!account_number || String(account_number).trim() === "") {
        return Response.json(
          { success: false, message: "Account number is required for bank transfer" },
          { status: 400, headers: corsHeaders }
        );
      }
      if (!ifsc_code || String(ifsc_code).trim() === "") {
        return Response.json(
          { success: false, message: "IFSC Code is required for bank transfer" },
          { status: 400, headers: corsHeaders }
        );
      }

      // Validate IFSC
      ifsc = String(ifsc_code).trim().toUpperCase();
      const ifscRegex = /^[A-Z]{4}0[A-Z0-9]{6}$/;
      if (!ifscRegex.test(ifsc)) {
        return Response.json(
          { success: false, message: "Invalid IFSC Code format (e.g. HDFC0000123)" },
          { status: 400, headers: corsHeaders }
        );
      }

      // Validate Account Number
      accNum = String(account_number).trim();
      if (accNum.length < 8 || accNum.length > 20 || !/^\d+$/.test(accNum)) {
        return Response.json(
          { success: false, message: "Account number must be numeric and between 8 and 20 digits" },
          { status: 400, headers: corsHeaders }
        );
      }

      // Extract and validate upi_vpa if provided
      if (upi_vpa && String(upi_vpa).trim() !== "") {
        upiVpa = String(upi_vpa).trim();
        if (!UPI_VPA_REGEX.test(upiVpa)) {
          return Response.json(
            { success: false, message: "Invalid UPI VPA ID format (expected something like name@bank)" },
            { status: 400, headers: corsHeaders }
          );
        }
      }
    } else if (payout_method === "upi") {
      if (!upi_vpa || String(upi_vpa).trim() === "") {
        return Response.json(
          { success: false, message: "UPI ID (VPA) is required for UPI payout" },
          { status: 400, headers: corsHeaders }
        );
      }
      upiVpa = String(upi_vpa).trim();
      if (!UPI_VPA_REGEX.test(upiVpa)) {
        return Response.json(
          { success: false, message: "Invalid UPI VPA ID format (expected something like name@bank)" },
          { status: 400, headers: corsHeaders }
        );
      }
    }

    // =========================================
    // UPI OWNERSHIP SELF-CERTIFICATION
    // Replaces Cashfree VPA Verification entirely -- our merchant account doesn't have access to
    // that capability (a separately-licensed feature), and we never fake a gateway verification we
    // can't perform. Required in this exact request whenever a upi_vpa is submitted at all, so a
    // driver who changes their UPI ID must re-confirm every time (there is no "unchanged, so skip
    // it" case -- simpler and strictly safer than tracking whether the value actually changed).
    // =========================================
    if (upiVpa && upi_self_certified !== true) {
      return Response.json(
        {
          success: false,
          message: "Please confirm that this UPI ID belongs to you and the details are correct before saving.",
        },
        { status: 400, headers: corsHeaders }
      );
    }

    // =========================================
    // GET RIDER PROFILE
    // =========================================
    const { data: rider, error: riderError } = await supabase
      .from("riders")
      .select("id")
      .eq("user_id", user.id)
      .maybeSingle();

    if (riderError || !rider) {
      return Response.json(
        {
          success: false,
          message: "Rider profile not found. Please complete your KYC verification first.",
        },
        {
          status: 400,
          headers: corsHeaders,
        }
      );
    }

    const riderId = rider.id;

    // =========================================
    // CASHFREE CONFIGURATION (LOADED EARLY FOR DELETIONS)
    // =========================================
    const cashfreeClientId = Deno.env.get("CASHFREE_PAYOUT_CLIENT_ID");
    const cashfreeClientSecret = Deno.env.get("CASHFREE_PAYOUT_CLIENT_SECRET");
    const cashfreePublicKeyPEM = Deno.env.get("CASHFREE_PAYOUT_PUBLIC_KEY");
    const cashfreeEnv = Deno.env.get("CASHFREE_ENV") || "production";

    if (!cashfreeClientId) {
      console.error("Missing CASHFREE_PAYOUT_CLIENT_ID secret!");
      return Response.json(
        { success: false, message: "Server configuration missing Client ID. Please contact support." },
        { status: 500, headers: corsHeaders }
      );
    }

    // WayDrop Cashfree hardening (payout 2FA fail-fast): this account has Payouts 2FA enabled --
    // every Beneficiary/Payout call below (Delete, Add, and the Get Beneficiary conflict-recovery
    // lookup) requires the RSA-OAEP X-Cf-Signature header derived from this key, confirmed live in
    // production (see the Get Beneficiary V2 lookup comment further down). Previously, a missing/
    // empty key just meant the header was silently omitted and Cashfree rejected the call with a
    // generic gateway error indistinguishable from a real business-validation failure. Failing fast
    // here, in the same place and style as the CLIENT_ID check above, surfaces a clear
    // server-misconfiguration message instead. Never logs/returns the key value itself.
    if (!cashfreePublicKeyPEM || cashfreePublicKeyPEM.trim() === "") {
      console.error("Missing CASHFREE_PAYOUT_PUBLIC_KEY secret!");
      return Response.json(
        { success: false, message: "Server configuration missing signing key. Please contact support." },
        { status: 500, headers: corsHeaders }
      );
    }

    const isProduction = cashfreeEnv.toLowerCase() === "production";
    const cashfreeBaseUrl = isProduction
      ? "https://api.cashfree.com/payout"
      : "https://sandbox.cashfree.com/payout";

    // =========================================
    // CHECK EXISTING PAYOUT ACCOUNT & REMOVE TO TRIGGER NEW ID
    // =========================================
    const { data: existingPayout, error: payoutFetchError } = await supabase
      .from("rider_payout_accounts")
      .select("*")
      .eq("user_id", user.id)
      .maybeSingle();

    if (payoutFetchError) {
      console.error("Error checking existing payout account:", payoutFetchError);
    }

    let payoutRecord: any;
    const newBeneficiaryId = `WDR_${user.id.replace(/-/g, "").substring(0, 16)}_${Math.floor(Date.now() / 1000)}`;

    if (existingPayout) {
      console.log(`Updating existing payout details. Generating a new unique beneficiary_id: ${newBeneficiaryId}...`);

      // Delete old beneficiary from Cashfree if it has a beneficiary_id
      if (existingPayout.beneficiary_id) {
        console.log(`Deleting old beneficiary ID: ${existingPayout.beneficiary_id} from Cashfree...`);
        try {
          const deleteHeaders: any = {
            "Content-Type": "application/json",
            "x-api-version": "2024-01-01",
            "x-client-id": cashfreeClientId,
          };
          if (cashfreeClientSecret) {
            deleteHeaders["x-client-secret"] = cashfreeClientSecret;
          }

          // Generate signature if PEM key exists
          if (cashfreePublicKeyPEM && cashfreePublicKeyPEM.trim() !== "") {
            try {
              const signature = await generateSignature(cashfreeClientId, cashfreePublicKeyPEM);
              deleteHeaders["X-Cf-Signature"] = signature;
            } catch (sigError: any) {
              console.error("Failed to generate signature for deletion:", sigError);
            }
          }

          const deleteUrl = `${cashfreeBaseUrl}/beneficiary`;
          console.log(`Invoking Cashfree Delete Beneficiary on: ${deleteUrl} with ID: ${existingPayout.beneficiary_id}`);
          const deleteResponse = await fetch(deleteUrl, {
            method: "DELETE",
            headers: deleteHeaders,
            body: JSON.stringify({
              beneficiary_id: existingPayout.beneficiary_id,
            }),
          });
          const deleteText = await deleteResponse.text();
          console.log(`Cashfree Delete Beneficiary responded with status ${deleteResponse.status}: ${deleteText}`);
        } catch (deleteError) {
          console.error(`Failed to delete beneficiary ${existingPayout.beneficiary_id} from Cashfree:`, deleteError);
        }
      }

      // Update the existing database record in place with the new unique beneficiary_id
      const { data: updated, error: updateError } = await supabase
        .from("rider_payout_accounts")
        .update({
          beneficiary_id: newBeneficiaryId,
          beneficiary_name: beneficiary_name.trim(),
          beneficiary_email: beneficiary_email ? beneficiary_email.trim() : null,
          beneficiary_phone: beneficiary_phone.trim(),
          payout_method: payout_method,
          account_number: accNum,
          ifsc_code: ifsc,
          upi_vpa: upiVpa,
          upi_self_certified: !!upiVpa,
          upi_self_certified_at: upiVpa ? new Date().toISOString() : null,
          cashfree_beneficiary_status: "pending",
          cashfree_beneficiary_added: false,
          updated_at: new Date().toISOString(),
        })
        .eq("id", existingPayout.id)
        .select()
        .single();

      if (updateError || !updated) {
        return Response.json(
          { success: false, message: `Failed to update payout details: ${updateError?.message}` },
          { status: 500, headers: corsHeaders }
        );
      }
      payoutRecord = updated;
    } else {
      // Insert new payout record using the generated new unique beneficiary_id
      const { data: inserted, error: insertError } = await supabase
        .from("rider_payout_accounts")
        .insert({
          rider_id: riderId,
          user_id: user.id,
          beneficiary_id: newBeneficiaryId,
          beneficiary_name: beneficiary_name.trim(),
          beneficiary_email: beneficiary_email ? beneficiary_email.trim() : null,
          beneficiary_phone: beneficiary_phone.trim(),
          payout_method: payout_method,
          account_number: accNum,
          ifsc_code: ifsc,
          upi_vpa: upiVpa,
          upi_self_certified: !!upiVpa,
          upi_self_certified_at: upiVpa ? new Date().toISOString() : null,
          cashfree_beneficiary_status: "pending",
          cashfree_beneficiary_added: false,
        })
        .select()
        .single();

      if (insertError || !inserted) {
        return Response.json(
          { success: false, message: `Failed to create payout details: ${insertError?.message}` },
          { status: 500, headers: corsHeaders }
        );
      }
      payoutRecord = inserted;
    }
    
    const beneficiaryId = payoutRecord.beneficiary_id;
    console.log("Assigned/Generated Beneficiary ID:", beneficiaryId);

    // =========================================
    // CASHFREE PAYOUT INTEGRATION (PREVIOUSLY DEFINED ABOVE)
    // =========================================

    // Setup V2 instrument details
    const instrumentDetails: any = {};
    if (payout_method === "bank_account") {
      instrumentDetails.bank_account_number = accNum;
      instrumentDetails.bank_ifsc = ifsc;
      if (upiVpa) {
        instrumentDetails.vpa = upiVpa;
      }
    } else if (payout_method === "upi") {
      instrumentDetails.vpa = upiVpa;
    }

    const cashfreeBody: any = {
      beneficiary_id: beneficiaryId,
      beneficiary_name: beneficiary_name.trim(),
      beneficiary_instrument_details: instrumentDetails,
      beneficiary_contact_details: {
        beneficiary_phone: beneficiary_phone.trim(),
        beneficiary_country_code: "+91",
      }
    };

    if (beneficiary_email && beneficiary_email.trim() !== "") {
      cashfreeBody.beneficiary_contact_details.beneficiary_email = beneficiary_email.trim();
    }

    // Configure headers dynamically
    const headers: any = {
      "Content-Type": "application/json",
      "x-api-version": "2024-01-01",
      "x-client-id": cashfreeClientId,
    };

    if (cashfreeClientSecret) {
      headers["x-client-secret"] = cashfreeClientSecret;
    }

    // Dynamic 2FA Request Signing using Public Key if configured
    if (cashfreePublicKeyPEM && cashfreePublicKeyPEM.trim() !== "") {
      try {
        console.log("Generating cryptographic signature using Public Key PEM...");
        const signature = await generateSignature(cashfreeClientId, cashfreePublicKeyPEM);
        headers["X-Cf-Signature"] = signature;
        console.log("X-Cf-Signature generated and bound to headers successfully.");
      } catch (sigError: any) {
        console.error("Failed to generate RSA-OAEP X-Cf-Signature:", sigError);
        return Response.json(
          { success: false, message: `Signature Generation Error: ${sigError.message}` },
          { status: 500, headers: corsHeaders }
        );
      }
    }

    console.log(`Invoking Cashfree Beneficiary V2 API on: ${cashfreeBaseUrl}`);

    try {
      const response = await fetch(`${cashfreeBaseUrl}/beneficiary`, {
        method: "POST",
        headers: headers,
        body: JSON.stringify(cashfreeBody),
      });

      const responseText = await response.text();
      let responseJson: any = {};
      try {
        responseJson = JSON.parse(responseText);
      } catch (e) {
        console.error("Error parsing Cashfree response JSON payload:", responseText);
      }

      console.log(`Cashfree API returned status: ${response.status}`, responseJson);

      if (response.status === 200 || response.status === 201) {
        // SUCCESS
        await supabase
          .from("rider_payout_accounts")
          .update({
            cashfree_beneficiary_added: true,
            cashfree_beneficiary_status: "active",
            cashfree_beneficiary_response: responseJson,
            updated_at: new Date().toISOString(),
          })
          .eq("id", payoutRecord.id);

        return Response.json(
          {
            success: true,
            message: "Payout details and Cashfree beneficiary registered successfully",
            beneficiary_id: beneficiaryId,
          },
          { status: 200, headers: corsHeaders }
        );
      } else {
        // IDEMPOTENCY check
        // BUG FIX (Phase 3 financial audit): Cashfree's "conflict_with_existing_beneficiary"
        // does NOT mean this exact beneficiary_id already exists -- it means the given
        // bank_account_number/IFSC (or VPA) is already registered under a DIFFERENT
        // beneficiary_id. The newBeneficiaryId generated above was never actually created on
        // Cashfree's side in this case. Treating it as a success (as this code previously did,
        // matching on the generic "already exists" substring) wrote a fabricated 'active' status
        // for a beneficiary_id Cashfree has no record of -- every subsequent withdrawal attempt
        // against it then failed with "beneficiary_not_found". This is now excluded from the
        // idempotency shortcut and falls through to the FAILURE branch below instead, so the
        // status accurately reflects that no real, transfer-ready beneficiary was registered.
        const errorMessage = responseJson.message || "Partner validation error";
        const conflictCode = (responseJson.code || "").toLowerCase();
        const isBankDetailsConflict = conflictCode === "conflict_with_existing_beneficiary";
        const isAlreadyExists =
          !isBankDetailsConflict &&
          (errorMessage.toLowerCase().includes("already exists") ||
            conflictCode.includes("already_exists") ||
            (responseJson.subCode && responseJson.subCode.toLowerCase().includes("already_exists")));

        if (isAlreadyExists) {
          console.log("Beneficiary already exists in Cashfree. Treating as successfully registered.");
          await supabase
            .from("rider_payout_accounts")
            .update({
              cashfree_beneficiary_added: true,
              cashfree_beneficiary_status: "active",
              cashfree_beneficiary_response: responseJson,
              updated_at: new Date().toISOString(),
            })
            .eq("id", payoutRecord.id);

          return Response.json(
            {
              success: true,
              message: "Payout details verified successfully",
              beneficiary_id: beneficiaryId,
            },
            { status: 200, headers: corsHeaders }
          );
        }

        // REUSE EXISTING BENEFICIARY on a genuine bank-details conflict (Bug 1 fix).
        // Cashfree's Get Beneficiary V2 supports lookup by bank_account_number + bank_ifsc
        // (not only by beneficiary_id) -- this is Cashfree's own documented recovery path for
        // exactly this conflict. Only attempted for bank_account payouts (the conflict message
        // itself names bank_account_number/bank_ifsc; UPI-only payouts have neither field to
        // look up with). No beneficiary is ever deleted here -- this only reads from Cashfree
        // and, if found, updates our own row to point at the real, already-registered
        // beneficiary_id instead of the locally-generated one that was never created.
        if (isBankDetailsConflict && accNum && ifsc) {
          try {
            const lookupHeaders: any = {
              "x-api-version": "2024-01-01",
              "x-client-id": cashfreeClientId,
            };
            if (cashfreeClientSecret) {
              lookupHeaders["x-client-secret"] = cashfreeClientSecret;
            }
            // ROOT CAUSE FIX: this account has Payouts 2FA enabled -- every call (including GET
            // reads, confirmed by create-rider-withdrawal's own status-sync GET call) requires the
            // RSA-OAEP X-Cf-Signature header, exactly like the Add/Delete Beneficiary calls above
            // in this same file. Without it, Cashfree rejects this lookup outright, it never
            // returns a reusable beneficiary, and execution silently fell through to the FAILURE
            // branch below -- which is why the conflict error was still reaching the user despite
            // this reuse logic existing.
            if (cashfreePublicKeyPEM && cashfreePublicKeyPEM.trim() !== "") {
              try {
                const lookupSignature = await generateSignature(cashfreeClientId, cashfreePublicKeyPEM);
                lookupHeaders["X-Cf-Signature"] = lookupSignature;
              } catch (sigError: any) {
                console.error("Failed to generate X-Cf-Signature for Get Beneficiary V2 lookup:", sigError);
              }
            }

            const lookupUrl = `${cashfreeBaseUrl}/beneficiary?bank_account_number=${encodeURIComponent(accNum)}&bank_ifsc=${encodeURIComponent(ifsc)}`;
            console.log(`Conflict detected -- looking up existing beneficiary via: ${lookupUrl}`);
            const lookupResponse = await fetch(lookupUrl, {
              method: "GET",
              headers: lookupHeaders,
            });
            const lookupText = await lookupResponse.text();
            let lookupJson: any = {};
            try {
              lookupJson = JSON.parse(lookupText);
            } catch (e) {
              console.error("Error parsing Get Beneficiary V2 response payload:", lookupText);
            }

            if (lookupResponse.status === 200 && lookupJson.beneficiary_id) {
              const existingStatus = lookupJson.beneficiary_status === "VERIFIED" ? "active" : "pending";
              console.log(`Found existing Cashfree beneficiary ${lookupJson.beneficiary_id} (status: ${lookupJson.beneficiary_status}) for these bank details -- reusing it instead of the unregistered ${beneficiaryId}.`);

              await supabase
                .from("rider_payout_accounts")
                .update({
                  beneficiary_id: lookupJson.beneficiary_id,
                  cashfree_beneficiary_added: true,
                  cashfree_beneficiary_status: existingStatus,
                  cashfree_beneficiary_response: lookupJson,
                  updated_at: new Date().toISOString(),
                })
                .eq("id", payoutRecord.id);

              return Response.json(
                {
                  success: true,
                  message: "Payout details verified successfully",
                  beneficiary_id: lookupJson.beneficiary_id,
                },
                { status: 200, headers: corsHeaders }
              );
            }

            console.log(`Get Beneficiary V2 lookup did not return a reusable beneficiary (status ${lookupResponse.status}) -- falling through to the standard failure response.`);
          } catch (lookupError) {
            console.error("Get Beneficiary V2 lookup failed:", lookupError);
          }
        }

        // FAILURE
        await supabase
          .from("rider_payout_accounts")
          .update({
            cashfree_beneficiary_added: false,
            cashfree_beneficiary_status: "failed",
            cashfree_beneficiary_response: responseJson,
            updated_at: new Date().toISOString(),
          })
          .eq("id", payoutRecord.id);

        return Response.json(
          {
            success: false,
            message: `Gateway Error: ${errorMessage}`,
            error_details: responseJson,
          },
          { status: response.status, headers: corsHeaders }
        );
      }
    } catch (fetchError: any) {
      console.error("HTTP client request to Cashfree API failed:", fetchError);
      
      await supabase
        .from("rider_payout_accounts")
        .update({
          cashfree_beneficiary_added: false,
          cashfree_beneficiary_status: "failed",
          cashfree_beneficiary_response: { error: fetchError.message || "Network request failed" },
          updated_at: new Date().toISOString(),
        })
        .eq("id", payoutRecord.id);

      return Response.json(
        {
          success: false,
          message: `Connection to payout gateway timed out: ${fetchError.message}`,
        },
        { status: 500, headers: corsHeaders }
      );
    }
  } catch (err: any) {
    console.error("Unhandled runtime exception in edge function:", err);
    return Response.json(
      {
        success: false,
        message: err.message || "Internal server error",
      },
      { status: 500, headers: corsHeaders }
    );
  }
});
