# Rider access request ownership — 2 November 2026

This local follow-up removes a demonstrated request amplifier during backend degradation. It does not establish the initiating November database resource cause or resolve the independently confirmed Storage DatabaseTimeout. No production queries, changes, deployments, paid resources or new cloud projects were used in this batch.

## Reproduction and correction

`RiderAccessService.resolve()` previously released its shared request when the eight-second presentation timeout expired. Dart's timeout does not cancel the HTTP operation. A second entry/retry therefore started another KYC/rider read while the original request was still running. The same defect affected a timed-out payout read. Signing out while the initial reads were pending also allowed a late, unnecessary payout request before the final identity check.

The reproduction uses the actual pinned Supabase Flutter client with an HTTP MockClient and controlled response gates, rather than a separate model of the algorithm. Five tests against the saved original implementation produced **2 passes / 3 expected failures**. The failing assertions observed two rider/KYC request pairs instead of one, repeated profile work during a pending payout read, and one payout request after sign-out instead of zero. Original source and baseline log are retained at `.dart_tool/waydrop-local-runtime/access-owner.before.dart` and `access-owner-before.log`.

Implementation: `lib/core/services/session/rider_access_service.dart`:

- Lines 23–28: an individual request owner records pending raw reads and completion of its visible result.
- Lines 70–89: same-account, same-credential callers share the result. Renewed credentials can start fresh validation; the credential is private in-memory identity only, never logged or persisted.
- Lines 92–111: release requires both the visible result and raw reads to settle, plus identity equality with the current owner. Completing an older request cannot clear its replacement. Lazy PostgREST builders are materialized once through `Future.sync`, avoiding an extra transport execution when observing settlement.
- Lines 119–163: both profile reads and the payout read participate in ownership tracking. Existing projections, parallel profile reads and eight-second phase timeouts remain.
- Lines 143–145 and 171–173: account checks prevent a late payout request and a ready result after sign-out/account switch.

The eligibility decision table is unchanged. There is no successful eligibility-result cache: a later completed entry validates again. KYC, suspension, account status, payout and service-mode gates remain. Timed-out work cannot subsequently authorize entry or publish a successful result.

## Regression verification

`test/rider_access_request_ownership_test.dart` has six tests:

1. Profile timeout followed by retry keeps one actual request pair until transport settlement; a fresh retry afterwards works.
2. Payout timeout retains ownership and never turns a late response into ready access.
3. Five concurrent callers share one validation; completed work is revalidated on the next call.
4. Completed HTTP 503 releases ownership for a genuine fresh retry.
5. Paused old owner, timeout, credential renewal, replacement claim, old-owner completion, third caller: old cleanup cannot remove the replacement; the third caller joins it.
6. Sign-out during profile reads prevents the late payout read.

Focused result: **6 passed / 0 failed** (`access-owner-after.log`). The original baseline had five tests; the credential-replacement regression was added afterwards, so it is not counted in that baseline. Full Flutter suite: **2,153 passed / 0 failed**, previous 2,147 plus six new tests (`access-owner-full-flutter.log`). Analyzer on the changed service and new test: **no issues**, exit 0 (`access-owner-analyze.log`); this is not a new full-project analyzer result. Durable copies and source fingerprints are in [request-ownership-20261102/VERIFICATION.json](request-ownership-20261102/VERIFICATION.json).

## Measured scope and limitations

In the controlled timeout/retry case, initial KYC/rider requests fall from **two pairs to one pair** while the same transport is pending. During a held payout read, retry no longer starts a second profile pair or payout query. After sign-out, unnecessary payout requests fall **1 → 0**. These are actual SDK HTTP counts; no handset latency or project-wide request-rate reduction is inferred.

Transport cancellation is not introduced. A permanently hung request retains its timed-out result for the same credential, preventing uncontrolled duplicate work; retry becomes fresh after raw transport settlement or credential renewal. The UI still receives its bounded timeout. New credentials may overlap old raw reads intentionally, to avoid blocking renewed sessions. A refresh does not invalidate a healthy same-user validation's result; backend authorization remains authoritative.

AccountProfileService's manual-retry ownership and public Auth resume verification require separate evidence/tests and are not claimed fixed by this change. Backend wait time, Storage's unidentified timed-out SQL, host resource metrics and existing combined SQL/Edge rollout gates remain open.

## Release boundary

This correction is **local and after Build 58**; no new APK is built in this batch. Build 58 remains the artifact under user testing. No SQL, RLS, trigger, cron, Edge Function or configuration changes are required for this client correction. It can be included in the next reviewed APK after device feedback. Existing production candidate approvals and managed-integration gates remain unchanged.
