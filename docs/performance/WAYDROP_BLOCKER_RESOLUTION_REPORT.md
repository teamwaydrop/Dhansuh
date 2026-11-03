**Later rollout status:** [Authorized independent changes](WAYDROP_AUTHORIZED_ROLLOUT.md) shipped workload-only SQL fixes, rejection v19 and internal RPC ACL restrictions. The coordinated five-blocker protocol described here is still not deployed; its remaining managed/drain gates are unchanged.

# Waydrop: five blocker implementations and release gates

Date: 2026-11-02. Production project: `yvwpchffctiagevpqgwy`. **Local implementations only; no production deployment, migration, policy, trigger, cron or configuration change.** One bounded production metadata query retrieved acceptance function definitions; zero incident log queries or user-row reads were needed. No paid resources were created.

The five demonstrated defects now have coordinated local SQL/Edge corrections and deterministic tests. This is **not production approval**: managed integration, business-rule signoff and admission/drain validation remain blocking gates. The November 1, 16:22–16:34 UTC initiating database slowdown remains **unproven**. These changes address verified concurrency/reliability defects and workload amplifiers, not an established CPU/RAM/I/O cause.

Read with [Part 3](PART_3_DISPATCH_CRON.md), [Part 4](PART_4_CHAT_NOTIFICATIONS.md), [Part 5](PART_5_FINAL_VERIFICATION.md), and the [deployment checklist](WAYDROP_PRODUCTION_DEPLOYMENT_CHECKLIST.md). Those historical findings are retained; the candidates here supersede their unsafe dispatch/push recovery implementations.

## Implementation inventory

Exact declaration lines for every candidate SQL function/trigger and TypeScript helper are in [SOURCE_LOCATIONS.json](blocker-resolution/SOURCE_LOCATIONS.json). Line numbers below refer to this candidate; exact SHA-256 hashes and baseline source comparisons are in [VERIFICATION.json](blocker-resolution/VERIFICATION.json).

| File | Relevant locations / change |
| --- | --- |
| `docs/migration-review/not-applied/20261102044001_waydrop_dispatch_fencing_and_delivery_outbox.sql` | 4 private schema; 11 dispatch ledger; 33 shared eligibility; 75 transport kick; 95 request; 110 claim; 133 atomic step; 214 conditional release; 229 delivery ledger; 247 aggregate; 282 claim; 319 send intent; 336 outcome; 359 bounded recovery. **Additive, disabled by default.** |
| `docs/performance/blocker-resolution/CUTOVER.candidate.sql` | 4 fingerprint guard; 24 public matching wrapper; 38 intercity wrapper; 60 order guard; 81 assignment guard; 111 KYC serialization; subsequent former writer/trigger/cron wrappers and inbox/outbox cutover. Separate coordinated activation candidate, **not applied**. |
| `supabase/functions/start-dispatch/index.ts` | 2 pinned SDK; 4 durable runner; final request/background branches retain existing authentication and participant checks, eliminate split REST worker writes/self-chaining. |
| `supabase/functions/start-dispatch/durable_dispatch.ts` | 3 checked RPC; 10 bounded runner; claim/step/token-conditional release; waits outside SQL transactions. |
| `supabase/functions/accept-order/acceptance_sql.ts:2` | Encoded transaction adds shared eligibility before writes, fails closed when absent. Readable generated [SQL review copy](blocker-resolution/ACCEPTANCE_SQL.review.sql): 34 rider lock, 41 order lock, 100 helper presence/eligibility gate. Existing fare, promo, assignment and idempotency logic retained. |
| `supabase/functions/send-push-notification/index.ts` | 2 pinned SDK; 109 handler; 120 persistent ID; 134 recipient-scoped claim; 143 token-scoped acknowledgement; 166 send intent; 217 bounded provider call. Canonical content loaded from stored notification. |
| `supabase/functions/send-push-notification/delivery_result.ts:1` | Typed outcome, Retry-After and existing preference rules. |
| `supabase/functions/_shared/http.ts:28` | Buffered deadline includes stalled response body, abort propagation, null-body statuses. Existing timeout helpers retained. |

