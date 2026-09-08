import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

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

    if (req.method === "GET") {
      console.log("GET Request received to sync pending withdrawals for user:", user.id);

      // Fetch pending/processing withdrawals for the user
      const { data: pendingWithdrawals, error: fetchError } = await supabase
        .from("rider_withdrawals")
        .select("*")
        .eq("user_id", user.id)
        .in("status", ["pending", "processing"]);

      if (fetchError) {
        console.error("Error fetching pending withdrawals:", fetchError);
        return Response.json(
          { success: false, message: `Failed to query withdrawals: ${fetchError.message}` },
          { status: 500, headers: corsHeaders }
        );
      }

      console.log(`Found ${pendingWithdrawals?.length || 0} pending/processing withdrawals to sync.`);

      const cashfreeClientId = Deno.env.get("CASHFREE_PAYOUT_CLIENT_ID");
      const cashfreeClientSecret = Deno.env.get("CASHFREE_PAYOUT_CLIENT_SECRET");
      const cashfreePublicKeyPEM = Deno.env.get("CASHFREE_PAYOUT_PUBLIC_KEY");
      const cashfreeEnv = Deno.env.get("CASHFREE_ENV") || "production";

      if (!cashfreeClientId) {
        console.error("Missing CASHFREE_PAYOUT_CLIENT_ID secret for sync!");
        return Response.json(
          { success: false, message: "Server configuration missing client ID for sync." },
          { status: 500, headers: corsHeaders }
        );
      }

      // WayDrop Cashfree hardening (payout 2FA fail-fast): this account has Payouts 2FA enabled --
      // the Get Transfer Status call below requires the RSA-OAEP X-Cf-Signature header derived from
      // this key (confirmed live: even GET reads are rejected without it). A missing/empty key
      // previously just omitted the header and let every pending withdrawal's status check fail
      // silently against Cashfree instead of surfacing a clear configuration error. No wallet
      // rollback is needed here -- this GET/sync path never deducts wallet balance itself, unlike
      // the POST Create Transfer path below. Never logs/returns the key value itself.
      if (!cashfreePublicKeyPEM || cashfreePublicKeyPEM.trim() === "") {
        console.error("Missing CASHFREE_PAYOUT_PUBLIC_KEY secret for sync!");
        return Response.json(
          { success: false, message: "Server configuration missing signing key for sync." },
          { status: 500, headers: corsHeaders }
        );
      }

      const isProduction = cashfreeEnv.toLowerCase() === "production";
      const cashfreeBaseUrl = isProduction
        ? "https://api.cashfree.com/payout"
        : "https://sandbox.cashfree.com/payout";

      let syncedCount = 0;

      if (pendingWithdrawals && pendingWithdrawals.length > 0) {
        // R10 perf fix: each withdrawal's Cashfree status check + DB write is independent (own
        // transfer_id, own withdrawal row, own try/catch that already swallows its own errors
        // without ever re-throwing) -- was previously awaited one at a time. Promise.all is safe
        // here specifically because nothing inside this body can escape its own try/catch, so
        // none of these promises can ever reject; behaviorally identical to Promise.allSettled in
        // this exact case. fail_withdrawal/complete_withdrawal's own `FOR UPDATE` row lock on
        // `riders` already serializes any concurrent wallet_balance writes for the same rider at
        // the DB layer, so this introduces no correctness risk -- only removes the artificial
        // serialization of independent Cashfree network round trips.
        await Promise.all(pendingWithdrawals.map(async (w) => {
          try {
            const getHeaders: any = {
              "x-api-version": "2024-01-01",
              "x-client-id": cashfreeClientId,
            };
            if (cashfreeClientSecret) {
              getHeaders["x-client-secret"] = cashfreeClientSecret;
            }

            // Generate signature if PEM key exists
            if (cashfreePublicKeyPEM && cashfreePublicKeyPEM.trim() !== "") {
              try {
                const signature = await generateSignature(cashfreeClientId, cashfreePublicKeyPEM);
                getHeaders["X-Cf-Signature"] = signature;
              } catch (sigError: any) {
                console.error(`Failed to generate signature for sync on ${w.transfer_id}:`, sigError);
              }
            }

            // Cashfree Payouts V2 "Get Transfer Status" is GET /transfers with
            // transfer_id as a query parameter -- NOT a /transfers/{id} path
            // segment. The path-segment form silently hits the wrong route and
            // Cashfree returns a 200 with an auth-layer error body instead of a
            // real transfer status.
            const getUrl = `${cashfreeBaseUrl}/transfers?transfer_id=${encodeURIComponent(w.transfer_id)}`;
            console.log(`Checking transfer status on Cashfree: ${getUrl}`);

            const response = await fetch(getUrl, {
              method: "GET",
              headers: getHeaders,
            });

            const responseText = await response.text();
            console.log(`Cashfree Status API for ${w.transfer_id} returned status ${response.status}: ${responseText}`);

            if (response.status === 200) {
              const responseJson = JSON.parse(responseText);
              const transferStatus = (responseJson.status || "PENDING").toLowerCase();

              let dbStatus = "pending";
              if (transferStatus === "success") {
                dbStatus = "success";
              } else if (transferStatus === "processing") {
                dbStatus = "processing";
              } else if (
                transferStatus === "failed" ||
                transferStatus === "rejected" ||
                transferStatus === "reversed" ||
                transferStatus === "cancelled" ||
                transferStatus === "error"
              ) {
                dbStatus = "failed";
              }

              if (dbStatus !== w.status) {
                console.log(`Status changed for ${w.transfer_id}: ${w.status} -> ${dbStatus}`);
                
                if (dbStatus === "failed") {
                  await supabase.rpc("fail_withdrawal", {
                    p_withdrawal_id: w.id,
                    p_error_response: responseJson,
                  });
                } else {
                  await supabase.rpc("complete_withdrawal", {
                    p_withdrawal_id: w.id,
                    p_cashfree_ref_id: responseJson.cf_transfer_id || null,
                    p_status: dbStatus,
                    p_response: responseJson,
                  });
                }
                syncedCount++;
              }
            } else if (response.status === 404) {
              // Cashfree has no record of this transfer, maybe it failed early or was never sent
              // After some time (e.g. 5 minutes), we can fail it locally to prevent funds from being permanently locked
              const timeDiffMs = Date.now() - new Date(w.created_at).getTime();
              if (timeDiffMs > 5 * 60 * 1000) {
                console.log(`Transfer ${w.transfer_id} not found on Cashfree after 5 mins. Failing locally...`);
                await supabase.rpc("fail_withdrawal", {
                  p_withdrawal_id: w.id,
                  p_error_response: { error: "Transfer not found on Cashfree after timeout" },
                });
                syncedCount++;
              }
            }
          } catch (itemError) {
            console.error(`Error syncing transfer ${w.transfer_id}:`, itemError);
          }
        }));
      }

      return Response.json(
        { success: true, message: `Synced ${syncedCount} withdrawals.`, synced_count: syncedCount },
        { status: 200, headers: corsHeaders }
      );
    }

    const body = await req.json();
    console.log("Create Rider Withdrawal payload received for user:", user.id, body);

    const amount = parseFloat(body.amount);
    if (isNaN(amount) || amount <= 0) {
      return Response.json(
        { success: false, message: "A valid positive withdrawal amount is required" },
        { status: 400, headers: corsHeaders }
      );
    }

    // Default transfer mode is banktransfer, but support upi if specified
    let transferMode = body.transfer_mode || "banktransfer";
    if (transferMode !== "banktransfer" && transferMode !== "upi") {
      return Response.json(
        { success: false, message: "Invalid transfer mode. Supported modes are 'banktransfer' or 'upi'" },
        { status: 400, headers: corsHeaders }
      );
    }

    // =========================================
    // ATOMICALLY CHECK BALANCE & INIT TRANSACTION
    // =========================================
    const { data: initData, error: initError } = await supabase.rpc(
      "initiate_withdrawal",
      { p_amount: amount, p_user_id: user.id }
    );

    if (initError) {
      console.error("Error invoking initiate_withdrawal RPC:", initError);
      return Response.json(
        { success: false, message: `Database transaction failed: ${initError.message}` },
        { status: 500, headers: corsHeaders }
      );
    }

    if (!initData.success) {
      return Response.json(
        { success: false, message: initData.message },
        { status: 400, headers: corsHeaders }
      );
    }

    const {
      withdrawal_id,
      transfer_id,
      beneficiary_id,
      upi_vpa
    } = initData;

    // Additional check: if user wants to withdraw via UPI but no UPI VPA was saved
    if (transferMode === "upi" && (!upi_vpa || upi_vpa.trim() === "")) {
      // Revert the transaction
      await supabase.rpc("fail_withdrawal", {
        p_withdrawal_id: withdrawal_id,
        p_error_response: { error: "Attempted UPI withdrawal but no UPI VPA is registered" },
      });

      return Response.json(
        { success: false, message: "No registered UPI ID found. Please update your payout details." },
        { status: 400, headers: corsHeaders }
      );
    }

    // =========================================
    // CASHFREE TRANSFERS INTEGRATION
    // =========================================
    const cashfreeClientId = Deno.env.get("CASHFREE_PAYOUT_CLIENT_ID");
    const cashfreeClientSecret = Deno.env.get("CASHFREE_PAYOUT_CLIENT_SECRET");
    const cashfreePublicKeyPEM = Deno.env.get("CASHFREE_PAYOUT_PUBLIC_KEY");
    const cashfreeEnv = Deno.env.get("CASHFREE_ENV") || "production";

    if (!cashfreeClientId) {
      console.error("Missing CASHFREE_PAYOUT_CLIENT_ID secret!");
      // Revert wallet balance
      await supabase.rpc("fail_withdrawal", {
        p_withdrawal_id: withdrawal_id,
        p_error_response: { error: "CASHFREE_PAYOUT_CLIENT_ID is not configured on the server" },
      });

      return Response.json(
        { success: false, message: "Server configuration missing. Withdrawal rolled back." },
        { status: 500, headers: corsHeaders }
      );
    }

    // WayDrop Cashfree hardening (payout 2FA fail-fast): this account has Payouts 2FA enabled --
    // the Create Transfer call below requires the RSA-OAEP X-Cf-Signature header derived from this
    // key, confirmed live in production. A missing/empty key previously just omitted the header and
    // let Cashfree reject the transfer with a generic gateway error. By this point
    // initiate_withdrawal() has already deducted the wallet balance, so this uses the exact same
    // fail_withdrawal() rollback path as the CLIENT_ID check immediately above -- no new wallet/
    // accounting mechanism, just the same existing safety net applied to this secret too. Never
    // logs/returns the key value itself.
    if (!cashfreePublicKeyPEM || cashfreePublicKeyPEM.trim() === "") {
      console.error("Missing CASHFREE_PAYOUT_PUBLIC_KEY secret!");
      // Revert wallet balance
      await supabase.rpc("fail_withdrawal", {
        p_withdrawal_id: withdrawal_id,
        p_error_response: { error: "CASHFREE_PAYOUT_PUBLIC_KEY is not configured on the server" },
      });

      return Response.json(
        { success: false, message: "Server configuration missing. Withdrawal rolled back." },
        { status: 500, headers: corsHeaders }
      );
    }

    const isProduction = cashfreeEnv.toLowerCase() === "production";
    const cashfreeBaseUrl = isProduction
      ? "https://api.cashfree.com/payout"
      : "https://sandbox.cashfree.com/payout";

    // Build the request body for standard V2 transfer API
    const cashfreeBody = {
      transfer_id: transfer_id,
      transfer_amount: amount,
      transfer_mode: transferMode === "upi" ? "upi" : "banktransfer", // banktransfer maps to IMPS/NEFT automatically
      beneficiary_details: {
        beneficiary_id: beneficiary_id,
      },
    };

    // Configure headers dynamically
    const headers: any = {
      "Content-Type": "application/json",
      "x-api-version": "2024-01-01",
      "x-client-id": cashfreeClientId,
    };

    if (cashfreeClientSecret) {
      headers["x-client-secret"] = cashfreeClientSecret;
    }

    // Generate cryptographic signature using Public Key PEM if configured
    if (cashfreePublicKeyPEM && cashfreePublicKeyPEM.trim() !== "") {
      try {
        console.log("Generating cryptographic signature for transfer using Public Key PEM...");
        const signature = await generateSignature(cashfreeClientId, cashfreePublicKeyPEM);
        headers["X-Cf-Signature"] = signature;
        console.log("X-Cf-Signature generated and bound to headers successfully.");
      } catch (sigError: any) {
        console.error("Failed to generate RSA-OAEP X-Cf-Signature:", sigError);
        // Rollback
        await supabase.rpc("fail_withdrawal", {
          p_withdrawal_id: withdrawal_id,
          p_error_response: { error: `Signature generation failed: ${sigError.message}` },
        });

        return Response.json(
          { success: false, message: `Signature Generation Error: ${sigError.message}. Balance refunded.` },
          { status: 500, headers: corsHeaders }
        );
      }
    }

    console.log(`Invoking Cashfree Transfers V2 API on: ${cashfreeBaseUrl}/transfers`);

    try {
      const response = await fetch(`${cashfreeBaseUrl}/transfers`, {
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

      console.log(`Cashfree Transfers API returned status: ${response.status}`, responseJson);

      if (response.status === 200 || response.status === 201) {
        // SUCCESS or RECEIVED/PENDING
        const transferStatus = (responseJson.status || "PENDING").toLowerCase();
        let dbStatus = "pending";
        if (transferStatus === "success") {
          dbStatus = "success";
        } else if (transferStatus === "processing") {
          dbStatus = "processing";
        } else if (
          transferStatus === "failed" ||
          transferStatus === "rejected" ||
          transferStatus === "reversed" ||
          transferStatus === "cancelled" ||
          transferStatus === "error"
        ) {
          dbStatus = "failed";
        }

        if (dbStatus === "failed") {
          // Cashfree reported failure inside a 200 response (e.g. business validation)
          console.log("Transfer rejected by Cashfree partner validation. Rolling back...");
          await supabase.rpc("fail_withdrawal", {
            p_withdrawal_id: withdrawal_id,
            p_error_response: responseJson,
          });

          return Response.json(
            {
              success: false,
              message: responseJson.status_description || "Transaction was rejected by payment gateway.",
              error_details: responseJson,
            },
            { status: 400, headers: corsHeaders }
          );
        }

        // Update database with success/pending
        await supabase.rpc("complete_withdrawal", {
          p_withdrawal_id: withdrawal_id,
          p_cashfree_ref_id: responseJson.cf_transfer_id || null,
          p_status: dbStatus,
          p_response: responseJson,
        });

        return Response.json(
          {
            success: true,
            message: `Withdrawal initiated successfully! Status: ${transferStatus.toUpperCase()}`,
            transfer_id: transfer_id,
            cashfree_reference_id: responseJson.cf_transfer_id,
            status: dbStatus,
          },
          { status: 200, headers: corsHeaders }
        );
      } else {
        // HTTP Error (400, 422, 500 etc) -> Rollback immediately
        const errorMessage = responseJson.message || "Partner connection failed";
        console.log(`Cashfree responded with error status: ${response.status}. Reverting transaction...`);

        await supabase.rpc("fail_withdrawal", {
          p_withdrawal_id: withdrawal_id,
          p_error_response: responseJson,
        });

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
      
      // Rollback on network failure
      await supabase.rpc("fail_withdrawal", {
        p_withdrawal_id: withdrawal_id,
        p_error_response: { error: fetchError.message || "Network request failed" },
      });

      return Response.json(
        {
          success: false,
          message: `Connection to payout gateway timed out: ${fetchError.message}. Balance refunded.`,
        },
        { status: 500, headers: corsHeaders }
      );
    }
  } catch (err: any) {
    console.error("Unhandled runtime exception in withdrawal edge function:", err);
    return Response.json(
      {
        success: false,
        message: err.message || "Internal server error",
      },
      { status: 500, headers: corsHeaders }
    );
  }
});
