# Waydrop continuation: implementation and verification report

Date: 31 October 2026. **Production release verdict: NOT READY.** The original offline failures are resolved and additional functional fixes are implemented. Critical backend proposals still require full Supabase staging validation and explicitly approved production deployment. Device, provider and complete end-to-end validation remain open. No production database changes, function deployments, payments, user backfills or order mutations were performed in this continuation.

This continues the existing modified project. The continuation-start source/test/proposal snapshot and SHA256 manifest are in .dart_tool/waydrop_review_before. Earlier work and the user's existing changes were retained. The earlier report is historical; this report supersedes its outstanding-test and proposal-validation status.

## Verified results

| Check | Before continuation | Final result |
|---|---|---|
| Complete offline Flutter suite | 1,993 passed, 20 failed | **2,038 passed, zero failed** |
| Original 20 failures | Outstanding | All resolved; every case documented below |
| Analyzer errors | 0 | **0** |
| Analyzer warnings | 75 | **73** |
| Analyzer information diagnostics | 433 | **382** |
| New analyzer findings | — | **0**, comparing file/code/message while ignoring line moves |
| Async-context diagnostics | 37 | **0** |
| Local SQL and actual TypeScript business contracts | No executable proposal harness | **58 passed, zero failed/cancelled/skipped** |
| Physical Android devices | None available | Empty adb device inventory; profile benchmarks unavailable |
| Production backend modifications | Prohibited without approval | **None** |

The Flutter count is the complete offline command's result, not all possible connected workflows. The two existing live-service files pricing_dedup_regression_test.dart and intercity_parcel_pricing_regression_test.dart were not run because they target configured real services. They are explicitly outstanding, not silently skipped or disabled. The missing-fixture setup now executes genuine tracked-baseline assertions, which also changes the number of discovered/passing cases. No failing tests were removed, marked skip or hidden to obtain a pass. After the complete run, fixture test labels were clarified to say tracked baseline rather than a production download; the unchanged assertions were rerun separately and passed (see verification-continuation/continuation_fixture_final.txt).

Evidence: [full Flutter log](verification-continuation/continuation_final_flutter_tests.txt), [canonical Flutter analyzer log](verification-continuation/continuation_flutter_analyze_verified.txt), [58-check Node log](verification-continuation/continuation_node_tests3.txt), [structured SQL cases](WAYDROP_LOCAL_SECURITY_TEST_RESULTS.json), [all analyzer findings and triage](WAYDROP_ANALYZER_TRIAGE_CONTINUATION.json). The analyzer intentionally returns nonzero while existing warnings/information diagnostics remain; it is not reported as a clean-lint run.

## Functional fixes implemented in this continuation

