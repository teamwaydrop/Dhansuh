# Final six-ride actual-app capture checklist

Status: **protocol only; execution is not authorized**. No new ride capture or measurement is asserted. This is the single execution checklist, consolidating the earlier procedure in [the recorder reference](local_ride_diagnostic_recorder.md). That reference supplies implementation, coverage and historical local-test details; its earlier procedure is not a second authorization. Older non-production profiling prerequisites remain a separate scenario, not approval to use the production-connected app.

## 1. Approval gates — stop until each relevant gate is explicitly approved

Record the approver, scope and date locally for each gate. Approval never carries forward automatically.

| Gate | Required evidence / approval |
|---|---|
| A — Environment | Provision and independently verify a dedicated Windows build VM with network adapter removed/disconnected, no forwarding or host build daemon; stage approved source, SDKs and caches offline. No such environment is verified yet. |
| B — Validation | Approve offline task-graph/dependency validation inside that environment. Verify actual release graph excludes `:app:uploadCrashlyticsMappingFileRelease`, and any native-symbol/other upload tasks are absent or explicitly excluded. `--offline` alone does not block network access. Stop on missing dependencies; never retry online automatically. |
| C — Assembly | Separately approve diagnostic APK assembly with verified no-upload controls and protected local diagnostic defines. Keep VM disconnected through termination of Gradle, single-use daemon and all child processes. |
| D — Artifact | Verify package, public signing certificate, permissions, source manifest, APK hash and install/version compatibility. Preserve selected baseline `3c6af66a02ed3a6d7ad954def1b5647c12754910`, version `1.0.0+54`, unless a separate version decision is approved. Installed `1.0.0+55` is previously reported: do not attempt downgrade, uninstall or bypass compatibility checks. |
| E — Devices | Separately approve installation and launch of the diagnostic-enabled **main app**, including its normal production-connected startup integrations. |
| F — Rides | Explicitly approve named operator-controlled accounts/resources, exactly six sequential rides, permitted backend writes/notifications and any payment-related action. Agree safe locations, consent, cost/abort responsibility and recovery procedure privately. Do not invent accounts or bypass normal flows. |

The synthetic host `com.waydrop.diagnosticvalidation` is **not WAY DROP**. Its successful export test does not certify main-app startup, filesystem access, instrumentation coverage or ride behavior. Main-app package is expected to be `com.waydrop.app`; verify the approved artifact rather than assuming it. The selected diagnostic baseline is not verified as the installed production APK's source and may not reproduce its lag.

## 2. Acquisition preflight — after the applicable approvals only

- [ ] Create an access-restricted local evidence folder and acquisition ledger. Keep real account/device identifiers out of the report; use P1/P2 and R1–R6. No keys, tokens, exact locations, payment data or ordinary logs enter the ledger.
- [ ] P1 = passenger, V2338, Android 16; P2 = partner, CPH2381, Android 14, as previously reported. Confirm actual model/OS, role and approved account at execution time; record redacted device labels only in shared records.
- [ ] Record each phone's previously installed app version/build and available APK hash/provenance separately from the diagnostic artifact's version/build, source baseline/complete isolated diff manifest, APK SHA-256 and public certificate fingerprint. Mark missing provenance NOT AVAILABLE. Never infer source identity from version/signature alone.
- [ ] Verify approved backend/integrations and account ownership locally without printing credentials or adding verification requests. Only production exists currently; launching/testing requires E/F, not an assumption of a synthetic backend. Stop if the approved scenario cannot operate safely under normal business rules.
- [ ] Ordinary builds omit BOTH `WAYDROP_LOCAL_RIDE_DIAGNOSTICS` and `WAYDROP_DIAGNOSTIC_RUN_KEY`. Approved diagnostic builds require explicit `true` plus Base64 encoding of exactly 32 bytes from the protected, ignored local file. Verify schema/key validity privately; never display, generate or transmit a key through this checklist. Both phones must receive the same approved configuration/key.
- [ ] Confirm **Save diagnostic capture** appears in each actual app's Passenger/Rider Settings. Compare exported `capture_namespace` values locally before joining any records: matching namespace and matching order pseudonym are required. Different namespace means stop, not a timing adjustment. Namespace is a fingerprint, not a key to publish.
- [ ] Record UTC capture start/end, phone role, session start/restart and session age for every export. Treat wall-clock alignment as unverified unless independently established with a documented uncertainty. Do not change clocks during capture.

