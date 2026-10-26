import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

import { KycReferenceReadError, readKycReferences } from "../_shared/kyc_cleanup_references.ts";

const supabaseAdmin = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

// =====================================================
// CLEANUP ABANDONED KYC UPLOADS
//
// Part of the incremental rider-KYC-upload redesign (each document now uploads to storage the
// instant it's picked, not batched at Final Submit -- see rider_kyc_screen.dart / kyc_upload_state.dart).
// A user who picks some documents and never completes Final Submit leaves real, durable files in
// the `rider_kyc` bucket with nothing to ever clean them up. This runs on a schedule (see the
// companion migration's pg_cron entry, following the existing dormant-rider/intercity-expiry
// pattern) and does two distinct things per session folder:
//
//   1. UNCLAIMED folders (never reached a successful create-rider-kyc submission): deletes the
//      whole folder once nothing in it has been touched for a full grace period.
//   2. CLAIMED folders (referenced by a submitted rider_kyc row): never deleted wholesale, but
//      each upload writes to a path suffixed with its own pickGeneration (see
//      rider_kyc_upload_service.dart), so re-picking a slot before settling on a final image
//      leaves earlier generations' objects behind. Those are pruned individually, regardless of
//      the grace period, since they can never become referenced later once the folder is claimed.
//
// No separate tracking table: a claimed session's folder -- and, for pruning, each individual
// object's own path -- is already a substring of one of that user's rider_kyc image columns once
// create-rider-kyc succeeds -- that's the single source of truth here, so there's nothing else to
// keep in sync.
//
// Session folders are named `{phone}_attempt_{N}` or `{phone}_attempt_{N}_{randomSuffix}` --
// requiring the literal `_attempt_` marker is what safely excludes add_vehicle_screen.dart's
// sibling folders (`{user_id}/vehicles/{millis}/...`), so this job structurally never touches
// that unrelated, already-approved-rider flow.
//
// Deletion goes through the Storage API (`.remove()`), not raw SQL against storage.objects --
// a SQL DELETE there would only remove Postgres metadata, not the underlying stored bytes.
// =====================================================

const BUCKET = "rider_kyc";
const GRACE_PERIOD_MS = 7 * 24 * 60 * 60 * 1000; // 7 days -- matches rider_kyc.blocked_until's existing cooldown length

// Every image field a submitted rider_kyc row can hold. Each upload's storage path is suffixed
// with its own pickGeneration (see rider_kyc_upload_service.dart), so re-picking a slot before
// settling on a final image leaves earlier generations' objects behind once the folder is
// eventually submitted -- unreferenced by any of these fields, and (unlike an unclaimed folder)
// guaranteed to never become referenced later, since kyc_status pending/under_review/resubmitted
// blocks the client from ever re-entering the picker for this same attempt/folder again.
const IMAGE_FIELDS = [
  "rider_image",
  "aadhaar_front_image",
  "aadhaar_back_image",
  "pan_front_image",
  "pan_back_image",
  "license_front_image",
  "license_back_image",
  "vehicle_image",
  "VECHILE_RC_front_image",
  "VECHILE_RC_back_image",
] as const;

// Cheap defense-in-depth, distinct from GRACE_PERIOD_MS: only prune an unreferenced object once
// it's had a little time to settle, so a same-instant edge case can never race a fresh write.
const OBSOLETE_VERSION_MIN_AGE_MS = 60 * 60 * 1000; // 1 hour

function isSessionFolderName(name: string): boolean {
  return /_attempt_\d+/.test(name);
}

// Storage `.list()` caps out at `limit` per call with no built-in "give me everything" mode --
// callers must page via `offset` themselves. Listing only the first page (as this job originally
// did) silently stops scanning once the bucket has more than one page of top-level user folders,
// which is guaranteed well before 100,000 users: every folder past the first page is then never
// scanned or cleaned, permanently, with no error ever surfaced.
async function listAllPages(prefix: string): Promise<{ id: string | null; name: string }[]> {
  const pageSize = 1000;
  const all: { id: string | null; name: string }[] = [];
  let offset = 0;
  while (true) {
    const { data, error } = await supabaseAdmin.storage
      .from(BUCKET)
      .list(prefix, { limit: pageSize, offset });
    if (error) throw error;
    if (!data || data.length === 0) break;
    all.push(...data);
    if (data.length < pageSize) break;
    offset += pageSize;
  }
  return all;
}

