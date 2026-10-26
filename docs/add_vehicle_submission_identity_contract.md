# Add Vehicle submission identity and storage contract

The screen captures account, rider, operation revision, files, type and normalized number before starting. It verifies the rider with the existing authenticated `riders.user_id` mapping, fences validation/compression/upload completion and insertion, and suppresses retired feedback/navigation. Account replacement retires the old form; an explicit rider replacement starts an empty form. Duplicate callbacks cannot submit while an operation is pending.

Storage remains the private `rider_kyc` bucket and `<account>/vehicles/<milliseconds>/<slot>.jpg`, with existing `upsert: true`, three flat attempts, 1500 ms delay and 30 s attempt timeout. Retired operations cannot start a subsequent helper attempt. Already-issued I/O cannot be retracted, and local tests do not establish production RLS or cancellation.

Automatic deletion is intentionally absent from this flow. A millisecond folder does not prove exclusive ownership across screens/devices; partial uploads and lost acknowledgements may leave objects present. An insert exception cannot prove that no valid record references the images. Existing shared rollback functionality is unchanged for other callers.

An unconfirmed insert retains uploaded objects and disables another submission from that form. The rider can leave and explicitly refresh My Vehicles before deciding whether to retry in a new form. No blind compensating write, polling, automatic retry, or record enumeration is added. Validation and pre-insert failures retain normal retry behavior.

Blocked storage reclamation requires an approved ownership/idempotency design: unique operation identity, authoritative reference/commit evidence, and permission to remove only proven unreferenced objects. Changing upload path contracts, server cleanup, RLS or database schema needs separate approval and isolated runtime validation. No such changes were made.

Local tests cover stage retirement, A-B-A, disposal, duplicate callbacks, uncertain commits, partial upload failure, preserved payload paths, actual helper HTTP retirement, and bounded logs. Device compression, real auth/Storage/RLS and lost-acknowledgement behavior remain unverified.

## Repository evidence and proposed ownership/idempotency contract (decision only)

All schema/policy evidence below is local repository evidence, not deployed configuration.

- `supabase/migrations/20260717000000_add_rider_vehicles_table.sql:13-46`: UUID `id` has a generated default and primary key; `rider_id` references `riders`; the three image columns are non-null text. SELECT/INSERT ownership is checked through `riders.user_id = auth.uid()`. No submission key or unique vehicle-number/image-path constraint is established by the inspected migrations. Table grants do not replace RLS.
- `supabase/migrations/20260801000000_kyc_upload_storage_policies_and_cleanup.sql:36-61`: Storage policies scope the first path segment to `auth.uid()`. This proves intended account scoping, not exclusive submission ownership, rider association, immutable content or absence of database references.
- `add_vehicle_screen.dart` captures an account and generates a millisecond folder per manual attempt. `uploadCompressedFile()` uses fixed slot names with upsert enabled. Separate tabs/devices can collide, and retries reuse a path. Existing object reference columns have no database FK to Storage objects.
- `vehicle_submission.dart` inserts without an explicit row ID or returned receipt. A new attempt can therefore create a new UUID row even for identical payloads. Only concurrent callbacks from the same mounted operation are suppressed; that is not server idempotency.
- `MyVehiclesScreen` selects only vehicle type/number/status/rejection reason. Its existing refresh can show a vehicle, but cannot tie it authoritatively to an uncertain submission. Apparent absence cannot exclude an in-progress/late commit.
- The backend search found direct vehicle INSERT plus read consumers, but no existing vehicle submission/finalization or vehicle orphan-reclamation endpoint. Person-KYC creation is a different contract and must not be reused.
- `cleanup-abandoned-kyc-uploads/index.ts:67-69,133` explicitly skips the `vehicles` subtree. Its person-KYC grace period is not a vehicle cleanup protocol; do not widen it.

### Recovery options with the existing schema

1. A targeted owner-authorized read matching rider plus all three exact image paths and immutable submitted fields can supply positive evidence of a matching committed row. Multiple matches, mismatches, visibility/read failures or no match remain unresolved. This cannot retrospectively establish a unique operation, and does not authorize deletion or a fresh insert.
2. Recommended smallest next client proposal: allocate the existing UUID primary key once per logical submission, retain it with an immutable payload scoped to the authenticated account/rider, and INSERT with that ID. After an uncertain acknowledgement, reconcile by that ID and rider; compare the whole submitted immutable payload. A plain retry with the same ID can create at most one row under the local PK contract. Duplicate-key errors require reconciliation, never automatic success or UPDATE/upsert of an existing row. Missing/hidden rows are not proof of cancellation. This does not deduplicate independently created submission IDs.
3. UUID-based row identity does not by itself solve Storage ownership. Approve an operation-specific namespace and immutable per-file content/path generation, retained across retries. Do not continue using upsert to overwrite objects after any record may reference them. Handling upload-conflict/lost acknowledgement requires trustworthy content verification; filename/path equality alone is insufficient.

The existing UUID column could support option 2 without a speculative migration, subject to authoritative schema/RLS/trigger confirmation and isolated tests. Persistence/resume and conflict UX are product decisions. Nothing in this proposal is implemented.

### Reclamation contract requiring backend approval

A deletion candidate must have authenticated owner/rider association, an exclusive immutable operation/object identity, authoritative reference inventory, and a terminal operation state that prevents later finalization. Age alone, an empty/erroring read, client disposal, or an expired session is insufficient.

Reference checks must include all approved consumers of this bucket (including `rider_vehicles` and `rider_kyc` image fields), fail closed on every error, and use exact canonical object identity. A reference-check-then-delete race cannot be solved with unrelated client GETs. A privileged internal backend workflow needs an atomic cancellation/reclamation claim that fences subsequent record finalization, plus a defined policy for already-issued Storage writes and any recreated unreferenced objects. Deletion must use Storage API operations; never delete metadata only. Existing service-role authentication patterns may guide design, but do not grant authorization to run or widen a cleanup job.

Account replacement/disposal retires client work, not server work. Do not retry/clean up A's operation with B's session. Returning to A must not automatically resume the retired generation. Already-issued upload/INSERT can finish; committed references remain protected regardless of client visibility.

### Decisions/evidence still required

- Approve stable row/submission identity and account-scoped persistence/recovery UX, including deliberate duplicate submissions versus retries and mismatched-payload conflicts.
- Approve immutable upload naming/content verification; current millisecond/upsert paths are insufficient for exclusive ownership.
- Approve retention policy, exhaustive reference inventory and privileged reclamation/finalization fencing design; validate the race protocol in an isolated database/Storage environment.
- Obtain authorized authoritative schema, grants, RLS, triggers and Storage-policy evidence before implementation or any deletion. No production inspection or cleanup was performed.

## Separate existing cleanup concern found during capability inspection

`cleanup-abandoned-kyc-uploads/index.ts:143-155` ignores the resolved error from the `rider_kyc` lookup. A failed lookup with null data becomes an empty reference list; an old qualifying folder can then reach deletion at lines 189-197 despite a committed reference. This is a source-established fail-open classification risk, not evidence that production deletion occurred. Subsequent local review prepared fail-closed resolved-error/shape handling and fake-handler regression tests; no deployment or real deletion occurred. See phase2_bounded_stability_validation.md. Concurrent reference commits and storage deletion remain unresolved; this does not authorize cleanup expansion.
