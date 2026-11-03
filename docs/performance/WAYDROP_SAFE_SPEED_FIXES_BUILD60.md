# Safe performance/reliability corrections — Build60, November 3, 2026

The latest instruction authorized implementation following the read-only review. This follow-up makes local client/Edge corrections, prepares separate backend candidates and a signed Android test APK. **No production writes, migrations, Edge deployments, cron/config/policy changes, paid resources or new projects occurred.** Existing independent production fixes are preserved. Original incident initiating cause remains unproven.

## Disposition of the five requested areas

| Area | Completed here | Still required |
| --- | --- | --- |
| Security/concurrency | Fresh local verification of dispatch/push ownership, eligibility, acceptance, recovery and Chat policy/trigger candidates. New atomic photo SQL/handler candidate passes concurrency, reassignment, transition-failure, pre-commit crash and committed/lost-response replay checks. | Managed Auth/full triggers/intercity/provider coverage, all-writer lock-order review and controlled admission/drain before coordinated rollout. Existing combined SQL/Edge **NO-GO** remains. |
| Frontend / missing APK fixes | Latest Home/pricing changes plus new rider-proof upload/verification ownership are packaged in **1.0.0(60)**, same verified signer as59. | Install/test on the actual phone; app-start, completion→Home, GPS/KYC, booking, proof/OTP and offline/account-change journeys. Not published or phone-profiled. |
| Duplicate backend work | Existing signer/ETA fixes retested. New production-v75-based pricing candidate preserves independent config prefetch and original LIMIT-1 fallback while caching normal zone reads. | These Edge changes are review candidates, not deployed. Observe actual per-isolate reuse and provider/DB effects after a separately selected compatible rollout. |
| Storage timeout | Hardened rider-proof upload ownership/reconciliation and server photo download body deadline. Required Storage writes, checksum and authorization retained. | Actual Storage metadata SQL/wait/pool and host-resource onset evidence. This does not repair a demonstrated underlying Storage database timeout or prove Free-plan saturation. |
| Idle DB snapshot | No resource/pool assumptions, restarts or blind timeout increases. Only targeted Storage-policy and photo-column metadata reads were used here. | A zero-blocked idle snapshot cannot clear peak-time health. Prior narrow onset-capture plan remains necessary. |

## Client changes and safety

`lib/features/local_parcels/services/parcel_upload_service.dart:19,41` adds verification-byte upload using the existing uploader's exact-object byte/hash reconciliation and no automatic write retries. Paths are immutable and scoped by **order + pickup/dropoff + account + content hash**. `upsert:false`, `retryAttempts:0` and raw in-flight ownership remain. A visible20s deadline never authorizes a second overlapping POST. Byte snapshots prevent caller mutation changing the uploaded content after its digest is selected. Existing booking paths and behavior are retained.

`lib/features/rider/orders/services/rider_photo_verification_service.dart:15,46,62` owns the actual SDK verification request by account/order/rider/type/photo URL. Same-key concurrent calls and completed replay share the same result. A20s visible timeout retains the original request. Ambiguous server/network failure is not automatically POSTed again by this owner. Completed failure remains retained; new intent or operator reconciliation may be required. This is **screen-owner transport control**, not durable process-wide or server idempotency. A restart/new screen can lose this memory; the coordinated SQL candidate provides the separate durable guarantee.

`lib/features/rider/orders/screens/rider_active_order_screen.dart:422–495` now:

- Guards capture/upload ownership before and after asynchronous steps and prevents starting another capture while busy.
- Reuses immutable verification uploads instead of timestamp paths with overwrite/upsert.
- Starts upload and location/device acquisition together, retaining image quality and location accuracy policy. No measured handset second-saving is claimed.
- Checks account/mounted state before invoking verification and before subsequent UI/OTP work.
- Uses the owned verification service. Ambiguous timeout/result triggers a read-only proof refresh and an unconfirmed-state message, **not automatic bypass or another write**. Explicit existing business bypass remains for other failures.

The post-proof verification refresh and best-effort intercity OTP helper remain backend-dependent. This is not a guarantee that the entire proof journey completes within20s or40s; there are separate stages. Raw requests are not forcibly cancelled by a Dart Future timeout. KYC, COD/tax, fare, payment, order acceptance and mandatory proof checks were not removed or weakened.

Fresh read-only Storage policy metadata confirmed authenticated INSERT on `parcel_images`, public SELECT and owner-scoped UPDATE/DELETE; the new immutable `orders/.../verifications/...` object path does not conflict with a path-specific predicate in those captured policies. This is metadata compatibility, not a complete Storage-security clearance or managed upload test. Existing public bucket exposure and policy questions require separate review; no policy changed.

## Backend candidates