## 3. Six sequential rides

Do not overlap rides or switch accounts/roles. Use the same approved normal ride type/path unless the scenario explicitly specifies otherwise; label actual alternate paths. Do not force steps to fit a timing window or invent delay thresholds. Record actual elapsed session age to assess a possible long-session pattern without asserting one.

| Ride | Passenger / partner | Required sequence | Ledger fields to fill during authorized execution |
|---|---|---|---|
| R1 | P1 / P2 | Book → offer → accept → arrival/status → complete → export both | Session labels/age, pseudonym, start/end, interruptions, artifact hashes/gaps |
| R2 | P1 / P2 | Same authorized sequence | Same fields |
| R3 | P1 / P2 | Same authorized sequence | Same fields |
| R4 | P1 / P2 | Same authorized sequence | Same fields |
| R5 | P1 / P2 | Same authorized sequence | Same fields |
| R6 | P1 / P2 | Same authorized sequence | Same fields |

### Marker map to use for every ride

| Boundary | Available recorder evidence | Boundary not established |
|---|---|---|
| Booking | Handler `action`, SDK `requestStart`, `response`, successful returned-order `confirmed`; original retry attempts retain logical correlation | Hardware touch, wire send, server receive/processing/commit |
| Assignment / offer | Partner assignment-feed `realtimeReceipt`; Incoming Order Card post-frame candidate where rendered | Dispatch start, push delivery, sound/human notification; other offer surfaces lack precise first-visible marker |
| Acceptance | Home/Orders/Card/Travel Plan acceptance SDK attempts and acknowledgement; applicable order Realtime/application/frame markers | Gesture time uniformly; server commit; acknowledgement alone may lack returned status/version |
| Arrival / status | Active Order generic/alternate status and Intercity Bookings arrival attempts/acknowledgement | Generic action may include location/device preflight; initial swipe/dialog timing is not uniformly instrumented |
| Completion | Generic and alternate delivery/settlement SDK attempts/acknowledgement; applicable terminal Realtime/frame candidates | Payment/OTP interaction before invocation, transaction commit; closing route may yield no terminal frame |
| Reads / UI | Selected order/live-status/fallback SDK waits, Realtime receipt → accepted application → post-frame candidate | All HTTP traffic/hidden retries; actual GPU presentation, user perception or cross-phone delivery latency |

Use fixed manual milestone labels with observation source/precision for uninstrumented visible steps; do not assign millisecond precision to human observations. `server_version_candidate`/`updated_at` is ordering evidence, never commit time. Plan pseudonyms are not interchangeable with order pseudonyms.

## 4. Per-ride capture, export and retrieval

There is no start/reset capture button: enabled recording starts with the app process. Do not invent a per-ride reset. Keep approved sessions alive across the six rides where safe; record restarts and diagnostic-owner retirement. Account replacement can retire recording on retained screens; stop rather than silently continue with missing ownership.

1. Before each ride, enter its R label and session age in the ledger; confirm correct phones/accounts/build and active diagnostic Settings action. Use only authorized normal navigation/actions. Do not add backend reads, retries or polling for evidence.
2. Complete that one ride safely through the authorized ordinary flow. Note interruptions/route changes and visible milestones without sensitive details. Do not assume a missing event means the operation did not occur.
3. On P1 Passenger Settings and P2 Rider Settings, tap **Save diagnostic capture** once and require successful fixed feedback. Do not export ordinary logs. Export captures current sanitized `exportJson()` only; counters alone with no timeline events can return empty. Failure/empty capture is a stop condition to diagnose separately, not permission to repeat rides.
4. After separately authorized device access, confirm the actual app-specific storage root. Expected fixed path: `/sdcard/Android/data/com.waydrop.app/files/ride-diagnostics/capture.json`. Temporary file: `capture.json.tmp`. Retrieve P1 then P2 with the individually selected approved device, never an implicit default device:

   `adb -s <local-approved-device-selector> pull <verified-main-app-capture-path> <protected-root>/R<n>-P<1-or-2>-<session>.json`

   This is a future command template, not permission to execute. Keep full serials/paths private. ADB denial means stop: no root, extra permissions, raw-log, clipboard or upload fallback.