serve(async (req) => {
  // This performs a privileged, bucket-wide sweep using the service-role client -- it must only
  // ever run as the internal pg_cron trigger (which authenticates with the vaulted service-role
  // key, see the companion migration), never as an ordinary signed-in app user. Supabase's platform
  // `verify_jwt` gate alone is insufficient here: it accepts ANY authenticated user's own session
  // JWT, not just the service-role key, so without this explicit check any rider/passenger could
  // invoke this endpoint directly and force a full-bucket scan on demand -- the same check
  // send-push-notification/index.ts already uses for its own internal-trigger path.
  const token = req.headers.get("Authorization")?.replace("Bearer ", "");
  if (token !== Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")) {
    return new Response(JSON.stringify({ error: "Forbidden" }), { status: 403 });
  }

  try {
    let userEntries: { id: string | null; name: string }[];
    try {
      userEntries = await listAllPages("");
    } catch (listUsersError: any) {
      console.error("[CleanupKyc] Failed to list bucket root:", listUsersError);
      return new Response(JSON.stringify({ error: listUsersError.message }), { status: 500 });
    }

    let deletedFolders = 0;
    let deletedObjects = 0;
    let prunedObsoleteVersions = 0;

    for (const userEntry of userEntries ?? []) {
      if (userEntry.id !== null) continue; // an actual file at bucket root, not a user folder -- skip
      const userId = userEntry.name;

      let sessionEntries: { id: string | null; name: string }[];
      try {
        sessionEntries = await listAllPages(userId);
      } catch (listSessionsError) {
        console.error(`[CleanupKyc] Failed to list folders for user ${userId}:`, listSessionsError);
        continue;
      }

      for (const sessionEntry of sessionEntries ?? []) {
        if (sessionEntry.id !== null) continue; // a file directly under the user folder, not a session
        if (!isSessionFolderName(sessionEntry.name)) continue; // e.g. "vehicles" -- out of scope

        const fullFolder = `${userId}/${sessionEntry.name}`;

        const { data: objects, error: listObjectsError } = await supabaseAdmin.storage
          .from(BUCKET)
          .list(fullFolder, { limit: 100 });

        if (listObjectsError || !objects || objects.length === 0) continue;

        let referencedValues: string[];
        try {
          referencedValues = await readKycReferences(() => supabaseAdmin
            .from("rider_kyc")
            .select(IMAGE_FIELDS.join(","))
            .eq("user_id", userId)
            .maybeSingle(), IMAGE_FIELDS);
        } catch (error) {
          const category = error instanceof KycReferenceReadError ? error.category : "query_exception";
          console.error(`[CleanupKyc] Reference check skipped category=${category}`);
          continue; // Neither whole-folder deletion nor generation pruning is authorized.
        }

        const claimed = referencedValues.some((v) => v.includes(fullFolder));

        if (claimed) {
          // The folder as a whole is the active submission's folder -- never reap it wholesale.
          // But any object inside it that isn't one of the row's CURRENT field values is a
          // leftover from an earlier re-pick that was superseded before the user's final choice
          // for that slot, and can never become referenced later (see IMAGE_FIELDS comment above),
          // so it's safe to prune regardless of the 7-day grace period, which governs whole-folder
          // abandonment, not this.
          const obsolete = objects.filter((o) => {
            const objectPath = `${fullFolder}/${o.name}`;
            if (referencedValues.some((v) => v.includes(objectPath))) return false;
            const ageMs = o.created_at ? Date.now() - new Date(o.created_at).getTime() : Infinity;
            return ageMs >= OBSOLETE_VERSION_MIN_AGE_MS;
          });

          if (obsolete.length > 0) {
            const obsoletePaths = obsolete.map((o) => `${fullFolder}/${o.name}`);
            const { error: removeError } = await supabaseAdmin.storage.from(BUCKET).remove(obsoletePaths);
            if (removeError) {
              console.error(`[CleanupKyc] Failed to prune obsolete versions in ${fullFolder}:`, removeError);
            } else {
              prunedObsoleteVersions += obsoletePaths.length;
            }
          }
          continue;
        }

        // Use the NEWEST object's timestamp, not the oldest. A session is only "abandoned" once
        // nothing has been added to it for a full grace period. Gating on the oldest object would
        // delete the whole folder -- including files uploaded minutes ago -- the moment the first
        // document a user ever picked crosses 7 days old, even if they're actively resuming and
        // adding new documents to the same still-unclaimed session (a scenario the client's resume
        // flow explicitly supports indefinitely, since it never expires a session by elapsed time).
        const newestMs = objects.reduce((max, o) => {
          const t = o.created_at ? new Date(o.created_at).getTime() : 0;
          return t > max ? t : max;
        }, 0);

        if (Date.now() - newestMs < GRACE_PERIOD_MS) continue; // still within the grace period

        const objectPaths = objects.map((o) => `${fullFolder}/${o.name}`);
        const { error: removeError } = await supabaseAdmin.storage.from(BUCKET).remove(objectPaths);

        if (removeError) {
          console.error(`[CleanupKyc] Failed to remove ${fullFolder}:`, removeError);
          continue;
        }

        deletedFolders++;
        deletedObjects += objectPaths.length;
      }
    }

    return new Response(
      JSON.stringify({ success: true, deletedFolders, deletedObjects, prunedObsoleteVersions }),
      { headers: { "Content-Type": "application/json" } },
    );
  } catch {
    console.error("[CleanupKyc] Unexpected error category=cleanup_failure");
    return new Response(
      JSON.stringify({ error: "Internal server error", details: "cleanup_failure" }),
      { status: 500 },
    );
  }
});