### Download body deadline

`supabase/functions/_shared/photo_download.ts:2` keeps the20s AbortController active until image body consumption completes. The previous header-only helper cleared its timer before `arrayBuffer()`. `process-verification-photo/index.ts:135` calls the new helper, preserving hash bytes and the existing early scope guards. Four controlled tests cover body stall after headers, pre-header stall, identical success bytes/timer cleanup and generic non-success handling. No arbitrary image-size limit or checksum bypass was introduced. This governs server re-download, **not the initial client Storage metadata-write timeout**.

[Legacy-compatible guard/body candidate](safe-speed-20261103/PHOTO_MANIFEST.json) preserves captured v18 dependencies, adding only the photo helper and revised handler. It still lacks atomic proof effects and must not be described as a complete photo pipeline fix.

### Atomic photo proof candidate

[PHOTO_ATOMIC_RPC.review.sql](safe-speed-20261103/PHOTO_ATOMIC_RPC.review.sql) adds a proposed service-only `record_order_photo_proof_v1` function. It is a review file, not an automatic migration and not installed in production.

- Locks order first, then pins rider ownership. Current assigned rider and verified actor are checked **inside the transaction**, so a stale handler snapshot cannot authorize effects after reassignment.
- Commits photo row, pickup completion flag, verification and security audit together. Any transition failure rolls everything back. Dropoff never sets pickup completion.
- Exact proof replay returns the same photo ID without repeated effects/timestamps. Order locking serializes concurrent calls. Existing partial/mismatched records fail closed with reconciliation required; no historical repair occurs.
- Revokes PUBLIC/anon/authenticated execution; service role only. The matching handler supplies actor from validated Auth, never a body-supplied actor. Zero latitude/longitude are preserved.
- Matching handler uses one RPC for durable effects, with generic error responses and no raw private failure text. A type-only timer annotation in its captured legacy HTTP dependency resolves the number/Timeout compile conflict without changing runtime behavior.

[Atomic handler manifest](safe-speed-20261103/PHOTO_ATOMIC_MANIFEST.json) and [actual handler/native tests](safe-speed-20261103/photo_atomic_handler_test.ts). Compared with the original pickup handler, its two existing table reads plus four separate write requests become two reads plus one RPC: **six Data API requests→three** for that path. The same four required logical effects still occur; new authorization/idempotency queries are performed inside SQL. This does **not** demonstrate lower SQL CPU, lock time, WAL or total production latency.

The candidate is tested against captured column types and relevant synthetic FKs, not the complete managed trigger/RLS/Cron/financial environment. All order/rider writer lock orders, trigger behavior, Auth, old/new writer overlap and full acceptance/completion integration must be verified before rollout. It does not authorize every order-state business transition or replace dispatch/acceptance eligibility.

### Pricing v75 reconciliation

[Pricing manifest](safe-speed-20261103/PRICING_V75_MANIFEST.json) is built from the captured deployed **v75** source, preserving its independent config prefetch, fallback/retry behavior and calculation functions. Only the normal active-zone query uses the existing30s helper. **The original fresh LIMIT-1 fallback is intentionally retained**; no assumption is made that the first row of a full cached result must match a LIMIT-1 planner choice.

Actual-handler differential tests: three concurrent normal quotes issue **three→one normal zone reads**, identical synthetic fare responses and preserved config prefetch while zone work is held. Fallback responses and three per-request LIMIT-1 reads remain unchanged. Missing-field rejection remains400 with no reads. Four tests pass, including fixture cleanup. This candidate is not the older local pricing handler and is not deployed. Existing successful verbose request logging in v75 is not certified private by this limited patch; no real request data appears in these fixtures/reports.

Existing signer/ETA coalescing remains separately frozen against live-status v54; do not overwrite its deployed relation/location improvements with the older local handler. [Earlier exact candidate](edge-load-20261103/live-status-candidate.manifest.json).

## Verification

| Suite/check | Final result |
| --- | --- |
| Full Flutter, final post-format/source-contract correction | **2,204 passed / 10 existing live opt-in skips / 0 failed**. Previous2,193 plus11 new cases: five proof-upload, six verification-owner cases. |
| Focused Flutter uploader/verification/intercity guards | **37 passed / 0 failed** |
| Changed-six-file analyzer | **0 errors / 0 warnings / 6 existing infos**, exit1. Legacy screen deprecation/style infos remain; no ignores added. |
| Edge helper/body/pricing/corridor suite | **71 passed / 0 failed** |
| Legacy-compatible photo guard handler | **10 passed / 0 failed** |
| v75 pricing differential suite | **4 passed / 0 failed** |
| Existing dispatch/push native concurrency/crash groups | **17 passed / 0 failed** |
| Existing coordinated Edge + actual native RPC | **15 passed / 0 failed**, provider/Auth synthetic |
| Existing Chat native policy/trigger mechanism tests | **14 passed / 0 failed**, managed Auth not reproduced |
| New atomic photo native groups | **9 passed / 0 failed** |
| New atomic photo actual handler/native SQL | **6 passed / 0 failed**, includes transport cleanup case |
| Signed APK, source/candidate manifests | Pass; all182 frozen source files unchanged during build; all three AOT libraries differ from59 |