All `lib/` files remain byte-identical to the start-of-task snapshot. Previous Passenger Home, GPS, Realtime, chat UUID/outbox/reconnect, notification badge, security and dispatch/rejection fixes are preserved. Historical draft migrations are retained but excluded from blanket deployment. Existing acceptance-only frozen manifest is **superseded for this changed payload**, not silently edited.

## 1. Stale-worker fencing

**Before:** Part 5 demonstrated that timestamp-CAS release did not protect subsequent order-state writes or assignment upserts. A paused owner could resume, overwrite replacement state and reopen an accepted assignment.

**Correction:** Every claim increments a durable generation and creates a random ownership UUID. The worker has no direct state/offer/expiry/audit writes. `step_order_dispatch` locks candidate riders in ID order, then order, then job, validates token/state/live lease under the job lock, and applies all mutations in one transaction. Candidate eligibility is checked again after rider/order locks. `release_order_dispatch` uses the same ownership/expiry predicate. A committed step clears ownership, so replay cannot apply it twice. Storage failure returns 503; there is no unfenced fallback.

Cutover database guards reject unfenced local offers/order-worker-state writes, accepted assignment reversal and accepted assignments inconsistent with the parent winner. Acceptance still locks rider then order and commits parent, assignment and audit atomically. Intercity acceptance wraps the captured original transaction instead of rewriting its fare/capacity code. Manual intercity negotiation remains distinct from automatic local dispatch.

**Reproduction/result:** Independent PostgreSQL sessions claim once among 12 competitors. Old claim → fixture lease expiry → replacement claim → old step/release both rejected, replacement step succeeds; **0 stale state writes, 0 stale releases**. Transaction rollback removes offers/audit/state together. Actual runner loses a committed step response, attempts conditional release, and replays with **0 additional offers**. Atomic acceptance race has **one 200, one 409, one accepted assignment**; winning retry is idempotent and synthetic fare stays 90. Accepted→sent reversal is rejected.

This does not replace a hosted old-invocation admission/drain rehearsal. Old Edge and privileged direct writers must be stopped/drained before activation. Do not deploy the earlier stale-flag recovery candidate.

## 2. Rider eligibility parity

**Before:** Part 5's offline service-call fixture still produced one offer. Separate SQL/Edge writers disagreed on KYC, status, location and financial checks.

**Correction:** One helper checks approved/active KYC linked to the rider's user and KYC ID, `blocked_until`, online status, service mode, vehicle/weight compatibility, self-order, existing active work, COD limit, government tax threshold, configured search lifetime and valid/fresh coordinates. Every automatic writer now requests work through the same atomic step. Public six-argument matching retains its captured ownership/distance logic and filters through the helper. Both ordinary and intercity acceptance use the shared eligibility gate. KYC status/activation/block/vehicle updates acquire the rider ownership lock so revocation serializes with offer/accept writes.

**Business distinction:** Ordinary acceptance remains a fresh authorized available-order claim; an expired/rejected offer is not a capability, and possession of an old offer cannot bypass current eligibility. Existing direct acceptance semantics are retained. Re-offering requires expiry/rejection, a higher rider earning and elapsed cooldown; live offers count against the configured batch. Intercity's captured transaction still validates request expiry, negotiation state, plan capacity and passenger conflict.

**Explicit behavior change requiring signoff:** Canonical approved/active KYC and configured location freshness are stricter than permissive pending/null KYC or 24-hour fallback paths. `riders.is_verified` alone does not override authoritative KYC. This is visible and gated, not an assertion that existing permissive rules were already equivalent. Intercity multi-booking/future-trip business behavior requires managed review before approval.

