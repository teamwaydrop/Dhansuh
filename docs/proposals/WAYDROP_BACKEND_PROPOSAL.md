# Waydrop backend proposals — 31 October 2026

Production was inspected read-only. No migration, function deployment, policy deletion, user backfill, order mutation or payment operation was performed.

## Approval package

`waydrop_security_review.sql` and `waydrop_promo_ownership_review.sql` are exact SQL proposals, outside `supabase/migrations/`. Both end in `ROLLBACK`. They have now been exercised in a disposable PostgreSQL 18.6/PGlite synthetic schema (52 authorization scenarios; see `../WAYDROP_LOCAL_SECURITY_TEST_RESULTS.json`). They have not been applied to a full Supabase staging clone or production. Internal RPC bodies in the harness are ACL fixtures, so dispatch, cron, payments and withdrawals still require full staging regression checks. Review current object definitions against the saved catalog before converting either proposal into an approved migration. Existing triggers and policies are retained.

| Finding | Catalog evidence | Proposed action | Staging acceptance |
|---|---|---|---|
| Anonymous compliance/security disclosure | `parcel_compliance_view` and `parcel_security_timeline_view` grant SELECT to anon/authenticated, are owned by bypass-RLS postgres, and have no invoker option. Definitions include phone, IP/device/location and security-event data. | Revoke application-role SELECT; preserve service-role access. No Flutter consumers found. | anon and ordinary accounts denied; authorized operational tooling still works. |
| Profile INSERT privilege escalation | `Users can insert own profile` constrains id only; authenticated can INSERT role/is_developer. `trigger_prevent_role_self_escalation` runs BEFORE UPDATE only. | New INSERT guard allows ordinary profile defaults; existing UPDATE role guard stays. Also protect suspension from owner changes. | Own ordinary profile creation succeeds; supplied admin/support/developer flags and owner unsuspension fail. |
| Client can write KYC decision fields | Owner UPDATE policy, column permissions on kyc_status/activation_status, and no decision guard. Existing trigger creates the rider profile after approval/activation; it does not authorize those decisions. | Additional decision-field trigger; legitimate approval/resubmission through existing service-role Edge Functions; preserve existing RLS-authorized, unsuspended admin/support review. | Direct self-approval/activation/unblocking fails; existing review, rejection and resubmission flows succeed. |
| Client can insert active payout status | Owner INSERT policy permits Cashfree active status. Existing protection covers UPI verification, not Cashfree activation. | Guard server-assigned Cashfree beneficiary status. | Pending setup and server-confirmed activation succeed; fabricated active insert fails. |
| Internal privileged RPCs callable anonymously | Exact EXECUTE grants and bodies show scheduler/dispatch/notification routines without caller checks. | Revoke seven specified signatures from PUBLIC/anon/authenticated; retain service_role and definer/cron operation. | Direct client calls denied; cron, freed-rider rematching, dispatch and notifications unaffected. |
| Promo check accepts arbitrary p_user_id | `validate_and_calculate_promo(varchar,numeric,uuid)` is authenticated-executable and trusts its argument for audience and usage checks. Final create-order pricing uses server identity separately. | Require auth.uid() to match supplied id for user sessions; retain service-role caller behavior and all original pricing rules. | Same-account checks work; other-account checks fail; server-created order totals unchanged. |
| Mutable search paths | 33 routines total; seven SECURITY DEFINER routines identified in the proposal. Public schema CREATE is denied to anon/authenticated. | Pin seven privileged paths to public,pg_temp; exercise extension/type resolution before approval. Remaining invoker routines need per-object review. | Normal pricing, OTP, withdrawals and expiry complete; no search-path name substitution. |

These are verified permission/definition gaps, not production exploit demonstrations. No exploit with writes was attempted. For KYC activation, the existing rider INSERT policy may additionally constrain the AFTER trigger; this does not make mutable approval fields safe. Evaluate end-to-end impact on a disposable database.

Seven advisor-flagged views are listed in `../WAYDROP_ADVISORS_2026-10-31.json`. The other five have business-facing aggregate/directory uses. Do not blindly change all views to invoker security: matching/tracking may rely on deliberate cross-account visibility. Define and test each intended audience first. The settlement summary has no anon/authenticated SELECT and is not equivalent to the exposed views.

