# Rider Home Realtime responsiveness — local follow-up

Build59 and all previous fixes are preserved. This batch corrects four demonstrated Rider Home defects. It does not change production, issue log queries, deploy SQL/Edge code, disable required writes or claim to resolve the underlying Storage/database stall. New source changes are **after Build59**, with no new APK built in this batch.

## Reproduction

`test/rider_home_critical_path_test.dart` mounts the actual RiderHome widget with the pinned Supabase client, controlled HTTP responses and synthetic Realtime wire frames delivered through the existing SDK channel. Original source: **5 passes / 4 expected failures**:

1. While a display-only earnings request is held, a riders wallet UPDATE leaves the old wallet25 instead of publishing50.
2. An older wallet/online event waits for earnings. A newer offline event is applied first; resolving the earlier earnings request then incorrectly restores the older online state.
3. A503 earnings response in that callback replaces the previous confirmed earnings17 with0.
4. After the eight-second earnings deadline, a Home refresh starts a second actual earnings HTTP request while the original request is still pending.

This is a verified application wait/reordering/amplification problem, not a finding that these events initiated any historical database-wide incident.

## Minimum local correction

`lib/features/rider/home/rider_home_tab.dart`:

- **Lines164–185**, `_fetchTodayEarnings`: keep the visible eight-second deadline, but release shared request ownership only when the original raw query settles. Work is keyed by rider and cleanup is fenced to its own Future. A late timed-out response cannot become a successful visible result or update the successful-fetch dedupe timestamp. Completed work remains freshly queryable; no persistent earnings/eligibility cache.
- **Lines187–207**, `_queryTodayEarnings`: the original projection, gross-fare calculation, completed/delivered status filter and local-calendar-day UTC boundary remain. Only timeout/timestamp ownership moves to the wrapper. No wallet, tax, COD or payment write is introduced.
- **Lines628 onward**, `subscribeRider`: capture account ownership and ignore obsolete account/subscription callbacks. Existing pure-GPS filtering and financial-field relevance rules remain. Apply the rider payload and online status immediately; then start the existing guarded `_refreshHomeEarnings` without awaiting it. Offline tracking teardown no longer sits behind the earnings request. Secondary completion updates earnings only, never replays the earlier rider payload.
- The existing `_refreshHomeEarnings` preserves prior confirmed value on failure and exposes Unavailable. Its mounted/account/rider checks remain. The three-second cross-channel completion dedupe is preserved.

Structural query guards in `test/egress_fixes_3_to_10_regression_test.dart` now assert the single canonical nonblocking refresh caller and unchanged query math/filtering, rather than requiring the removed blocking callback call site.

## Measured results and test corrections

The nine actual Home widget tests pass after correction. Wallet state is published while the controlled earnings response is still unresolved; newest offline status survives the older completion; failed earnings retains17; timeout followed by refresh has **one pending earnings request instead of two**. This measures actual SDK HTTP counts and widget state ordering, not Android elapsed-time improvement. No fabricated millisecond saving or project-wide rate reduction is claimed.

Broader focused suite: **78 passed / 0 failed**, including Home earnings math, earlier query/realtime guards, completion/KYC transition tests and Storage transport recovery. Changed-four-file analyzer: **no issues**, exit0. Final full Flutter: **2,192 passed / 0 failed**, previous2,188 plus four new widget cases. Full suite and hashes: [verification](rider-realtime-home-20261102/VERIFICATION.json).

The first focused regression also caught an edit-time UTF-8 currency-symbol conversion; it was corrected and the final diff preserves all preexisting non-ASCII UI text. An intermediate full suite passed2,190 and failed two existing upload concurrency tests because their fixed30ms delay expired before file I/O/request start under suite load (observed request counts0, not duplicate writes). Those test assumptions were replaced with explicit request-start barriers; the five-way sharing case uses preloaded immutable bytes and still exercises the actual SDK transport. Independent owners wait until both actual POSTs have started. Test count/meaning is retained. No production upload implementation was changed for that fixture correction. Initial failures are retained separately from final results.

## Remaining limits and handoff

Raw HTTP cancellation is not introduced. A permanently hung same-rider query retains a timed-out visible result until transport settles; this bounds view waiting and suppresses duplicate work. The existing dedupe/fallback refresh schedule remains best-effort display reconciliation. No guarantee of globally ordered server events or exactly-once financial effects is added by this client change.

Production Storage504/57014 and shared backend admission/resource/lock latency remain unresolved; the prior service/onset capture plan remains required. No current incident is inferred without a supplied test interval. Real Android validation should cover financial events/order completion, online-to-offline transitions, slow/failed earnings, Home recreation and account switch. Live location policy, required KYC/eligibility checks, atomic acceptance, payment security and dispatch fallbacks are preserved.

Build59 remains the separately signed test artifact from the previous batch; these newest changes are local for a subsequent reviewed build. No artifact overwrite, version bump, deployment, paid resource or new project in this follow-up.