**Result:** Ten denial fixtures (offline, KYC, activation, mode, COD, tax, stale GPS, vehicle, self-order, expired search) assert offer/accept parity, all five request entry paths, no offer to the denied rider, and public matcher exclusion. An actual two-session test observes KYC revocation waiting on the rider lock, then verifies subsequent matching denies it. Eligibility paths preserve the existing active-trip helper. Full production intercity transaction execution is **not claimed**: the native fixture uses a stub legacy transaction; the actual captured body is in [ACCEPTANCE_CAPTURE.json](blocker-resolution/ACCEPTANCE_CAPTURE.json).

## 3. Duplicate dispatch enqueue

**Before:** New-order, rider-online/freed, rematch, Edge starts and two cron paths could independently enqueue/match/write offers. A short-lived process boolean could not provide durable deduplication or crash recovery.

**Correction:** One durable job per order with request revision, current token/generation, next due time, queued transport lease and last error. All former automatic writers converge to `request_order_dispatch`; only the fenced SQL step writes offers. Enqueue is best effort **after** durable intent, not the source of truth. Existing minute/45-second fallback functions recover bounded due jobs and catch committed searching orders missing a job. No schedule is changed or fallback disabled. Already queued/live leased jobs are excluded from recovery batches; selected IDs are processed consistently. Transport failure retains intent and retries after eight seconds. Crash before claim expires the queue lease; crash during claim expires worker ownership; committed step has durable next due time.

**Result:** Actual order-created trigger plus 12 concurrent requests → **one job, one HTTP enqueue, one claim winner**. Five entry paths → one job/kick and no direct offers. Lost step response adds no offers. Rollback cannot leave orphan offers. A batch-limit-one fixture skips the already-queued oldest job and kicks the next due notification. This is bounded queue coalescing, not a claim that HTTP itself is exactly once: transport may replay, but current SQL generation has one owner.

## 4. Concurrent push replay

**Before:** Part 5 verified concurrent processing of one notification sent twice; sequential `push_sent` checks were insufficient. Unscoped aggregate writes and token deletion also risked partial-success loss.

**Correction:** Service-only RPCs lock the parent delivery job, snapshot recipient registrations once and claim per-device work with unique tokens, registration version and leases. `begin_notification_device` persists send intent before FCM; `finish_notification_device` validates the same ownership and recipient. Partial successes persist per device; retry claims exclude successes. Only a typed FCM `UNREGISTERED` outcome can delete a token, using recipient + device ID + exact registration timestamp CAS. Generic 404 never deletes registrations. A server-side registration-version trigger advances the timestamp when token or recipient changes, even if a client preserves the old timestamp; stale cleanup cannot target a replacement token. Canonical recipient/title/body/payload come from the inbox; request bodies cannot forge them. Clients cannot execute delivery/status RPCs or access the private ledger.

**Result:** Twelve concurrent SQL claims produce two claims for two registrations; **zero replay claims**. Eight simultaneous actual push handlers make **two provider calls for two devices**, and replay makes none. Foreign recipient/invalid Auth is denied before mutation. Refreshed registration survives a stale UNREGISTERED acknowledgement. Partial success is retained while only its transient sibling retries.

## 5. Durable delivery recovery and guarantees

Inbox insertion and outbox intent are in the initiating transaction. Essential storage failure now rolls that transaction back instead of silently losing its notification; async transport failure is caught only after durable intent. Existing stable-ID chat retries can recover a failed transaction. Direct legacy push calls without a persistent notification ID are rejected; captured database callers supply it. No historic failed inbox rows are bulk replayed automatically.

Device states: `pending → claimed → sending → sent`, with explicit `retry`, `terminal`, `skipped`, `uncertain`. Five attempts maximum; exponential 8/16/32/64/120-second retry delay, quota minimum 60 seconds, bounded Retry-After up to 3,600 seconds. Repeated pre-intent crashes exhaust the same budget. Existing recovery crons enqueue due/abandoned work. Aggregate statuses distinguish partial success, terminal failures and uncertain delivery; unchanged public aggregate status is not rewritten on replay.