69 anon-executable and 90 authenticated-executable definer functions are not 159 distinct exploits: the sets overlap; many routines return trigger and cannot be invoked as ordinary RPCs. The complete 113-function inventory and RLS definitions are saved in `../WAYDROP_BACKEND_CATALOG_2026-10-31.json`. Twenty same-role overlapping permissive policy groups were counted; the earlier 22 advisor count can include role overlap. Ownership predicates were reviewed; missing explicit WITH CHECK alone was not treated as proof of an ownership bypass.

## GPS bridge: retain the current contract

Live definitions confirm `riders` UPDATE → `sync_riders_gps_to_rider_locations()` UPSERT → `check_rider_near_destination_from_rider_locations()` order lookup and conditional push. Matching helpers still read coordinates from `riders`. A direct client switch to `rider_locations` would violate both permissions and data-consumer assumptions.

No executable GPS migration is proposed without staging measurements. The next bounded experiment is:

1. On a production-like staging clone, collect `EXPLAIN (ANALYZE, BUFFERS)` for representative stationary and moving rider updates, including trigger timings. Never run write-bearing EXPLAIN ANALYZE on production for this investigation.
2. Inventory every coordinate/freshness reader, including dispatch, `get-live-order-status`, active-order views and location realtime consumers.
3. If bridge costs dominate, design an authenticated ownership-bound RPC that accepts coordinates/heading only, derives the rider from auth.uid(), validates bounds and online eligibility, and maintains every required freshness/dispatch input. Deny arbitrary rider ids, financial columns and offline availability changes. Set a fixed search path and explicit EXECUTE grants.
4. Only after consumers have a compatible contract should a migration change the authoritative write table or bridge. Preserve proximity notification idempotency and the current 30-second dispatch freshness heartbeat.
5. Replay stationary/moving, offline, reconnect, active delivery, destination arrival and concurrent account-change tests. Compare trigger time and writes/minute, then obtain production approval.

The Flutter fix retains the 10 m movement gate, 30 s heartbeat and active-order map stream. Its new counter measures completed HTTP write requests, not affected rows or database-trigger invocations.

## Query/index findings

`idx_notifications_user_id_is_read` already supports unread counts. A read-only EXPLAIN ANALYZE sample used it via Index Only Scan (130 qualifying rows, 91 heap fetches; total execution 64.678 ms). This was a privileged SQL-session sample, including an InitPlan to select a cohort, not the authenticated PostgREST request or a before/after benchmark. No duplicate unread index is justified by this plan.

A read-only projected assignment/order join sample took 0.235 ms and returned no matching pending rows. It does not establish performance for busy riders. Historical pg_stat_statements still contains matching RPC mean 228.46 ms, unread query 97.36 ms and assignment join 30.15 ms for particular entries. Different entries/roles/plans must not be combined into mobile latency claims. Current exact plans, index definitions and stats are saved alongside the report.

Do not execute matching/scheduler RPCs to obtain timings on production: several can dispatch, notify or mutate. Use staging for function-level EXPLAIN ANALYZE. No new index or nested-join rewrite has been proposed without representative evidence.

## Edge authentication review

Downloaded deployed versions: create-rider-withdrawal v20, create-rider-payout v30, create-payment v64, create-rider-kyc v51, validate-rider-kyc v41, send-push-notification v24 and cashfree-webhook v43. The first six use auth.getUser/token or an explicit trusted-server path; payment/payout/withdrawal identity is bound to the user. KYC functions reject a body.user_id mismatch. The webhook validates the raw body signature. `verify_jwt=false` alone is not an issue for these implementations. Exact identity-check line references are in `../WAYDROP_EDGE_AUTH_REVIEW_2026-10-31.json`.

This is a source review of seven sensitive deployments, not a penetration test or an audit of all 27 deployed functions. The remaining deployments and provider webhook replay/financial concurrency tests remain open. Existing rider financial-column protection and service-only withdrawal-finalization permissions were confirmed, and were not removed.

## Profile mismatch

Auth users 174; public profiles 127; missing 47; profiles without Auth users 0. Missing groups: 26 anonymous signed-in accounts, 18 unconfirmed never-signed-in accounts, 3 confirmed signed-in accounts. No Auth-users profile-creation trigger exists. This supports incomplete onboarding as a plausible cause, not a decision to backfill all accounts. Confirm product policy and the three confirmed accounts with an authorized administrator before any data repair. No user identities are included in the evidence or report.
