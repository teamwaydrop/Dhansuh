# Waydrop implementation and verification report

Date: 31 October 2026 (Asia/Kolkata). This report covers edits to the existing checkout. Its pre-existing uncommitted work was preserved. No production backend writes, migrations or deployments were performed.

The null-session spinner and eager tab mounting are fixed and covered by behavior tests. Startup, routing, GPS and refresh/query changes are implemented, with limits below. This is not a release sign-off: the full local suite is not green and device performance/business workflows have not been tested.

## Problem 1

**Problem ID:** 1 — slow startup  
**Severity:** P0  
**File path:** `lib/main.dart`, `lib/app_start_screen.dart`, `lib/core/services/config/production_config_service.dart`, `lib/core/providers/initial_data_provider.dart`, passenger/rider Home tabs.  
**Function / line number:** `main`; `AppStartScreen.checkUserFlow` (line 98), `changeScreen`; `ProductionConfigService._fetch`; `HomeTab._load`; `RiderHomeTab.initState`. See the line-indexed source manifest below.  
**Actual root cause:** Profile retrieval waited for configuration; passenger secondary data and rider earnings waited before navigation; changeScreen enforced a 500 ms floor. The existing main() already initialized Firebase, Supabase and cache in parallel and started notifications/location in the background. Config caching and auth initialSession/tokenRefreshed suppression were already present and retained.  
**Evidence:** Inspected the complete main → AppStartScreen → navigation → first Home initialization path. Before these edits, the passenger startup path awaited configuration, users, then riders/KYC/orders; rider startup awaited configuration, users, riders and an earnings scan, with no eligibility guard.  
**Code modification performed:** Start bounded profile/config requests concurrently; capture profile errors without throwing until maintenance/version gates are evaluated. Narrow the startup user projection. Run app-version/platform lookup concurrently with the config request, project only config fields, retain memory/persisted cache and in-flight sharing. Maintenance retry explicitly refreshes config. Remove the 500 ms floor. Seed passenger profile and load secondary data from Home after navigation, reusing the profile instead of re-querying it. Move rider earnings into Home after eligibility navigation and use the existing gross-fare calculation. Dispose the splash notifier, guard disposed rechecks and clear seeds on logout. Add private development/profile request counters and a main-start timing marker.  
**Why this fix is correct:** Independent reads overlap; all user/profile, maintenance and version decisions still precede usable app content. A failed concurrent profile request cannot bypass maintenance. Only secondary data moves later. Existing cached-config failure defaults and backend enforcement are unchanged; these are an existing fail-open policy, not newly guaranteed live config validation during outages.  
**Test results:** New behavior tests pass; production-control and earnings regression assertions were updated to follow the new boundaries without removing their checks. Analyzer has no errors. No device timing test was possible.  
**Before/after performance:** Source-level passenger blocking requests: 5 → 2; the other 3 execute after navigation. Config/profile waits: sum → parallel maximum; app-version/config waits: sum → parallel maximum. Artificial splash floor: 500 ms → 0 ms. These are code-path facts, not observed latency gains. Cold/warm/first-usable ms and overall API totals remain unmeasured. Rider security checks add necessary requests: the old unsafe 4-request route becomes 5 pre-dashboard reads (config/profile/KYC/rider/payout), with earnings after navigation. Do not claim fewer total rider security requests.  
**Status:** Partially Fixed — implementation complete; real startup measurements pending.

## Problem 2

