# Waydrop remaining device and staging verification

Status: required release work, not executed. Production Supabase has not been changed. The Android device inventory is empty in build/continuation_adb_devices.txt. Package ID is com.waydrop.app. Do not use the repository's production .env for this exercise.

## Reproduce local verification

From the project root in PowerShell, with the installed Flutter SDK on PATH:

```powershell
flutter pub get --offline
$waydropTests = @(rg --files test -g '*_test.dart' | Where-Object { $_ -notmatch '^(test[\\/])(pricing_dedup_regression_test|intercity_parcel_pricing_regression_test)\.dart$' })
flutter test --no-pub @waydropTests --reporter expanded
flutter analyze --no-pub
npm --prefix tools/waydrop-verification ci
npm --prefix tools/waydrop-verification test
git diff --check
```

The two named live-backend files are not executed by that offline command. They must be reviewed for target/credentials and run against an approved staging endpoint before release. No tests were disabled or marked skip.

## Physical Android profile procedure

Create a private staging.env file outside version control containing SUPABASE_URL, SUPABASE_ANON_KEY and OLA_MAPS_API_KEY for the approved staging deployment. Confirm provider sandbox configuration separately. Never paste service_role keys into Dart defines. Connect the authorized Android phone and enable USB debugging.

```powershell
adb devices -l
flutter devices
flutter run --profile -d <ANDROID_SERIAL> --dart-define-from-file=staging.env
# Keep this terminal attached for DevTools and PERF log timestamps.
# In a second terminal, select the SAME serial explicitly:
adb -s <ANDROID_SERIAL> shell cmd package resolve-activity --brief com.waydrop.app
adb -s <ANDROID_SERIAL> logcat -c
adb -s <ANDROID_SERIAL> logcat -v epoch > build/profile-device-log.txt
```

Copy the resolved activity into the launch command below (normally com.waydrop.app/.MainActivity; use the actual resolution). After the first profile run installs the build, capture ten process-cold starts for each signed-out, passenger and activated rider account. A force-stop preserves application/session data; do not use pm clear, which would change the scenario.

```powershell
adb -s <ANDROID_SERIAL> shell am force-stop com.waydrop.app
adb -s <ANDROID_SERIAL> shell am start -W -n com.waydrop.app/.MainActivity
# Repeat ten times, waiting for usable content and recording each sample.
# Warm foreground/resume: background with HOME without force-stop, then launch:
adb -s <ANDROID_SERIAL> shell input keyevent KEYCODE_HOME
adb -s <ANDROID_SERIAL> shell am start -W -n com.waydrop.app/.MainActivity
```

Android am start -W TotalTime/WaitTime are launch measurements, not proof of first usable Flutter content. Record PERF_PROCESS, PERF_STARTUP and PERF_HOME markers plus a DevTools timeline/screen recording. The usable event is the first rendered content that accepts the intended action with required data loaded; exclude splash, placeholder and loading skeleton. State explicitly whether permission dialogs are included. Measure ten warm resumes too. Export raw samples and p50/p95 for both runs, with device model, OS, refresh rate, Flutter revision, build hash, network, dataset, cache state and account role.

Compare an isolated pre-change checkout with this modified checkout using the identical staging data and SDK. Tracked HEAD is not a byte-for-byte copy of the initial dirty workspace; use the continuation snapshot for continuation-only comparisons, and disclose that limit for the earlier implementation. Do not reset this working directory to obtain a baseline.

In DevTools debugger evaluate apiMetricsClient?.totals before and after each flow, and apiMetricsClient?.requestsLastMinute after a steady minute. The wrapper is defined in main.dart and counts actual sends through its supplied HTTP client (including failures), not WebSocket frames, map-provider native traffic or SDK-internal bypasses. Record per-operation deltas; do not compare cumulative totals across different-length sessions. Record LocationCacheService.successfulLocationUploads deltas over exactly 60 seconds, stationary and moving, online, offline, active delivery and background. It counts successful HTTP requests, not trigger writes. Confirm actual backend rider coordinates and passenger position freshness on staging as well.

Use DevTools Performance recording for ten repetitions of tab switching, map pan, order accept/open/complete, reconnect and navigation. Export build/raster durations, p50/p95, missed-frame count and refresh-rate frame budget (16.67 ms at 60 Hz, 8.33 ms at 120 Hz). Reset recordings between scenarios. Attach timeline exports rather than judging smoothness by eye.