| File / function | Root cause and resulting behavior | Verification |
|---|---|---|
| lib/app_start_screen.dart:88, checkUserFlow | The earlier parallel Future.wait still waited for a stalled profile before showing maintenance/version decisions. Configuration and profile now start together, profile failures are observed immediately and bounded, config-only gates resolve first, and user/mounted checks still precede profile application. | Actual AppStart widget test failed before and passes after: maintenance appears while the profile response remains pending. No fabricated startup time. |
| lib/core/services/session/auth_routing_policy.dart:9, shouldRecheck; AppStart listenAuthChanges; RiderEntryHandler and AccountGuard auth listeners | Ignoring every tokenRefreshed event also ignored a restored or changed identity. The shared policy suppresses only same-identity initial/refresh/duplicate-signout events. Restored identities route again; routine refresh retains content without extra eligibility reads. | Actual SDK setSession, widget routing and request-count assertions; pure policy transitions. This fixes a regression in the earlier refresh suppression. |
| lib/core/services/session/user_session_service.dart:56, handleAccountRestriction | Existing restriction handling replaced the entire stack with a bare Login screen, losing the auth owner needed by the next OTP login after mode switching. The reusable handler restores AppStartScreen, bounds logout/cache cleanup, handles remote logout failure, stops owned listeners and avoids a stale account's cleanup navigating over a newly signed-in identity. | Widget test begins without AppStart, mocks remote logout HTTP 503, invokes the actual handler, pushes a synthetic OTP route, restores a real SDK session and verifies profile routing removes that route. It does not claim a real SMS OTP round trip. |
| lib/core/services/realtime/realtime_manager.dart:251, _createSupabaseChannel; :293, _subscribeToChannel | Queued payloads could reach former owners after manager disposal, and replaced channel callbacks could still affect current channel state. Both payload and status callbacks now require the live managed entry and exact current channel identity. An isolated client constructor supports behavior tests; debug counts use that manager instance. | Disposal test reproduced one unexpected callback before the guard; all four manager behavior tests now pass. Pooling, owner release, order-filter isolation and exception isolation are executed without a network. Actual server reconnect remains staging work. |
| intercity_tracking_screen, parcel_tracking_screen, ride_tracking_screen: _performCancel | Async cancellation used a supplied sheet context after navigation/disposal. Validate mounted state and use the live parent State context for subsequent snackbar/navigation. | Analyzer plus retained cancellation/financial/navigation regressions. Device cancellation UI still requires the runbook. |
| ride_location_screen and parcel_location_screen: continueFlow | Serviceability response could return after the booking State was disposed. Return before using its controllers/navigation when no longer mounted. | Analyzer and existing booking/serviceability regression suite. |
| rider_home_tab: _showFreeTrialBottomSheet, _showSubscriptionBottomSheet, _handleOrderAction | Closed modal contexts and setSheetState could be reused after awaited network/payment/order operations. Check the exact modal context before updates/pop, and use the parent State context for the next route, payment call or snackbar. | Analyzer and subscription/order/payment amount source contracts retained; no formulas or visual layout changed. |
| rider_earnings_tab payout sheet; rider_active_order_screen confirmCancellation; travel_plan_details delete modal; user/profile upload and rider mode-switch callbacks | Similar lifecycle gaps around async modal/pop/upload operations. Guard the relevant context or State after the await. | Analyzer and applicable existing regressions. These are code-audited lifetime fixes, not a claim that 37 distinct device crashes were reproduced. |
| pubspec.yaml / pubspec.lock | KYC upload directly imports path_provider but the package was only transitive. Declare the already-locked **2.1.5** directly. | Offline resolution succeeded; lockfile version and checksum unchanged. No dependency upgrades. |
| LocationCacheService, RiderAccessService, UserSessionService, AccountGuard and one existing behavior test | Added braces to owned guard branches flagged by the analyzer. Removed unused private constructor key parameters in rider/admin dashboard content. | Behavior-preserving cleanup, 13 information and 2 warning findings removed. |

[Exact function references](WAYDROP_CONTINUATION_FUNCTION_REFERENCES.json), [continuation-only changed-file manifest](WAYDROP_CONTINUATION_CHANGED_FILES.json), and [complete continuation-only diff](WAYDROP_CONTINUATION_DIFF.patch) are supplied. The manifest covers 51 implementation/test/proposal/tool/dependency files; report/evidence files are additional deliverables. The diff compares against the continuation snapshot, not against HEAD where earlier edits and user changes are mixed together. Pubspec files were clean at continuation start and are compared to HEAD. No Supabase Edge Function implementation or payment/pricing formula was rewritten during this continuation.

## All 20 original failures: root cause and resolution

Origin evidence: 17 of these failures had already been reproduced in tracked HEAD during the earlier report. That is evidence they predated that implementation, with the explicit limit that tracked HEAD is not the exact initial dirty worktree. Cases 17–18 concern the user's already-modified pooled chat implementation; this continuation did not introduce that implementation. Case 16 depended on an untracked fixture absent in the original workspace too. None of the original 20 required changing intended runtime business behavior to satisfy the test. Separate real bugs above were found by behavioral verification and fixed.