**Guarantee and unavoidable limit:** The database guarantees durable intent, atomic claims and no automatic resend of a committed ambiguous send attempt. FCM receipt and PostgreSQL commit cannot be one transaction; FCM has no transactional idempotency key. A crash after durable `sending` but before the network call can therefore leave an **undelivered `uncertain`** item. A crash after provider acceptance but before acknowledgement also becomes `uncertain`. Neither is blindly resent. A late same-owner provider acknowledgement can settle it, but no automatic/manual replay endpoint bypasses uncertainty. Device collapse identifiers are an additional presentation aid, not an exactly-once guarantee. Delivery to every device is **not guaranteed**; operators must reconcile uncertain/terminal states. Product acceptance of this conservative policy remains a release gate.

**Crash matrix:** Roll back before inbox/outbox commit → neither persists. Roll back snapshot/claim → snapshot remains incomplete. Crash after claim, before send intent → recover after lease with new token; old begin rejected. Roll back send intent → claim remains. Crash after committed send intent, before/after provider request → uncertain, no second automatic send. Roll back acknowledgement → sending remains; committed acknowledgement lost to Edge → replay suppressed. Terminal/aggregate state lives in the database and survives handler termination. Tests cover these boundaries with real SQL rollback and injected actual-handler interruption. They do not prove real FCM receipt.

## Verification and measurements

| Verification | Result / boundary |
| --- | --- |
| Native PostgreSQL 17.11 | **17 groups passed, 0 failed**. Independent sessions, row locks, rollback, tokens, bounded retry, eligibility, acceptance and recovery. [Native evidence](blocker-resolution/NATIVE_RESULTS.json). |
| Actual Edge handlers/runner + native RPCs | **15 passed, 0 failed** under `--deny-net`; Auth/preferences/provider synthetic, actual signing, actual SQL transitions. |
| Production dependency type check | Dispatch, push and acceptance Edge handlers pass frozen, cached lockfile checks using pinned SDK 2.118.0; test mock import map is not used for this check. |
| Full Flutter | **2,118 passed, 0 failed**. Six source-contract fixture files updated for equivalent canonical SQL/RPC behavior; no tests removed/skipped and no `lib/` changes. |
| Analyzer | **0 errors**; existing **73 warnings / 384 info** remain. One intermediate closed-pipe crash was retried. An introduced unused test variable was removed. |
| Fresh synthetic restore | Saved guarded fixture restored successfully into a fresh fixed loopback database, then native suite passed. Managed Supabase restore is not claimed. |

Initial full Flutter run after replacing the worker had 22 failures among 2,118, all obsolete Edge implementation-string contracts: 10 local-dispatch, four order-delivery, one distance writer, one CRLF payload fixture, four feature-gate flow and two OAuth/status-flow assertions. They were changed to assert the same behavior at the canonical SQL/owned RPC layer. Focused six-file suite passed 135 tests before final full run. The distance fixture's unused old source variable was subsequently removed and rechecked.

Measured **operation counts**, not production latency: 13 overlapping dispatch events → one enqueue; 12 claimers → one owner; 8 concurrent push handlers × 2 devices → two provider sends; replay → zero additional sends; stale owner → zero writes; acceptance concurrency → one winner. Part 5 supplies the before-defect counterexamples (stale state overwrite, one offline offer, two concurrent sends). These are not matched production throughput benchmarks. No new claim of CPU, WAL, I/O, end-user latency or incident workload reduction is justified. Historical cumulative pg_stat_statements was not used as causation evidence.

## Release assessments and remaining blocked changes

