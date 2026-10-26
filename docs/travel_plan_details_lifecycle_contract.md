# Travel Plan Details lifecycle contract — implementation pending

## Parent ownership requirement

Every parent/navigation entry point must associate the plan with the authorized
account and rider that supplied it. Home, Intercity Bookings and Notifications
currently push snapshot props; this alone does not guarantee route retirement
when authentication changes. AppStartScreen's Login-exit pop is not such a
guarantee.

On account/rider/plan replacement, the parent must either supply an authorized
replacement plan for the current account or explicitly retire the old route
through a proven navigation-owner path. Never reinterpret account A's plan as
account B's plan, even if account B has become the current session. Do not infer
ownership from a display name or client-provided rider ID alone; preserve server
authorization/RLS checks.

Neither automatic route retirement nor a new screen-re-entry requirement is
chosen here. The unresolved parent decision is which entry points can deliver
verified replacement props and which must explicitly retire their owned route,
including any dialogs/child routes. Establish this before implementation.

## Generation-scoped rebinding

The scope includes account ID, rider ID, plan ID and a monotonically increasing
generation. Increment/retire the generation synchronously BEFORE clearing old
state or awaiting resource cleanup. A -> B -> A must not revive A's old work.
An account change without an authorized replacement retires old work; it must
not initiate reads or actions against the old plan with new credentials.

For a verified replacement: cancel the old debounce timer; unsubscribe each
owned listener exactly once; clear matches, request maps and old operation/UI
state; then bind subscriptions for the new scope. Respect RealtimeManager's
listener ownership: unsubscribing this screen must not remove another owner's
pooled listener. Capture account/rider/plan/generation in each callback. Ignore
late callbacks from retired subscriptions, including callbacks queued before
unsubscribe. Recheck ownership after asynchronous cleanup before binding new
resources, so a second replacement/disposal cannot install obsolete listeners.

Both `_loadIntercityRequests()` and `_loadMatches()` capture that scope BEFORE
request start and validate it after every relevant await and immediately before
publishing state or error feedback. Preserve their distinct projections,
filters, enrichment and error meanings. A retired failure must not reset a new
scope's loading state. Never apply results merely because `mounted` is true.

Resume and Realtime callbacks target only the current verified scope; preserve
the existing 500-ms debounce. Post-write continuations capture the initiating
scope and revalidate before refresh, parent callbacks, feedback and UI cleanup.
This does not cancel or undo a server write already sent. Disposal retires the
generation first, cancels debounce/listeners, and prohibits later publication
or subscription creation. No polling/coalescing changes are authorized here.

## Runtime test seam and required tests

Use a retained widget with a stable key under a parent harness that supplies
explicit authorized account/rider/plan props. Mock the existing Supabase HTTP
transport for both loader projections/enrichment, using request-start and
response Completers rather than delays. A narrow injectable subscription adapter
must return cancellable listener handles and retain captured callbacks so tests
can replay an old callback after cancellation. Production defaults must remain
the existing RealtimeManager path; avoid public mutable global test overrides.
Control post-write and unsubscribe futures as well. No real authentication,
customer records or backend calls are required.

Required behavioral tests:

- Same-key A/Plan1 -> A/Plan2 and A/Rider1 -> A/Rider2: only authorized new scope
  publishes; old requests/maps/loading/error feedback do not overwrite it.
- Account A -> B: without authorized replacement, no B request uses A's plan;
  with authorized B props, normal refresh/subscription behavior resumes without
  a new re-entry requirement. Test A -> B -> A with a different generation.
- Suspend each loader separately; replace scope and complete the old success
  or failure after a new result. Include `_loadMatches()` enrichment awaits.
- Replay old assignment/request/order callbacks and queued debounce after
  replacement. No requests/UI updates may originate from retired callbacks.
- Assert each old listener is unsubscribed once, pooled sibling listeners
  survive, and each current listener is bound once. Replace/dispose while
  unsubscribe is pending; no obsolete subscription may be created afterward.
- Dispose during either load, enrichment, debounce or post-write continuation:
  no subsequent UI mutation, request start, feedback or resource creation.
- Resume/Realtime/post-write triggers for unchanged scope preserve queries,
  loading/error behavior and navigation; future coalescing tests are separate.

Source-text assertions are supplementary and do not prove this lifecycle.
Runtime tests/seams are not implemented by this documentation-only change.