| # | Failing test file | Exact root cause | Fix preserving intended behavior |
|---|---|---|---|
| 1 | subscription_stale_pending_payment_regression_test.dart | Old literal customer_phone expression expected an invented fallback; shipped code delegates to resolveCashfreeCustomerPhone. | Existing financial amount assertions retained; require actual customer-phone helper call and execute helper contract in Node. |
| 2 | rider_self_rematch_regression_test.dart | Exact old busy-to-free condition omitted intentional first-poll recovery for an already-free rider. | Accept first-poll-or-wasBusy gate; retain awaited rematch before refetch and no extra timer. |
| 3 | rider_self_rematch_regression_test.dart | Expected empty catch(e); implementation now records Crashlytics with stackTrace without making rematch fatal. | Assert caught diagnostic branch and subsequent fetch rather than empty catch spelling. |
| 4 | rider_pending_ride_after_completion_regression_test.dart | Same obsolete busy-to-free source expression; wasBusy snapshot and forced fetch remain. | Recognize first-poll recovery as well as busy-to-free transition. |
| 5 | rider_orders_screen_duplicate_active_order_work_suppressed_regression_test.dart | Same obsolete busy-to-free source expression; synchronous awaited self-rematch remains inside fallback. | Keep rematch-before-fetch ordering assertion using current guarded branch. |
| 6 | rider_orders_busy_to_free_refetch_regression_test.dart | Same obsolete busy-to-free branch literal. | Assert current first-poll-or-busy gate with no active order. |
| 7 | rider_orders_busy_to_free_refetch_regression_test.dart | Branch extraction failed because its start marker was obsolete; fetchSearchingOrders was present. | Extract current guarded branch and retain forced-fetch assertion. |
| 8 | rider_orders_busy_to_free_refetch_regression_test.dart | Test forbade intentional initial free-rider recovery by requiring transition-only behavior. | Require bounded first-poll-or-busy gate, never unconditional polling. |
| 9 | rider_kyc_submission_reliability_regression_test.dart | Expected exact old English rejection text; create-rider-kyc already compared authenticated identity and returned 403. | Assert identity comparison plus 403 response without coupling to error-message prose. |
| 10 | rider_kyc_submission_reliability_regression_test.dart | Expected exact old English rejection text; validate-rider-kyc already compared authenticated identity and returned 403. | Assert identity comparison and 403 response for the validate endpoint. |
| 11 | rider_home_active_order_duplicate_work_suppressed_regression_test.dart | Arbitrary 600-character dispose slice ended before existing PiP cleanup. | Inspect complete dispose block; keep isOpen and PiP cleanup checks. |
| 12 | rider_home_active_order_duplicate_work_suppressed_regression_test.dart | Expected loadRider() with default duplicate active-order read; implementation correctly uses loadActiveOrder plus loadRider(skipActiveOrderReload:true). | Assert explicit reconciliation and deduplicated load contract. |
| 13 | rider_home_active_order_duplicate_work_suppressed_regression_test.dart | Exact timer condition omitted existing backoff conjunction; visibility gate and timer lifecycle remained. | Recognize existing backoff while preserving isOpen and periodic lifecycle assertions. |
| 14 | production_fix_2026_07_29_regression_test.dart | Arbitrary 13,000-character slice truncated before real PartnerCard yourFare wiring. | Inspect relevant complete card scope and preserve authoritative passenger fare assertion. |
| 15 | intercity_parcel_fixes_regression_test.dart | Alias moved into shared pricing-calculations.ts; endpoint already imports and executes it. | Inspect the real shared calculator and its endpoint call; execute actual TypeScript calculation contracts. |
| 16 | create_order_surgical_phase1_regression_test.dart | Untracked .audit_backup production-v76 fixture was absent; suite setup could not run. | Track a genuine pre-control source baseline from commit ed24dee3da2d724bf1e109a4ff8ee895e4170556 with SHA256 provenance; assert remainder equality after removal of only the feature gate/import. Historical deployed v76 comparison remains unverified. |
| 17 | chat_regression_test.dart | Test expected direct raw-channel API; existing dirty chat source uses pooled RealtimeManager with the same order_id filter. | Assert pooled subscription table/filter/current order id and add real manager isolation tests. |
| 18 | chat_regression_test.dart | Test expected raw channel removal; existing dirty chat source releases its pooled subscription ID. | Assert unsubscribe with channel/subscription ownership; manager behavior test proves final owner closes channel. |
| 19 | local_order_delivery_regression_test.dart | Test searched old no-argument loadRider signature; current optional-argument wrapper still reconciles pending assignments. | Recognize named parameters while retaining reconciliation in function body. |
| 20 | nearby_partner_count_regression_test.dart | Test referenced a removed Home map-marker query; Home now reads current rider identity, availability uses canonical find_nearby_riders in search screens. | Assert current scoped Home query and canonical nearby RPC at its real callers; allow whitespace in RPC syntax. |

