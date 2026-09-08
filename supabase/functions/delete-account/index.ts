import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// =====================================================
// Account Deletion (server-authoritative)
// =====================================================
// ARCHITECTURE (see 20260802000000/20260803000000_kyc_evidence_retention_on_deletion.sql for the
// full audit/design rationale):
//   1. Identity is derived from the caller's own JWT -- never a client-supplied user_id.
//   2. All DATABASE anonymization/hard-delete work happens inside delete_own_account(), a
//      SECURITY DEFINER RPC that uses auth.uid() internally -- called here through a client
//      scoped to the CALLER's own JWT, so even this edge function cannot make it act on anyone
//      else's account.
//   3. STORAGE object cleanup requires the service-role client -- only this function has that
//      credential, never the Flutter client. KYC documents specifically (Aadhaar/PAN/DL/RC/rider
//      photo/vehicle photo) are ARCHIVED, not deleted outright: copied into the private,
//      admin/support-only kyc_retention_archive bucket at the same relative path, then removed
//      from the public rider_kyc bucket -- so a Drop Partner can no longer destroy the identity
//      evidence a later fraud/safety/legal investigation would need simply by deleting their
//      account, while ordinary app users/the deleted account itself still have zero access to it
//      (storage RLS on kyc_retention_archive is admin/support SELECT only -- see the migration).
//      Passenger profile photo and the driver's personal UPI QR are still plain-deleted (not
//      identity/KYC evidence, out of scope for this fix).
//   4. AUTH: the account is never hard-deleted (public.users.id has ON DELETE CASCADE FROM
//      auth.users, but orders.user_id has ON DELETE RESTRICT -- so deleting the auth user would
//      be rejected by Postgres for any account with order history). Instead: permanently ban
//      the auth user (blocks all future sign-in) and revoke every existing session (blocks
//      continued use of an already-issued token) -- functionally equivalent to "account gone"
//      without violating the RESTRICT constraint. The real phone number is reassigned to a
//      generated placeholder (see the auth-update block below for why -- GoTrue silently ignores
//      an empty-string phone/email update) so it is genuinely freed for a fresh signup later.
//
// Idempotent: delete_own_account() short-circuits if already completed; storage archival/removal
// and the auth ban/signout are all safe to repeat (re-archiving/removing already-gone objects,
// banning an already-banned user, regenerating the same deterministic phone placeholder).
// =====================================================

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
    const serviceRoleKey = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS")!)["default"];

    // =====================================================
    // AUTH -- derive identity from the caller's own JWT.
    // =====================================================
    const authHeader = req.headers.get("Authorization");
    const token = authHeader?.replace("Bearer ", "");
    if (!token) {
      return Response.json(
        { success: false, message: "Missing auth token" },
        { status: 401, headers: corsHeaders },
      );
    }

    // Scoped to the caller's own JWT -- delete_own_account()'s auth.uid() is bound to this
    // token, so this can never be tricked into deleting a different account.
    const supabaseUser = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authHeader! } },
    });

    const { data: authData, error: authError } = await supabaseUser.auth.getUser(token);
    if (authError || !authData.user) {
      return Response.json(
        { success: false, message: "Unauthorized" },
        { status: 401, headers: corsHeaders },
      );
    }
    const userId = authData.user.id;

    // =====================================================
    // 1. DATABASE: anonymize/hard-delete via the auth.uid()-bound RPC.
    // =====================================================
    const { data: rpcResult, error: rpcError } = await supabaseUser.rpc("delete_own_account");

    if (rpcError || !rpcResult || rpcResult.success !== true) {
      console.error("delete_own_account RPC failed:", rpcError, rpcResult);
      // BUG FIX: delete_own_account() can now return code: "ACTIVE_ORDER_EXISTS" (see
      // 20260819000000_block_delete_account_during_active_order.sql) -- a genuine client-state
      // conflict, not a server error, so it gets 409 like every other conflict response in this
      // codebase (e.g. accept-order/boost-order-fare). Every other rpcResult failure (auth,
      // DELETE_FAILED) is unchanged, still 500.
      const isActiveOrderBlock = rpcResult && rpcResult.code === "ACTIVE_ORDER_EXISTS";
      return Response.json(
        {
          success: false,
          code: rpcResult && typeof rpcResult.code === "string" ? rpcResult.code : undefined,
          message:
            (rpcResult && typeof rpcResult.message === "string" && rpcResult.message) ||
            "Failed to delete account. Please try again.",
        },
        { status: isActiveOrderBlock ? 409 : 500, headers: corsHeaders },
      );
    }

    // =====================================================
    // 2. STORAGE cleanup (service-role only -- never exposed to Flutter).
    // =====================================================
    const supabaseAdmin = createClient(supabaseUrl, serviceRoleKey);

    const removeAllUnderPrefix = async (bucket: string, prefix: string) => {
      try {
        const { data: files, error: listError } = await supabaseAdmin.storage
          .from(bucket)
          .list(prefix, { limit: 1000 });
        if (listError) {
          console.error(`Storage list failed for ${bucket}/${prefix}:`, listError);
          return;
        }
        if (files && files.length > 0) {
          const paths = files.map((f: { name: string }) => `${prefix}/${f.name}`);
          await supabaseAdmin.storage.from(bucket).remove(paths);
        }
      } catch (e) {
        console.error(`Storage cleanup failed for ${bucket}/${prefix}:`, e);
      }
    };

    // KYC identity-evidence fix: archive every object under this prefix into the private,
    // admin/support-only kyc_retention_archive bucket (same relative path) BEFORE removing it
    // from the public rider_kyc bucket -- download+upload rather than a same-request storage
    // "copy" call, since a cross-bucket copy is not reliably available across supabase-js
    // versions and this must not silently fail to preserve evidence. Best-effort per file: a
    // single file failing to archive/remove is logged and does not abort the rest of the
    // deletion (the DB-side identity fields are already safely archived by the RPC regardless).
    const archiveAndRemoveAllUnderPrefix = async (bucket: string, prefix: string) => {
      try {
        const { data: files, error: listError } = await supabaseAdmin.storage
          .from(bucket)
          .list(prefix, { limit: 1000 });
        if (listError) {
          console.error(`Storage list failed for ${bucket}/${prefix}:`, listError);
          return;
        }
        if (!files || files.length === 0) return;

        for (const f of files) {
          const path = `${prefix}/${f.name}`;
          try {
            const { data: blob, error: downloadError } = await supabaseAdmin.storage
              .from(bucket)
              .download(path);
            if (downloadError || !blob) {
              console.error(`Archive download failed for ${bucket}/${path}:`, downloadError);
              continue; // do not delete the original if the archive copy did not succeed
            }
            const { error: uploadError } = await supabaseAdmin.storage
              .from("kyc_retention_archive")
              .upload(path, blob, { upsert: true });
            if (uploadError) {
              console.error(`Archive upload failed for kyc_retention_archive/${path}:`, uploadError);
              continue;
            }
            await supabaseAdmin.storage.from(bucket).remove([path]);
          } catch (e) {
            console.error(`Archive-and-remove failed for ${bucket}/${path}:`, e);
          }
        }
      } catch (e) {
        console.error(`Storage archival failed for ${bucket}/${prefix}:`, e);
      }
    };

    // rider_kyc: covers every uploaded identity document (all paths live under {user_id}/... per
    // rider_kyc_upload_service.dart's generateAttemptFolder, including add_vehicle_screen.dart's
    // {user_id}/vehicles/... uploads -- same prefix, one listing) -- archived, not deleted.
    await archiveAndRemoveAllUnderPrefix("rider_kyc", userId);
    // Passenger profile photo, if ever set -- not identity/KYC evidence, plain delete unchanged.
    await removeAllUnderPrefix("user_profile_photos", userId);
    // Driver's uploaded Personal UPI QR -- keyed by riders.id, not identity/KYC evidence, plain
    // delete unchanged.
    if (rpcResult.had_rider_profile && rpcResult.rider_id) {
      await removeAllUnderPrefix("driver_personal_qr", String(rpcResult.rider_id));
    }

    // =====================================================
    // 3. AUTH: permanently ban + revoke all sessions. Never auth.admin.deleteUser() -- see
    // header comment for why that would fail outright for any account with order history.
    //
    // SAME-PHONE RE-REGISTRATION FIX (root cause, confirmed against the supabase/auth source,
    // not assumed): GoTrue's admin update-user handler (internal/api/admin.go) only touches the
    // phone/email columns when the incoming value is non-empty --
    //   `if params.Phone != "" { params.Phone, err = validatePhone(params.Phone); ...
    //     user.SetPhone(tx, params.Phone) }`
    // -- so writing phone: "" (as this code previously did) is SILENTLY IGNORED: the real phone
    // number stays on this now-permanently-banned auth user forever. Every later signInWithOtp()
    // for that same phone then resolves back to THIS banned identity (GoTrue's SmsOtp handler
    // looks the user up by phone with no ban check, so OTP send still succeeds), and only fails
    // at verifyOtp() once GoTrue's IsBanned() check rejects issuing a session -- reproducing
    // exactly the reported "OTP send succeeds, verify fails" symptom, with no new auth identity
    // ever created. Fix: actually change the phone to a value GoTrue will accept, so the real
    // number is freed for a genuinely new signup. Any non-empty value must itself pass GoTrue's
    // E.164 check (internal/api/phone.go: `^[1-9][0-9]{1,14}$`), so a placeholder is generated
    // here rather than left blank -- deterministic from this user's own UUID (idempotent across
    // retries) and fixed at 15 digits, a length no real number this app ever submits (+91 plus a
    // 10-digit mobile = 12 digits) can ever match, so it can never collide with a genuine future
    // phone number. email is left as "" (unchanged, same silent no-op) -- this app is phone-OTP
    // only, so auth.users.email is never populated in the first place and freeing it has no
    // effect on any real flow.
    const phonePlaceholder = (() => {
      const hex = userId.replace(/-/g, "");
      const digits = [...hex].map((c) => parseInt(c, 16) % 10).join("");
      return `9${digits.slice(0, 14)}`;
    })();

    try {
      await supabaseAdmin.auth.admin.updateUserById(userId, {
        phone: phonePlaceholder,
        email: "",
        // Supabase's admin API has no literal "forever" duration; ~100 years is the
        // documented workaround for an effectively-permanent ban.
        ban_duration: "876600h",
      });
    } catch (e) {
      console.error("Failed to ban auth user (non-fatal -- DB data is already anonymized):", e);
    }

    try {
      // scope 'global' revokes every refresh token for this user, not just the current session.
      await supabaseAdmin.auth.admin.signOut(token, "global");
    } catch (e) {
      console.error("Failed to revoke sessions (non-fatal):", e);
    }

    return Response.json(
      { success: true, message: "Account deleted." },
      { headers: corsHeaders },
    );
  } catch (e) {
    console.error("delete-account error:", e);
    return Response.json(
      { success: false, message: "Internal server error" },
      { status: 500, headers: corsHeaders },
    );
  }
});