5. Preserve each retrieved original without overwriting; calculate SHA-256 locally and record size/hash/acquisition time in the ledger. Before the next save replaces the phone's fixed file, confirm both originals are retained. A second export safely replaces the fixed file; never delete unrelated files or manipulate a pending temporary file. Unexpected temporary-file residue/export failure requires stopping and review.
6. Validate offline without printing JSON: UTF-8 parses; at most 4,194,304 bytes (4 MiB); exact current recorder schema/field types/enums; no unexpected fields/raw identities; expected namespace, session and pseudonymous ride linkage; inspect `dropped`/skipped evidence. Use the existing exporter tests/schema contract, not an invented permissive schema. Preserve invalid originals securely for review; do not silently repair/truncate them.

Exports are cumulative per process, not six independent resets. Deduplicate overlapping exports by phone + recorder session + event sequence; operation/attempt numbers are local. Default timeline capacity is 2,048 events, oldest evicted; SDK observers are limited to 64, pending frame observations to 64 per owner, with ride deduplication and one scheduled frame callback per owner. Overflow drops evidence only. Export promptly after each ride to limit loss; completeness is not guaranteed by valid JSON. Never increase limits, add automatic exports or restart mid-ride to compensate.

Keep APKs, exports and ledgers access-restricted with agreed retention/access policy. Pseudonyms are not anonymization: an APK/key holder with candidate IDs may correlate them. Captures reveal activity timing and a wall anchor. Existing application logging/Crashlytics remains outside the recorder's privacy guarantee; do not collect/export it under this protocol.

## 5. Abort rules

Stop the scenario at the first wrong account/phone/build, disabled diagnostics, mismatched namespace, export/access/schema failure, unexpected production impact, unexpected payment behavior, unsafe ride/parcel condition or unauthorized notification/write. Do not create a replacement ride automatically. Preserve existing evidence; follow the separately agreed safe operational recovery process rather than improvising cancellation/payment/backend actions. Any unexpected external build-time upload/network activity invalidates build safety: stop and retain isolation until all validation processes exit.

No unapproved parcels, artificial payments, stress/load tests or customer interactions. Six ordinary rides are not capacity testing. Additional metrics/tools or production observability require separate authorization; do not attach raw HTTP/heap/log collectors as a fallback.

## 6. Offline analysis and final six-row report

- [ ] Validate namespace before cross-phone pseudonym matching. Never subtract P1/P2 `mono_us`: each Stopwatch origin is independent. Wall anchors alone do not synchronize phones. Cross-phone intervals require independently justified alignment and uncertainty; otherwise NOT CALCULABLE.
- [ ] Pair same-device events only by unique session, operation, attempt, ride and compatible status/version evidence. Keep retries/duplicate RPC/Realtime evidence distinct; do not count duplicate confirmations as separate rides. A timeout/exception is an uncertain server outcome, not proof of rollback. Missing/evicted endpoints = **NOT AVAILABLE**; unreliable duration = **NOT CALCULABLE**.
- [ ] Produce an event ledger with phone, R label, source (client action/SDK response/Realtime/application/frame/manual observation), monotonic time where available, wall anchor confidence and evidence gaps. No raw identities or exported contents in the public report.
- [ ] Produce one row for each R1–R6: booking action→confirmation; SDK start→response for booking/acceptance/arrival/completion; assignment receipt→offer frame where available; acknowledgement→matching application/frame on each phone; total action→visible milestone where uniquely paired. Cross-phone booking→assignment and backend→both-screens durations remain NOT CALCULABLE unless their required endpoints/clocks are actually observed and aligned. Include build/session age, evidence source and confidence for each value.
- [ ] Report instrumented SDK attempt counts, fixed failure/timeout categories, skipped/dropped events and available Realtime/GPS aggregate counters with coverage caveats. They are not all network requests, actual outstanding transport counts, GPS delivery proof or exhaustive reconnect totals. Frame/raster jank, memory, server/pool/Edge processing and push latency remain unavailable unless separately measured.
- [ ] Rank only measured phases and compare session age without inferring cause from coincidence. Classify explanations CONFIRMED / STRONGLY SUPPORTED / POSSIBLE / NOT ENOUGH EVIDENCE with supporting events. If evidence cannot isolate a phase, report **inconclusive**, exact missing boundaries and smallest next measurement. No root-cause, improvement or capacity claim follows from this checklist or six captures alone.

All gates remain pending unless supported by separately recorded explicit approvals. This documentation does not authorize provisioning, validation execution, building, signing, installation, launch or any ride/backend/payment operation.