[Machine-readable per-failure record](WAYDROP_FAILURE_TRIAGE_CONTINUATION.json) preserves every original test name, individual origin classification, fix and result. Assertions continue to check business contracts, authorization comparisons, rematch ordering, ownership filters and cleanup; source spelling/character-count slices are no longer mistaken for the contract.

The replacement create-order fixture is the actual file from commit ed24dee3da2d724bf1e109a4ff8ee895e4170556, with SHA256 6bbeb4fce044d31f4bbcfcc262273e77714739c2082839d2a11644e213108f3f recorded in its provenance JSON. The test removes only the control import and feature-gate block and compares all remaining source exactly to that tracked baseline. It retains auth, device, OTP, fare, payment and dispatch fields. This restores reproducible regression protection; it does **not** establish equality to the unavailable historically deployed v76 artifact. That historical deployment comparison remains unverified.

## Backend security proposal review

The Supabase skill workflow was applied. Existing catalog/permission snapshots were reviewed without mutating production. The proposals remain outside supabase/migrations and end in ROLLBACK. They have been exercised only in an isolated PostgreSQL 18.6 PGlite database using synthetic data. No proposal was submitted to production or a connected staging Supabase project.

| Risk | Prepared fix | Local negative / positive evidence | Status |
|---|---|---|---|
| Profile INSERT privilege escalation | Add guard_client_user_security_fields; normal self-profile defaults allowed, admin/support/developer/suspension injection denied; retain existing UPDATE role guard and add suspension protection. | Baseline admin insertion reproduced; forged roles/flags and owner protected updates fail; ordinary profile creation/edit and server writes pass; cross-user ownership remains constrained by RLS. | Proposal tested locally; full clone pending. |
| Unauthorized KYC decision/activation changes | guard_client_kyc_decisions prevents clients assigning/changing approval, activation, block and rejection fields; null status cannot bypass defaults. Preserve existing RLS-authorized unsuspended staff review and trusted server operations. | Baseline owner decision mutation reproduced; forged approval/activation/block/reason/null inserts and updates denied; pending profile edits, server decisions and authorized admin approval pass; suspended staff denied. | Proposal improved and tested locally; real approval/rider-creation trigger chain pending. |
| Payout activation | guard_client_payout_activation denies active beneficiary insertion and client activation-state changes. | Baseline fabricated active insert reproduced; negatives denied; ordinary pending setup and server activation pass. | Full Cashfree sandbox payout lifecycle pending. |
| Sensitive views | Revoke SELECT on parcel_compliance_view and parcel_security_timeline_view from PUBLIC, anon and authenticated; retain service_role. | Baseline anon read reproduced; both views denied for ordinary/anon roles and accessible to server role. | ACL checked; real operational consumers require clone validation. |
| Seven privileged internal RPC overloads | Revoke PUBLIC/anon/authenticated EXECUTE; retain service_role for named expiry, redispatch, core assignment and notification routines. | Role/ACL and unauthorized-call tests pass for all seven signatures. | RPC bodies are explicit no-op ACL fixtures in the harness; real cron/dispatch/notification behavior untested. |
| Promo identity | Bind non-service requests to auth.uid() using null-safe comparison; preserve original promo body and server pricing behavior, pin search path and explicit grants. | Baseline cross-account audience read reproduced; other/missing/null identities and anon denied; same-user discounts and server-selected owner continue to work. | Actual proposed promo SQL executed locally; real order pricing/usage concurrency pending. |
| Privileged search paths | Pin seven named definer routines to public,pg_temp. | Configuration checked locally. | Promo body real; six path-only routines are fixtures. Real OTP, withdrawal and expiry resolution pending. |