Atomic photo checks include eight simultaneous callers producing one set of proof/audit effects; denial after a competing reassignment while waiting on the order lock; rollback when each of four durable transitions fails; backend termination before commit followed by safe retry; and committed proof with lost response replaying without additional effects. These are real local PostgreSQL transactions with synthetic business fixtures, not actual production load/provider tests. Local PostgreSQL was stopped after completion.

Intermediate failures are retained: a native/Edge fixture overlap invalidated the first rerun; clean sequential17/15 runs passed. Formatter changed one implementation-string assertion's whitespace; the assertion was made whitespace-insensitive without removing the endpoint/scope check, and the final full suite passed. Atomic handler harness setup exposed legacy timer typing; the candidate carries the explicit type-only correction. No failing run is counted as passing evidence.

[Verification summary](safe-speed-20261103/VERIFICATION.json), [atomic SQL results](safe-speed-20261103/PHOTO_ATOMIC_RESULTS.json). Raw local logs: [full Flutter](../../.dart_tool/waydrop-local-runtime/build60-flutter-final.log), [focused](../../.dart_tool/waydrop-local-runtime/safe-photo-final-focused.log), [analyzer](../../.dart_tool/waydrop-local-runtime/build60-analyze-final.log), [native dispatch/push](../../.dart_tool/waydrop-local-runtime/safe-speed-native.log), [Edge/native](../../.dart_tool/waydrop-local-runtime/safe-speed-edge-native-final.log), [Chat](../../.dart_tool/waydrop-local-runtime/safe-speed-chat-native.log), [atomic photo](../../.dart_tool/waydrop-local-runtime/safe-photo-atomic.log), [atomic handler](../../.dart_tool/waydrop-local-runtime/safe-photo-atomic-handler.log), [pricing](../../.dart_tool/waydrop-local-runtime/safe-pricing-v75.log).

## APK and release boundary

[waydrop-1.0.0-build60.apk](../../artifacts/waydrop-1.0.0-build60.apk), package `com.waydrop.app`, version1.0.0(60), same verified signing certificate as59. SHA256: `6217fa6893ddf703baa084dff9a6b168ed3269e762f9383cf317653d1cbebb0c`. [Verification](safe-speed-20261103/APK_VERIFICATION.json). Build59 is retained. No plaintext .env asset found. No install, publication, actual phone speed measurement or production backend deployment inferred.

Client test candidate is **CONDITIONAL**; it includes prior local Home/pricing fixes plus this proof ownership change, without requiring the new RPC to function against the current endpoint. It does not remove the existing production endpoint's security/atomicity limitations. Whole-app release/security GO is not granted.

## Required rollout sequence and outstanding resources

1. Use an approved isolated managed environment with current full schema/triggers, test JWTs/roles, Vault/pg_net/Cron/Realtime, synthetic orders/intercity actors and safe FCM destination. Only production is currently available in the established workflow; the previously declined project creation remains respected. No new environment or paid resource was created.
2. Validate Chat restrictive policies, coordinated dispatch/acceptance/push and atomic photo candidate independently, including all writer lock ordering, crash/replay, eligibility/financial invariants and old-client compatibility. Native success does not waive these managed checks.
3. Freeze current production definitions/ACLs/versions again before any selected rollout. Never blanket-push pending migrations or replace entire older local handlers.
4. For atomic photo: reviewed additive service-only RPC first, then close old photo-writer admission and prove old invocations/transactions drained before compatible handler activation. Do not rolling-mix with legacy non-atomic proof writers. Preserve existing proof/audit rows. Existing combined dispatch/push cutover requires its own stronger writer-drain procedure.
5. On regression, close admission/fail closed and prefer a forward correction. Do not restore a known missing photo-authorization guard or unfenced financial/dispatch writer, delete delivery/proof state, or reset uncertain sends to pending. Unused additive RPC rollback/removal is considered only after no callers remain; no rollback executed here.
6. Device-test Build60 and measure matched startup/Home/completion/booking/photo latency. The original Storage SQL57014/DatabaseTimeout and reported504 mechanism still require narrow request/wait/pool/resource correlation; no claim that Free plan, CPU/I/O or the initiating cause is solved.
