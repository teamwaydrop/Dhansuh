# Owner-local completion prototype: intentionally unwired

## Current decision: defer completion-driven Earnings refresh

Preserve existing Realtime, tab-activation and remount refresh behavior. Keep
this prototype unwired and add no notification-driven GETs.

The unresolved product decision is whether to permit independent UI groups with
explicit stale indicators, or additional dependent rereads before atomic
publication. Neither policy is approved for implementation by this decision.

Intercity completion identity must come from trustworthy server evidence, such
as a validated existing terminal response/event containing the stored completion
timestamp. Never generate a completion version from client time or infer one
from an acknowledgement that lacks that evidence.

The new gate and handoff are not imported by any screen. Existing routes, queries,
publishers and refresh behavior are unchanged. Each navigation owner creates its
own gate; each consumer creates its own handoff and disposes it independently.

## Evidence and ownership

A producer must verify the initiating account/rider and authoritative terminal
order response before constructing confirmed evidence. A local `confirmed` enum
is not authentication or proof by itself. Timeout/unknown outcomes and
payment_pending transitions are not confirmed completions. The server version
must identify the terminal completion, not a later arbitrary row edit; it is a
UTC instant parsed only after the producer validates the timezone-aware wire
timestamp. RPC/Realtime evidence for that same completion must share the same
version. The gate rejects duplicate/older versions regardless of source/status.
If this version/operation identity cannot be established, do not wire the gate.

Identity changes and owner retirement must increment the owner generation BEFORE
replacing the bound account/rider. Rebinding A after B cannot revive A's old
callbacks. Disposed gates cannot be revived. These are caller obligations,
not subscriptions to a global auth service.

## Pending-only handoff

Only after gate acceptance, invalidate the relevant exact query scope. Keys
include account, rider, owner generation, the complete query contract and the
unchanged captured cutoff instant. Never substitute a new cutoff or merge a
recent-three query with a 30-day query. Idle invalidation has zero fetches.
An active query has one active attempt and one shared trailing attempt, even
after active failure. Ordinary callers share the publication-bearing future.
Old invalidated successes return null and do not publish. The trailing future
invokes the synchronous consumer callback only after current ownership and
revision checks; consumers must observe its errors. Distinct newer events during
a trailing attempt can legitimately require another attempt; the prototype
does not promise one trailing GET across the entire multi-query batch.

## Follow-up findings: existing completion identity

Local generic settlement source
`20260901000038_cashfree_pg_charge_wallet_gst_separation.sql:84-85,261-265`
sets completed_at/updated_at from server v_now and returns the order row.
`update-order-status/index.ts:632-662,1148` forwards this successful RPC row.
That server completed_at is a candidate terminal-transition identity; updated_at
alone is not, because other writes can change it. No client-generated time is
acceptable. The producer must validate the returned order/rider identity,
terminal status and timezone-aware completed_at, and use the stored same value
on Realtime replay. Deployed definitions and timestamp immutability are unverified.

The latest local intercity parcel payment confirmation definition
`20260906000000_fix_parcel_completion_travel_plan_status_sync.sql:162-163,225-232`
stores server completed_at but returns order_id/financial results WITHOUT that
timestamp or the order row. Active Order's RPC success branch updates only local
order_status (`rider_active_order_screen.dart:1586-1600`). It therefore cannot
construct a versioned completion notification from that acknowledgement alone.
An existing subsequent authenticated Realtime/read response could provide the
stored timestamp; no new request is authorized to obtain it. Missing evidence
must leave the existing fallback intact, not invent an operation version.

## Smallest proposed batch integration and precise blocker

Use a consumer-owned draft with account/rider/owner generation, exact captured
30-day cutoff, batch revision and an observation slot per participating query.
Trailing results populate that draft, never invoke setState independently.
Only after all affected slots have compatible current revisions, exact-count
validation passes and the widget's existing identity/disposal/observation guards
pass may its existing prepared totals/history callback publish atomically.
Retain unaffected slots ONLY after proving their independence from completion.
No route or publisher change has been made.

Concrete blocker: a profile query can finish before completion while 30-day
orders is still pending. Pending-only invalidation refreshes orders but starts
zero GETs for the now-idle profile scope. The old profile observation cannot
become post-completion evidence. The existing publisher rejects this batch.
Replacing that guard with acceptance of the trailing order alone would mix
revisions; refreshing the idle profile would violate zero-idle-GET semantics.
Therefore universal fresh publication requires either a separately approved
per-field partial publication contract, explicitly allowed dependent rereads,
or deferral until the next existing complete refresh. Fresh evidence can be held
in a draft, but publication progress cannot honestly be guaranteed yet.

Focused tests preserve the cutoff and atomically hand off one complete test
draft. A boundary test demonstrates that the real single-query handoff itself
does NOT validate the revisions of other inputs. This is not a test of the
existing widget publisher and is not permission to bypass its guards.

## Integration boundary: still blocked

Rider Earnings currently awaits several independent queries, checks their
observations and a batch revision, then calculates and atomically publishes
30-day totals/history in one setState. A trailing single-query result cannot
simply mutate this state: the original invalidated batch is discarded, while
activity/active-order inputs and independent rows may have incompatible versions.
The prototype tests a real handoff into an atomic test consumer, NOT the existing
widget publisher. No claim is made that integration is complete.

Before wiring, specify a batch-owned assembly that consumes the trailing future,
validates same-account complete order rows with exact count, retains compatible
captured inputs and rechecks all consumer revisions immediately before the
existing atomic publisher. Reject mismatched evidence without publishing partial
totals/history. Do not refresh unrelated queries to hide this missing contract.
Notification-entry routing also remains on its existing fallback path.

Tests cover gate acceptance/rejection, RPC/Realtime deduplication, account and
generation retirement, idle zero-fetch behavior, six callers sharing one query,
one trailing fetch, active failure, near-completion invalidation, distinct cutoff
scope, and disposal/identity fences. All are local fakes, not backend/load tests.