**Problem ID:** 2 — hidden tabs initialize  
**Severity:** P0  
**File path:** `lib/main_navigation_screen.dart`, `lib/features/rider/navigation/rider_main_navigation_screen.dart`, `lib/shared/widgets/lazy_indexed_stack.dart`, initial-data provider and rider tab seed consumers.  
**Function / line number:** `MainNavigationScreenState.build/setIndex`; `_RiderDashboardState.build/_buildTabs`; `_LazyIndexedStackState.build`; `InitialRiderData.isUsableFor`.  
**Actual root cause:** IndexedStack mounted every child immediately; passenger tab selection also explicitly reloaded Activity. Once mounting is delayed, the old process-lifetime “cold seed” flags could incorrectly trust a startup snapshot on a much later first tab visit.  
**Evidence:** Both navigation lists constructed all tab children; child initState methods issue requests. Inspected RiderHome's assignment reconciliation, notification subscription and GPS ownership to ensure they do not depend on Orders mounting.  
**Code modification performed:** Keyed lazy IndexedStack mounts a tab on first selection and retains its State. Rider Home is eager even for a direct initial Orders/Earnings selection because it owns dispatch-critical services. Remove the Activity reload on every selection. Rider seeds now require the same authenticated user and age under 5 seconds, in addition to existing one-shot consumer guards. The projected rider seed includes fields required by all its consumers, including COD/tax/earnings/profile fields.  
**Why this fix is correct:** Hidden nonessential tabs do not enter initState; existing keyed state survives ordinary switches and service-mode list reordering. Home remains the service owner. Late first visits fetch fresh data.  
**Test results:** Real widget tests verify init counts `[1,0,0]` on launch, `[1,1,0]` after the second tab is selected, retained counter State on return, eager Home under an initial Orders selection, and Home identity after Orders removal. A unit test rejects old or other-account seeds.  
**Before/after performance:** Tested probe child initialization: all eager children previously mounted by IndexedStack; new default mount is the selected child only. Production per-tab HTTP counts need a device capture. Earnings/Profile may still refresh on later visibility changes under their pre-existing realtime lifecycle; lazy mounting does not remove correctness refreshes.  
**Status:** Fixed — code and widget lifecycle verified; device network verification pending.

## Problem 3

**Problem ID:** 3 — inconsistent rider eligibility  
**Severity:** P0 security/functional  
**File path:** `lib/core/services/session/rider_access_service.dart`, rider entry/navigation/status service, startup, `lib/shared/widgets/account_guard.dart`, passenger navigation and admin dashboard.  
**Function / line number:** `RiderAccessService.decide/resolve/_fetch`; `RiderEntryHandler.load/build`; public `RiderMainNavigationScreen.build`; `RiderStatusService.switchToRiderMode`; `AccountGuard._check`.  
**Actual root cause:** Startup entered rider navigation directly. Entry and mode switching had separate rules; entry omitted activation and could fall through to welcome for unknown KYC states when a rider existed. Admin content had no local role guard.  
**Evidence:** Compared actual branches, database enum handling, payout query and mode switching. The existing switch service requires `kyc_status=approved`, `activation_status=active`, a rider row, active Cashfree beneficiary and chosen service mode. Those are the reused business rules.  
**Code modification performed:** One decision table uses existing states: no KYC → form; pending/under_review/resubmitted → pending; rejected → existing rejection; future blocked_until → blocked; approved but inactive/no rider → waiting; missing active payout → payout setup; invalid/unset local/intercity mode → service selection; fully ready → dashboard. Unknown status fails into review. All public rider dashboard callers go through entry; switching mode reuses the service. Concurrent eligibility checks share requests only while in flight; the next entry revalidates. Session identity is rechecked after async work. Passenger navigation requires a session; admin dashboard verifies database role and suspension before its stats widget mounts. Auth stream errors are handled. Logout removes pushed screens that could obscure Login and invalidates snapshots.  
**Why this fix is correct:** preferred_mode no longer serves as an eligibility decision. Roles are read from public.users, never editable Auth metadata. Rider accounts may still deliberately use passenger mode; preferred_mode is a UI preference, not a mutually exclusive authorization role. Frontend guards remain secondary to backend RLS/functions.  
**Test results:** Decision tests cover all listed states, expired/current blocks, activation, missing rider, payout, both valid modes and invalid mode. Mocked requests verify concurrent eligibility coalescing and fresh checks on later entry. Widget test verifies a regular user never mounts admin content. Session errors and cleanup are analyzed; real expiry/refresh/logout flows still need device tests.  
**Before/after performance:** Eliminates unsafe bypass; adds mandatory KYC/payout checks to startup. No long-lived eligibility cache. Snapshot reuse reduces immediate duplicate rider reads; no measured mobile routing latency is claimed.  
**Status:** Partially Fixed — routing implemented; backend authorization gaps and full device/session-transition verification remain.

