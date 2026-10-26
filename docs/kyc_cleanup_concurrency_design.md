# KYC cleanup concurrency proposal — approval required

## Established source behavior

The handler checks `rider_kyc` references and separately invokes Storage removal. A reference writer can commit between those steps. Claimed-folder pruning has the same race. Upload paths are resumable generation paths with `upsert:true`; age and filename do not establish exclusive ownership. The fail-closed helper handles rejected/resolved errors but has no explicit deadline/abort signal. A never-settling lookup stalls the sequential scan. Cron's HTTP caller timeout does not prove server cancellation. This is source evidence, not an observed production incident.

## Proposed minimum shared protocol

Requires backend/security approval, exhaustive inventory of reference writers/readers, storage authorization and isolated integration validation. No implementation is authorized by this document.

- Establish immutable object/submission identity and account ownership; do not retrofit exclusivity onto current millisecond filenames. Identify all committed references, including legacy URL forms and other tables.
- Reference attachment/finalization and reclamation claim must serialize on the same authoritative object state. If attachment wins, cleanup cannot claim a referenced object. If reclamation wins, all writers must be prevented from attaching/reuploading that object while deletion is pending or complete. Client checks alone are insufficient; backend enforcement and Storage permissions must close bypass paths.
- Use a durable deletion claim and fencing token to bridge database coordination and external Storage I/O; do not hold a SQL transaction open across network deletion. Verify current claim before issuing removal. Claim expiry must **not** make an object attachable while an already-issued deletion could still finish. A new generation/identity or confirmed retirement is required; timestamp-only leases are insufficient.
- Track deletion acknowledgement separately from uncertainty. Lost acknowledgement leaves the object quarantined; reconciliation must verify Storage outcome before retirement. Never resurrect/reuse a possibly deleted identity. Retention, crash recovery and orphan authorization require explicit decisions. Keep current cleanup unchanged until the full writer/Storage protocol is validated.

## Deadline proposal and cancellation limits

Approve a reference-read budget from job/runtime constraints, not an invented constant. Deadline/rejection/malformed response means skip the object/folder, never authorize deletion. Use supported request abort where the pinned SDK/runtime permits; verify actual transport behavior. A Promise race only releases the caller: database work may continue. Fence late results, consume late rejections, and bound outstanding work so repeated timeouts do not create an unbounded backlog. On exhausted job budget, stop safely rather than launch more requests. This design adds no retry loop. Storage deletion timeout cannot safely be treated as failure-before-commit.

## Required deterministic and isolated tests

Controlled local futures/fake clock: never-settling reference read reaches approved deadline with zero remove calls; late success/error cannot authorize removal or cause unhandled rejection; missing/malformed results skip; cancellation unavailable/ignored still fails closed; outstanding-request budget prevents accumulating hung reads. Existing legitimate referenced/unreferenced cases remain covered.

Disposable database/Storage tests with synchronization barriers (infrastructure remains paused): writer commits before claim; claim wins before writer; two cleanup workers compete; late stale claimant after replacement; attachment after lookup but before removal; upsert to claimed identity; crash before/after issued deletion; acknowledgement lost; identity/account replacement during issued I/O; concurrent reference in each inventoried table. Assert no referenced object is removed, no new reference attaches to deletion-pending/deleted identity, one authorized claimant owns each removal, and unresolved I/O remains quarantined. Test grants/RLS/Storage enforcement and direct-write bypass attempts independently of client mocks.

Approval decisions: identity/state representation, writer migration compatibility, retention and uncertainty UX, cleanup service permissions, deadline/job budgets and isolated test environment. Re-reading references or adding a timeout alone does not resolve the concurrent deletion contract.