| Bundle | Assessment |
| --- | --- |
| Flutter reviewed subset | **CONDITIONAL GO**, unchanged: 2,118 pass and zero analyzer errors; managed/device/security compatibility gates remain. No application implementation changed in this task. |
| SQL coordinated candidate | **LOCAL VERIFIED / PRODUCTION NO-GO** pending independent business-rule acceptance, complete managed intercity/trigger/RLS/pg_net/Cron tests, drift/ACL capture, lock/load thresholds and old-writer drain. |
| Edge coordinated candidate | **LOCAL VERIFIED / PRODUCTION NO-GO** pending compatible SQL cutover, hosted JWT/RPC/time-budget tests, notification sink/device validation and acceptance admission/drain. |

Missing resources are an authorized isolated Supabase environment with complete current schema, actual Auth test JWTs, managed pg_net/Vault/Cron/Realtime, full intercity travel plans/capacity, a Firebase test destination/device, and Android profile hardware. Local emulation cannot replace these. No paid project was provisioned. Payment provider end-to-end effects are not exercised; existing atomic acceptance fare/idempotency invariants passed locally.

Still blocked: deployment/activation of all candidates; historical stale-worker recovery migration; old split-writer restoration; automatic uncertain push replay; broad historic notification backfill; blanket migrations/overload/index/publication changes; any claim of incident initiating-cause resolution. A full production GO also requires already documented security policy/ACL and rejection compatibility gates; this task does not erase them.

## Migration ordering, rollback and operations

1. Freeze exact candidate/dependency hashes and approval scope; independently capture current definitions, trigger dependencies, policies, owners/ACLs and deployed versions. Compare all replaced functions, not just four executable fingerprint checks. Retain pre-change snapshots in the operator's approved backup boundary. Historical review evidence is not current drift approval.
2. In an existing isolated environment, install the **additive disabled** migration, rehearse the complete coordinated cutover, verify negative JWT/roles and all real trigger writers, KYC transitions, intercity capacity/fare/idempotency, both recovery intervals, token rotation and FCM delivery. Establish queue-age/lock-timeout/error and matching-latency abort thresholds.
3. Only after explicit production approval: place order/offer/accept/push writer admission into the reviewed maintenance/fail-closed state, stop old invocation admission, drain outstanding invocations and database transactions, and prove no legacy writer remains. Queue/inbox intents must not be discarded. New code before SQL intentionally fails closed; do not casually rolling-mix old/new protocols.
4. Apply the reviewed additive migration, install pinned new Edge artifacts including the changed acceptance transaction and required shared helpers, then execute the separately guarded transactional cutover with explicitly reviewed fingerprints. It replaces writer functions/guards and enables runtime together. Existing cron schedules remain untouched. Reopen admission only after synthetic approved-boundary checks and record versions/hashes/times. No blanket `db push`.
5. Observe durable oldest due age, pending/running/expired claims, kicks/error codes, retries/terminal/uncertain counts, accepted-assignment invariant and managed DB locks/pool/latency under matched load. Use aggregate counts/status codes; never log raw tokens, notification text or personal data. Terminal/uncertain work needs a named operator and provider reconciliation procedure before GO. No ledger cleanup/backfill is automated in this candidate.

Rollback: before activation, disabled additive storage can remain. After activation, first close admission/drain and retain every job/device outcome. Prefer a forward correction. **Never restore old unfenced dispatch or split acceptance writers**, delete outbox/device state, or reset sending/sent/uncertain to pending. Fail closed while repairing; inbox remains authoritative. Restore captured functions/owner/ACL only through a reviewed protocol-compatible rollback with drift checks, and only after all new workers stop. Keep guards/ledger active until compatibility is proven. SQL transaction failure during cutover rolls back activation/wrapper changes; it does not authorize unsafe prior workers to resume. Push cannot be unsent and committed acceptance/payment cannot be rolled back by an Edge version change.

Reproduction commands, fixture safety guards and limitations: [README](blocker-resolution/README.md). The verification manifest records local raw logs and hashes; reports contain no production tokens or personal messages.