## Full Supabase staging acceptance

The local SQL harness uses PostgreSQL 18.6, while the saved production catalog is PostgreSQL 17. It executes the real proposal trigger and promo bodies against synthetic tables and representative RLS. Seven scheduler/dispatch/notification bodies and six other path-only routines are fixtures; their execution is not covered. A full isolated PostgreSQL 17 Supabase clone is still required. Provision it without production provider credentials, real FCM recipients or live payment callbacks.

1. Compare every named table, trigger, function overload, grant and policy with the saved catalog and current approved staging schema. Export staging schema/grants before testing. Verify ordinary clients lack CREATE on public, and verify auth.role()/auth.uid() under actual JWTs, not only SQL GUCs.
2. Execute each proposal as-is against that disposable staging clone using psql -v ON_ERROR_STOP=1 -f <proposal>. Each ends in ROLLBACK, so this validates compatibility without persisting changes. A second explicit staging transaction may install the reviewed proposal for app/API tests only after the target has been confirmed as the isolated clone; do not replace ROLLBACK in the production copy or create an auto-applied migration.
3. Replay every case in WAYDROP_LOCAL_SECURITY_TEST_RESULTS.json with actual anon, account A, account B, unsuspended admin/support and server JWTs over PostgREST. Check SQLSTATE/HTTP denial and unchanged rows, not merely a UI error. Confirm id changes cannot escape RLS WITH CHECK. Validate self-profile creation and normal edits, pending KYC upload/resubmission, staff rejection/approval and server activation/payout remain valid.
4. Exercise the seven real internal routines through their existing server/cron/trigger callers. Direct anon/ordinary authenticated RPC calls must be denied. Confirm pending assignment creation, freed-rider rematch, searching/active expiry, nearby matching and notification delivery retain their exact results. Check extensions/type resolution for every fixed search_path routine, particularly OTP and withdrawal completion/failure.
5. Same-user promo validation and service-role order pricing must preserve audience, min fare, global/user usage limits, fixed/percentage cap and exact rounding. Account B's ID, missing JWT and null target must fail for account A. Create/accept/complete local ride, parcel and intercity orders; compare authoritative passenger payable, commission, taxes, PG fees and rider earnings to baseline fixtures.
6. Sandbox payments: success, failure, pending, abandoned, duplicate/out-of-order signed webhook, retry, existing pending reconciliation, provider timeout and session change. Sandbox withdrawals: payout registration pending/active, authorization failure, insufficient funds, concurrent requests, duplicate provider callback and complete/fail idempotency. No duplicate ledger debit/credit, payout or activation is acceptable.
7. GPS/dispatch/realtime: online/offline/availability, order offers/accept races, active delivery, foreground/background and denied permission, poor accuracy, stationary heartbeat, reconnect, account switch, channel cleanup, order/chat isolation. Notifications: foreground/background/terminated tap, token rotation, unread-count updates, duplicate pushes and proximity notification idempotency.
8. Auth on physical device: fresh install, anonymous/no profile, completed passenger, all KYC and payout states, maintenance/version block, offline timeout/retry, routine token refresh, restored identity, account switch, suspended/deleted user logout including remote failure, fresh OTP after logout and mode switching. Unauthorized rider activation must never enter the rider dashboard.
9. Export SQL/API test results, application logs (redacted), sandbox ledger comparisons, notification receipts and profile timelines. Obtain explicit approval for any later production migration. No production approval or acceptance of unresolved critical risk is implied by this report.

## Required benchmark worksheet

| Metric | Before | After | Current evidence |
|---|---|---|---|
| Cold process launch p50/p95 | Not measured | Not measured | No attached physical phone |
| Warm resume p50/p95 | Not measured | Not measured | No attached physical phone |
| First usable screen p50/p95 | Not measured | Not measured | Widget concurrency is verified, latency is not |
| API sends per startup / steady minute | Not measured | Not measured | Counter tested; no comparable device sample |
| GPS successful requests per minute | Not measured | Not measured | Stream/dedup contracts tested; no moving-device sample |
| Frame build/raster p50/p95 and misses | Not measured | Not measured | No profile trace captured |

No before/after millisecond, request/minute or frame improvement is claimed.