Auth-stream error handling was checked against the [official Supabase Flutter reference](https://supabase.com/docs/reference/dart/auth-onauthstatechange); local source and mocked tests provide the implementation evidence.

## Problem 4

**Problem ID:** 4 — infinite rider-entry spinner  
**Severity:** P0  
**File path:** `lib/features/rider/onboarding/screens/rider_entry_handler.dart`  
**Function / line number:** `load` line 46; `build` line 84.  
**Actual root cause:** Null currentUser returned before loading=false; errors also fell through to the KYC form.  
**Evidence:** Original early return and loading branch inspected directly.  
**Code modification performed:** Explicit unauthenticated result renders existing Login; finally clears loading for every current request; generation and mounted checks ignore obsolete completions. Invalid-token/Auth failures also resolve to Login; other failures show the existing retry/error screen. Auth subscription is canceled on disposal.  
**Why this fix is correct:** No async early return can strand the spinner or let an older request overwrite a newer auth decision; rendering replaces duplicate Navigator pushes.  
**Test results:** Real RiderEntryHandler widget with null Supabase session resolves to Login, has no progress indicator and disposes without an exception.  
**Before/after performance:** Null-session terminal state was unreachable through the early-return path; it now completes. No device millisecond benchmark needed for this correctness claim.  
**Status:** Fixed.

## Problem 5

**Problem ID:** 5 — GPS write overhead  
**Severity:** P1  
**File path:** `lib/core/services/location/location_cache_service.dart`; rider Home; active-order screen inspected.  
**Function / line number:** `_performHeartbeatUpdate` line 324; `startRiderLiveTracking` line 397; `_handlePositionUpdate` line 551; `stopRiderLiveTracking` line 645; `updateRiderLocation` line 677.  
**Actual root cause:** The stream-exists guard was checked before async permission checks, allowing concurrent starters to both subscribe. A skipped position callback's finally released another request's upload lock. Failed writes were swallowed but still advanced dedup state. Heartbeat fallback could restamp stale cached coordinates. Backend bridge/proximity work exists but has not been isolated with write-side timings.  
**Evidence:** All geolocator subscription sites were located. Two functional streams exist: shared dispatch/database tracking and the active-order map's finer local renderer stream. The latter does not write the database and was retained. Live catalog confirms both GPS triggers and existing dispatch coordinate readers.  
**Code modification performed:** Synchronous startup guard and lifecycle generation checks; upload lock only covers its owner's request; cancel errored subscriptions before permitting restart; cancel GPS monitor on stop; reject stale last-known fixes/failure fallback; advance dedup state only after a successful request in the current tracking generation. Add completed-write counter. Stop shared tracking when refreshed/realtime rider state is offline. Retain online-only UPDATE riders filter, 10 m movement gate, 30 s heartbeat and active map accuracy.  
**Why this fix is correct:** Removes proven duplicate/racy writes without changing table permissions or tracking frequency contracts. A failed upload remains eligible for retry. No client switch to rider_locations was made.  
**Test results:** Mocked actual geolocator streams and HTTP verify one subscription for concurrent starts, one upload while two fixes arrive during a blocked heartbeat, identical-coordinate suppression, all monitor/timer cleanup, failed-write retry and a new upload after the heartbeat interval. No physical foreground/background tracking test.  
**Before/after performance:** Deterministic blocked-upload regression now issues exactly one PATCH. Existing stationary policy remains approximately two successful write requests/minute when tracking/GPS are healthy, plus movement-triggered requests; this is policy arithmetic, not an observed field rate. Actual uploads/minute and bridge timings remain unmeasured.  
**Status:** Partially Fixed — Flutter races fixed; device rates and backend bridge experiment pending approval/staging.

## Problem 6

**Problem ID:** 6 — overlapping realtime/polling  
**Severity:** P1  
**File path:** passenger Home/Activity, rider Home and the new diagnostics HTTP client. Existing realtime manager/order controller/Orders fallback inspected.  
**Function / line number:** `HomeTab._load` line 687; `ActivityTab.loadOrders` line 263; `RiderHomeTab.loadRider` line 348 and `_fetchTodayEarnings`; Home timer/lifecycle methods.  
**Actual root cause:** Multiple refresh sources could enter Home/Activity/rider Home fetches concurrently. Passenger Home's passive timer continued when hidden. Existing Orders/controller health/backoff checks and pooled rider channels already reduce traffic and must not be removed just because timers exist.  
**Evidence:** Reviewed timer guards, subscription identities, ownership, active-order cover handling, fetch entry points and disposal. The existing realtime controller already coalesces its polling/realtime fetches; Orders already guards searching-order fetches.  
**Code modification performed:** Home/Activity serialize full refreshes and coalesce a pending refresh rather than lose a realtime invalidation. Rider Home shares a completion across overlapping callers and drains a queued reconciliation; earnings queries share in-flight work. Bound new refresh batches. Passenger Home pauses passive refresh when hidden/backgrounded and restarts when visible/resumed. Preserve dispatch/order realtime and fallback/backoff logic. Add counts of actual HTTP sends per operation in a rolling minute.  
**Why this fix is correct:** Timers are not counted as requests. Hidden passive work is suppressed while essential realtime remains; concurrent signals serialize rather than race or silently disappear.  
**Test results:** Analyzer has no errors; existing local lifecycle/request tests were run in the suite. New HTTP counter test verifies actual sends, rolling expiry and no query/header secrets. New eligibility/GPS concurrency tests pass. Screen-specific refresh coalescing still requires device/slow-network exercise; it is not claimed as fully behavior-tested.  
**Before/after performance:** No real per-minute passenger/rider request sample is available. Instrumentation now exposes operation totals and rolling counts; unchanged timers were not arbitrarily removed.  
**Status:** Partially Fixed.

## Problem 7

**Problem ID:** 7 — order/notification queries  
**Severity:** P1  
**File path:** notification badge service, Home/Activity, rider order/earnings screens and query/index evidence JSON files.  
**Function / line number:** `NotificationBadgeService._refreshOnce`; `ActivityTab.loadOrders/_loadMorePastRides/_loadMorePastParcels`; rider assignment query call sites.  
**Actual root cause:** Unread count selected and transferred notification ids alongside the exact count. Startup fetched full rows that Home's existing projected queries already knew how to load. Several historical query entries reflect older broader SQL, not necessarily the current Flutter projection.  
**Evidence:** Call sites searched across lib and matching Edge Functions. Existing Activity uses per-bucket keyset pagination, bounded active orders and projected rows; rider assignment queries already project joined fields. Live indexes, statistics and two read-only EXPLAIN ANALYZE plans captured.  
**Code modification performed:** Replace unread GET/select-id/count with HEAD exact count, preserving same owner/unread filters and shared refresh queue. Reuse existing projected Home queries after navigation. Preserve existing pagination, matching parameters, financial queries and returned display fields; no speculative nested-join/index rewrite.  
**Why this fix is correct:** Badge needs only a number; backend RLS still evaluates it. Existing index already supports the filter. Changing large financial aggregates or matching functions without representative data could change results; they were not shortened or silently paginated.  
**Test results:** Mock HTTP confirms HEAD, count=exact, owner/unread filters and resulting badge value 7. Existing order/history/earnings tests ran; known failures are recorded below. SQL count plan uses idx_notifications_user_id_is_read.  
**Before/after performance:** Unread response body: row ids → no row body. Exact-count database cost remains; no faster SQL execution claim. Count-plan sample 64.678 ms and empty pending-assignment join 0.235 ms are not before/after or mobile measurements.  
**Status:** Partially Fixed — proven client overhead removed; representative matching/order plans and staging optimization remain.

## Problem 8

**Problem ID:** 8 — backend security warnings  
**Severity:** P0 review  
**File path:** `docs/proposals/WAYDROP_BACKEND_PROPOSAL.md`, two proposal SQL files, catalog/advisor/permission/view/Edge review evidence.  
**Function / line number:** Exact object signatures, policy names, trigger definitions and deployed Edge identity-check lines are in those artifacts; frontend admin guard is in `account_guard.dart`.  
**Actual root cause:** Specific grants expose bypass-RLS compliance views and internal routines. Owner-row RLS does not protect server-controlled role/KYC/payout fields. Existing role trigger covers UPDATE but not profile INSERT. Advisor warning totals alone do not establish exploitability.  
**Evidence:** Live read-only catalog: 113 definer functions; 69 anon/90 authenticated executable; 33 mutable paths, seven of them definer. Seven advisor-flagged views. Two sensitive views have anonymous SELECT and bypass-RLS owners. Owner insert/update grants and protection-trigger coverage checked. Seven sensitive deployed Edge Functions downloaded/reviewed. Client scan found one legacy anon JWT in .env and no service-role JWT, sb_secret or private-key patterns in the scanned client sources/assets/config. Values were not recorded.  
**Code modification performed:** Admin frontend guard implemented. Backend changes are proposal files only: restrict two private views/internal RPCs; protect INSERT roles, suspension, KYC decisions and payout activation; scope promo identity; pin seven privileged search paths. No policy/trigger/function was removed or deployed.  
**Why this fix is correct:** Avoids blanket revocation/invoker conversions that could break intentional cross-account matching/tracking. Existing financial guard and service-only withdrawal completion were confirmed. verify_jwt=false functions were evaluated on actual auth.getUser/identity/signature checks.  
**Test results:** Catalog/permission/definition review verified. No production exploit writes or unauthorized payment tests performed. Proposal SQL not applied or staged-tested; rollback, negative ownership and service workflow tests specified separately.  
**Before/after performance:** Production unchanged; security improvement depends on approved deployment.  
**Status:** Requires Backend Approval.

## Problem 9

**Problem ID:** 9 — Auth/profile mismatch  
**Severity:** P2; recovery correctness  
**File path:** startup, `lib/features/auth/screens/profile_setup_screen.dart`, backend proposal/evidence.  
**Function / line number:** `checkUserFlow` missing-profile branch; `ProfileSetupScreen.saveProfile`.  
**Actual root cause:** No Auth-users profile creation trigger; profile setup only UPDATEd public.users. An authenticated account with no row could see a successful zero-row update and continue without a profile. Registration paths do not establish that every Auth account must already have a profile.  
**Evidence:** Live counts: 174 Auth, 127 profiles, 47 missing and zero orphan profiles. Groups: 26 anonymous signed-in, 18 never-signed-in/unconfirmed, 3 confirmed/signed-in. No account identifiers retrieved for the report. Inspected OTP/profile creation and startup recovery.  
**Code modification performed:** Keep missing-profile routing to the existing form. On explicit form submission, UPSERT only authenticated id, canonical Auth phone and supplied form fields, with on_conflict=id and a returned id required to confirm success. Preserve existing profile fields on conflict and default ordinary role on insert. Add mounted checks on failed/late completion. No automatic backfill.  
**Why this fix is correct:** Recovers a single account through its existing user action without creating records at app launch or making assumptions about all 47 records. Backend ownership RLS still applies.  
**Test results:** Real form widget/mock HTTP verifies merge-duplicates upsert, exact safe payload and disposal during request. No production record was created. Business exceptions and the three confirmed accounts still need administrator investigation.  
**Before/after performance:** Missing-row submit now requests a real upsert result instead of accepting zero updated rows; no timing benchmark claimed.  
**Status:** Partially Fixed — client recovery fixed; account classification remains investigative.

## Problem 10

**Problem ID:** 10 — regression/performance verification  
**Severity:** Mandatory  
**File path:** test changes listed below; `docs/WAYDROP_VALIDATION_2026-10-31.json`; raw logs under build.  
**Function / line number:** Three new behavior-test files and the updated structural assertions.  
**Actual root cause:** Static findings and historical database means do not establish mobile performance or correctness; existing source-shape tests also predate some implementation changes.  
**Evidence:** Installed Dart 3.11.1/Flutter toolchain was used. Initial launcher/cache permission stalls were resolved by invoking the installed Flutter tool snapshot with approved SDK/user-cache access. adb devices returned no attached Android device.  
**Code modification performed:** Added 12 offline behavior/unit tests; updated affected structural assertions to follow moved/guarded code while retaining earnings, maintenance and logout checks. Added request instrumentation and preserved baseline comparison evidence.  
**Why this fix is correct:** Tests distinguish actual behavior, structural checks, SQL samples and unperformed field measurements. Results are not reported as all green.  
**Test results:** New behavior tests: 12 pass. Latest focused run including production-control, gross-earnings and query regressions: **103 pass**. Latest full local suite excluding two live-service files: **1,993 pass, 20 fail**. Flutter analyze: **0 errors, 75 warnings, 433 informational findings; nonzero exit due to diagnostics**. `git diff --check` passes. After the complete suite, startup diagnostic logs were corrected and profile submission was tightened to preserve an existing phone when Auth has none; affected tests and analyzer were rerun afterward.  
**Before/after performance:** No physical-device cold/warm/first-usable/frame or request/minute before/after sample exists. Source-level blocking reductions and mocked concurrency/request-body changes are reported above.  
**Status:** Partially Fixed — release validation remains open.

## Test failures and unperformed checks

The complete failing test names are in `WAYDROP_VALIDATION_2026-10-31.json`. An isolated tracked-HEAD copy reproduced 18 failures among the selected original groups (244 tests passed); one of those old timeout-assertion failures was corrected here, leaving **17 remaining failures reproduced at tracked HEAD**. Two remaining chat failures concern the untouched, already-modified `order_chat_screen.dart`; the twentieth is the missing `.audit_backup/phase1_surgical_create_order/...` fixture, also confirmed in the original copy. The baseline is tracked HEAD, not a byte-for-byte snapshot of the user's initial dirty worktree; that limit matters.

Remaining categories: old structural expectations for rider busy/free rematch and active-order lifecycle; local-delivery function signature; pricing alias/fare and payment-phone expectations; KYC identity-check source wording; nearby-map eligibility; chat subscription cleanup/filter shape; missing staged audit fixtures. Do not reinterpret these as successful behavior checks or automatically change production logic to satisfy an old source substring. Their full failures remain visible.

Excluded live files: `pricing_dedup_regression_test.dart` and `intercity_parcel_pricing_regression_test.dart`. They use real configured services and were excluded to keep validation offline/read-only.

Not performed: actual passenger/rider OTP login; session expiry/refresh/logout on a device; KYC review/activation/payout transitions against staging; rider availability; order creation/acceptance/completion; payment/withdrawal/provider webhook delivery; real notifications; physical foreground/background GPS; profile-mode frame timing. No such flow is marked passed.

## Important diffs

```dart
// Startup: was config -> profile -> secondary batch -> navigation (+500 ms floor).
await Future.wait<dynamic>([config.init(), profileRequestWithCapturedError]);
// Evaluate maintenance/version before applying profile or showing usable content.
// Passenger startup now seeds only profile; Home fetches secondary data afterward.
```

```dart
// Was IndexedStack(children: everyTab).
LazyIndexedStack(index: selected, children: keyedTabs);
// Rider only: eagerIndices: const {0} keeps the Home service owner alive.
```

```dart
// Every public rider dashboard construction is guarded.
RiderEntryHandler(readyScreen: _RiderDashboard(initialIndex: initialIndex));
// Only an approved, activated, paid-out-ready rider with valid service mode enters.
```

```dart
// GPS: acquire before try; skipped fixes cannot reach the lock owner's finally.
if (!_shouldUploadPosition(position) || isUpdatingDb) return;
isUpdatingDb = true;
try { /* upload; advance dedup state only on successful current-generation result */ }
finally { isUpdatingDb = false; }
```

```dart
// Was select('id') ... count(exact), transferring ids too.
final count = await client.from('notifications').count(CountOption.exact)
    .eq('user_id', user.id).eq('is_read', false);
// Profile form: UPDATE that may affect zero rows -> self UPSERT + returned id.
```

These snippets explain the important changes; actual source and the line-indexed manifest are authoritative. No application visual layout, existing form, bottom-bar design or map rendering was redesigned.

## Modified files

See `WAYDROP_CHANGED_FILES_2026-10-31.md` for every source/test file changed for this task and function line references. Pre-existing dirty files in realtime manager, user-session service, incoming-order card, chat, payments and unrelated tests were not edited for this task. Startup, location cache, passenger Home and notification badge already had user edits; the changes here build on them.

## Performance capture procedure

Use an authorized staging account and attached target phone. Run the same profile build/conditions at the original checkout and this revision. Preserve the existing SDK/version, account roles, dataset and network conditions. Do not mix debug timings with profile results.

1. Capture at least 10 cold starts (process force-stop) and 10 warm foreground/resume cycles per account. Record p50/p95 and sample count, not one lucky run.
2. Correlate main-start `[PERF_PROCESS]`, `[PERF_STARTUP]`, `[PERF_HOME]` and the first displayed usable content/frame. Report whether permission/network prompts were included.
3. Inspect `apiMetricsClient.totals` and `requestsLastMinute` in DevTools. The non-release Supabase HTTP wrapper records REST/auth/function operation names and methods, never body/header/query values; it does not count realtime socket frames or SDK-internal traffic bypassing that HTTP client. Record the delta before/after each startup/tab operation, then a steady minute per visible tab.
4. Record `LocationCacheService.successfulLocationUploads` deltas over a stationary and moving minute, online/offline and in delivery. It counts successful requests, not changed database rows. Validate actual passenger tracking and reconnect behavior simultaneously.
5. Use Flutter DevTools profile frame charts for navigation/map/order operations; capture slow-network and interrupted realtime recovery. Run the business-flow checks listed above before considering a release.

| Metric | Before | After | Evidence quality |
|---|---:|---:|---|
| Passenger pre-navigation data reads | 5 | 2 | Inspected code path, excludes startup services/SDK/auth traffic |
| Artificial splash floor | 500 ms | 0 ms | Source change |
| Initial unrelated tab mounts | Every child | Selected child; rider Home always retained | Real generic-widget lifecycle tests |
| Blocked GPS request plus two arriving fixes | Racy overlapping path | 1 PATCH | Mocked real stream/HTTP test |
| Unread count response body | Notification ids plus count | HEAD/no row body | Mocked HTTP test |
| Cold/warm first usable screen p50/p95 | Not captured | Not captured | Requires device |
| Actual production requests/uploads per minute | Not captured | Not captured | Instrumentation supplied |
| SQL/mobile latency improvement | No comparable baseline | Not established | No claim |

## Approval boundary

Only the backend proposals require approval before staging/production deployment. They are not in the migration directory and have not been run. No production profiles should be created/deleted en masse based on the aggregate mismatch. Existing local migration files were left as found. Backend authorization gaps and the outstanding regression/device checks remain release blockers.