The SQL parent test executes **52 scenarios**; five tests execute actual shipped TypeScript pricing/phone/feature-gate code. Node reports 58 total tests because its parent SQL test is also counted. No skipped tests. The engine is PostgreSQL 18.6, while the saved production project is PostgreSQL 17. This is executable PostgreSQL authorization evidence, not a full Supabase staging clone, provider test or proof all 113 catalog functions are safe.

The original proposal would have blocked existing authorized staff KYC updates. That was corrected before staging by checking protected database roles and suspension state; this does not grant any RLS access. No client-supplied metadata grants staff authority. Existing financial guards and RLS were retained. Other aggregate/directory views and remaining Edge/RPC inventory still need their intended audiences/callers reviewed; no blanket security rewrite was performed.

[Security SQL](proposals/waydrop_security_review.sql), [promo SQL](proposals/waydrop_promo_ownership_review.sql), [updated review notes](proposals/WAYDROP_BACKEND_PROPOSAL.md), [executable harness](../tools/waydrop-verification/security.test.mjs), [actual business contracts](../tools/waydrop-verification/business-contracts.test.mjs). The client secret scan found only the expected anon JWT in the private .env; no service_role JWT or private-key pattern in its scanned client scope. This is a pattern scan, not proof no secret exists anywhere.

## Flutter verification coverage and remaining limitations

| Area | Verified locally | Still required |
|---|---|---|
| Startup | Actual maintenance/stalled-profile widget, timeout/routing structural regressions, lazy-tab lifecycle and seed tests. | Cold/warm physical startup, permissions, version gate, offline/retry and complete passenger/rider first screen with staging data. |
| Sessions / logout | Real SDK session refresh/restore in widget tests; no redundant rider eligibility on same identity; inactive rider denied; restricted logout remote failure and next-login route recovery. | Real SMS OTP, refresh expiry/network loss, foreground/background account switching and provider-side session revocation. |
| KYC / activation | Pure production eligibility decisions across status, block expiry, activation, payout and mode; mounted entry tests; SQL negative/positive authorization cases. | Uploaded documents, Edge validation, staff review and rider creation/activation against full staging. |
| Passenger/rider orders and dispatch | Existing offline source contracts pass; actual feature gate executes against controlled config; current fare/financial/dispatch source baseline retained. | Two-account create/offer/accept/complete/cancel, competing acceptance, expiry, rematch and GPS-dependent matching with real triggers. |
| Payments / withdrawals | Actual pricing/response/phone helpers executed; existing amount/tax/fee/ledger contracts pass; activation SQL checked. | Cashfree sandbox, signed duplicate/out-of-order webhook, retry/reconciliation, concurrent withdrawal and idempotent ledger verification. |
| GPS | Actual mocked stream/HTTP tests verify coalesced startup, upload lock, successful-write dedup, failed-write retry and 30-second heartbeat eligibility. | Physical moving/background tracking, permissions, battery/process lifecycle, backend trigger write counts and passenger freshness. |
| Realtime | Four actual manager tests: pooled stream, owner lifetime, mismatched-order filter isolation, exception isolation and post-disposal payload rejection. | Server reconnect/auth rotation, loss/rejoin, queued old status, production-like channel volume and notifications. |
| Notifications | Actual unread HEAD count request contract and existing routing/badge source regressions. | Real FCM token rotation, foreground/background/terminated delivery, tap routing and proximity duplicate suppression. |

Most legacy Flutter regressions inspect source contracts; their green result is not presented as a completed live transaction. No physical-device or provider scenario in the right-hand column is marked passed.

## Analyzer triage

All 508 original diagnostics were categorized; the full remaining list is in WAYDROP_ANALYZER_TRIAGE_CONTINUATION.json. Functional priority went to async lifetime issues. The 37 use_build_context_synchronously diagnostics are resolved, 13 brace findings removed, direct package dependency fixed and two unused private key parameters removed. Total falls from 508 to **455**.

Remaining **73 warnings**: unused imports 18, unused elements 26, unused local variables 18, unused fields 3, unused element parameters 5, unused catch 1 and unnecessary non-null assertions 2. Review found no newly introduced warning. Existing unused UI helpers/colors and dead local scratch variables were left for a scoped cleanup rather than rewriting UI or payment flow here.

Remaining **382 information diagnostics**: deprecated members 325, dangling library docs 13, null-aware elements 4, prefer-final fields 7, conditional assignment 10, unnecessary underscores 17, unnecessary imports 2 and interpolation preferences 4. The API deprecations are predominantly existing Flutter presentation APIs; they are recorded, not suppressed. No ignore rules or analyzer configuration were added. No new diagnostic remains when comparing file/code/message while disregarding shifted lines.

A direct dart analyze lib test attempt emitted duplicate diagnostics for overlapping analysis scopes. Its 917 raw entries were not treated as 917 distinct issues. The authoritative result is the final full **flutter analyze --no-pub** output: zero errors, 73 warnings, 382 infos, 455 total, 7.4 seconds analyzer runtime. Analyzer runtime is not an app performance benchmark.

## Performance results

| Required benchmark | Before | After | Reason / evidence |
|---|---|---|---|
| Physical cold startup p50/p95 | Not measured | Not measured | No attached Android phone |
| Warm startup/resume p50/p95 | Not measured | Not measured | No comparable profile samples |
| Time to first usable screen | Not measured | Not measured | Widget route readiness proved, device latency not measured |
| API request counts / minute | Not measured on device | Not measured on device | Counter contract verified; no real scenario capture |
| GPS writes/minute | Not measured on device | Not measured on device | HTTP dedup/heartbeat test is not a database-trigger benchmark |
| Frame build/raster time and misses | Not measured | Not measured | No physical Flutter profile trace |

There is no actual before/after mobile benchmark to report. Existing source improvements and deterministic mock assertions are not relabeled as milliseconds, request/minute savings or frame improvements. adb devices -l returned an empty list. [Exact profile/staging commands, first-usable definition, raw-sample requirements and acceptance procedures](WAYDROP_DEVICE_AND_STAGING_VERIFICATION.md) cover all requested metrics. The runbook names com.waydrop.app, profile mode, staging-only defines, cold force-stop versus warm resume, API/GPS counter deltas and DevTools frame exports.

## Remaining issue list and release gates

1. **Critical:** production authorization gaps remain until the reviewed SQL passes the full PostgreSQL 17 Supabase clone/API checks and an explicitly approved production deployment occurs. Local SQL success does not close this gate.
2. **High:** full cron/dispatch/notification trigger execution and fixed-search-path callers are not validated. The local internal RPC fixtures check permissions only.
3. **High:** complete two-account order/activation flows and provider payment/withdrawal ledger/idempotency scenarios remain unverified on staging. The two existing live-service test files also remain unrun against an approved staging target.
4. **High:** physical Android profile, background GPS, real notification and real OTP/session lifecycle testing are unavailable without an attached phone and approved staging accounts/provider setup.
5. **Review required:** remaining definer RPCs, other aggregate/directory view audiences and remaining deployed Edge functions need the bounded security review described in the earlier inventory. No claim of a complete backend penetration test is made.
6. **Evidence gap:** the historical deployed create-order v76 artifact was unavailable. A tracked, hashed pre-control baseline now gives reproducible protection, but historical deployment equivalence is unproven.
7. **Low priority:** 73 existing warnings and 382 existing information diagnostics remain catalogued for later cleanup; no new findings are introduced.

**Release decision: hold production release.** Local verified fixes are complete and reviewable in the supplied patch. Security deployment, staging financial/dispatch regression and device evidence are not complete or explicitly accepted. The existing UI, payment formulas, business flow contracts and production database were preserved.
