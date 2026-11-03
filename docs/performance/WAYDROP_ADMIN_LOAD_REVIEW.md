# Admin panel load — read-only review, November 3, 2026

Subsequent authorization: [production rollout preparation](WAYDROP_PRODUCTION_ROLLOUT_2026_11_03.md) implements the Dashboard/Revenue failure fan-out correction locally (58admin tests pass), builds a candidate ZIP and records why publication/coupled backend rollout remains blocked. The inspection findings below are retained as the before-state; other listed risks are not marked fixed.

**Conclusion:** the local admin source has avoidable workload patterns, and deployed revenue aggregation repeats work. The reviewed November3 **09:54–10:04 IST / 04:24–04:34 UTC** logs do **not** establish admin-panel activity as the cause of that slowdown. No admin/app implementation, database object, production configuration or deployment changed in this review.

## Actual panel located

React/Vite project: `C:/Users/karth/Desktop/waydrop-admin (7)/waydrop-admin`. Its configured Supabase project and existing built assets reference `yvwpchffctiagevpqgwy`. That verifies the intended backend, not that this particular local revision is the deployed website. The live URL/version was requested and remains unverified. [Source hashes](admin-load-20261103/SOURCE_PROVENANCE.json).

This is separate from `lib/modules/admin/admin_dashboard_screen.dart` in the Flutter app. That Flutter file polls every4seconds and performs4–5 sequential REST reads, including unfiltered orders and expired assignments, without an in-flight guard. **No reference/import/navigation to its AdminDashboardScreen was found outside its declaration in lib.** Its presence alone is not evidence that the user's running web panel or app executes that timer. Do not count its theoretical60–75requests/minute as observed production traffic.

## Confirmed work and risks

All React paths below are relative to the project root above.

| Finding | Exact source | Load implication / qualification |
|---|---|---|
| Live Tracking reloads whole available rider list and matching KYC on any rider UPDATE | `src/pages/LiveTracking.jsx:31`, `:85`, `:101`, `:130` | Subscription is to all rider UPDATEs, not only location changes. Normal reload runs two REST reads. Existing1500ms throttle, single-flight guard and hidden-tab suppression help, but under sustained events the ordinary automatic path can approach40reloads/80REST reads per minute per visible tab when requests are fast and rider list nonempty. This is a calculated ceiling for that path, **not measured traffic**; manual/visibility forced refresh can bypass the throttle. Multiple tabs multiply work. |
| No explicit pagination/limit in live map rider read | `LiveTracking.jsx:130` | Full returned list is refetched. Server row caps still apply, so this must not be described as unlimited returned rows or proof every rider is shown. KYC is read again even when only coordinates changed. |
| Ongoing timer does not coalesce active batches | `src/pages/Ongoing.jsx:17`, `:127`, `:183` | Visible-tab30second interval; manual refresh or visibility changes can overlap existing work. If a batch exceeds30seconds, another starts. Hidden-tab interval cancellation already exists and must be preserved. Existing limit300 and short-lived name caches reduce work; not an unbounded query. |
| Dashboard fallback amplifies failure | `src/pages/Dashboard.jsx:26`, `:42` | Normal fetch:3requests (chart, recent10trips, aggregate RPC). Any aggregate error triggers6more reads: **3 → 9 requests for that refresh**. This includes exact counts and all-paid-payment data. Under backend degradation it can add load precisely when the RPC fails. Existing60second cache, in-flight sharing and visible-only recursive scheduler limit cadence; it is not a four-second web dashboard poll. |
| Revenue fallback retrieves historical data | `src/pages/Revenue.jsx:22`, `:46` | Normal3requests; RPC failure adds3more, including all-paid-payment and completed-order reads. Existing5minute caching helps. Broad client sums may also be truncated by API caps. Adding an arbitrary row limit would corrupt financial totals; use authorized server aggregation and explicit unavailable states instead. |
| Server revenue RPC repeats aggregate inputs | Deployed `public.get_revenue_data(timestamptz)` | Captured definition has5payments aggregate subqueries, including repeated all-paid filters and duplicate total_revenue/total_collection sums, plus3completed-order aggregates. This is actual deployed SQL structure, **not measured runtime/IO cost**. One RPC does not mean one scan. Consolidating compatible aggregates is a useful targeted candidate, with exact financial/security parity tests required. |

[Deployed revenue definition](admin-load-20261103/REVENUE_FUNCTION.json), [deployed dashboard definition](admin-load-20261103/DASHBOARD_FUNCTION.json). Both are STABLE, security-invoker functions and include an `is_admin()` check; neither was executed during inspection. STABLE is not a shared cross-request result cache. Preserve authorization and existing amount/null/zero semantics when consolidating.

The Flutter support inbox **is** navigated from passenger/rider profile for admin/support roles: `lib/modules/support/screens/admin_support_chats_screen.dart:39` reads returned support-message history and deduplicates sessions client-side; `:94` repeats that read on every support INSERT without an in-flight guard. It subscribes through the existing Realtime manager and unsubscribes on disposal. This is a separate, source-confirmed amplifier when that inbox is open; no evidence says it was open during the incident.

## Incident attribution

Only **two bounded log queries** plus **two lightweight read-only catalog transactions** were used. Catalog sessions used a2second statement timeout. No business-row scans, aggregate execution, EXPLAIN ANALYZE or broad historical log scans.

The ten-minute endpoint/client-family aggregate checked riders, rider_kyc, payments, orders, rider_withdrawals, admins and dashboard/revenue RPC paths. It found:

- **0 Mozilla/browser-family requests** among those checked paths; observed matching request families were Dart and Deno.
- **0 get_dashboard_stats calls**; a separate exact-path check of the correct Revenue RPC, **get_revenue_data, also found0calls**.
- **0 matches** for this local LiveTracking rider projection in request query strings.
- Dart orders:283GETs, maximum18,622ms; Dart riders:149GETs, maximum19,991ms. These identify client families/latency, not an admin user's identity or SQL execution duration.

Evidence: [window client counts](admin-load-20261103/WINDOW_CLIENT_COUNTS.json), [Revenue exact-path count](admin-load-20261103/REVENUE_WINDOW.json), [main query provenance](admin-load-20261103/LOG_QUERY.sql). Generic user-agent matching is coarse. A custom agent, server proxy, another admin revision, direct SQL/editor or different window can escape these fingerprints. No full URLs, query-filter values, user IDs, messages, phone numbers or tokens were exported.

Therefore **admin source workload is a confirmed optimization opportunity; admin activity as the November3 incident initiator is unproven**. Current metadata is not historical deployment proof. November1/2 initiating CPU/RAM/I/O cause remains unproven as well.

`is_admin()` in an app timeout stack is not evidence an administrator was using the panel: RLS can invoke that helper for normal passenger/rider queries. The previously reviewed RLS candidate remains separate, unapplied and subject to its existing validation gates.

## Next targeted corrections

1. Confirm live panel URL/build before editing or publishing the sibling project. Capture a short admin-only request trace under an approved test session; avoid repeatedly opening live pages just to benchmark their expensive reads.
2. Live Tracking: apply validated realtime location/status payloads to existing markers; cache stable names/KYC separately; retain a bounded resync for reconnect, missed events, new riders and eligibility changes. Never remove recovery or live tracking blindly.
3. Ongoing: one in-flight batch, one queued refresh, disposal/account fencing and a bounded timeout/backoff that preserves raw request ownership. Retain hidden-tab suppression.
4. Dashboard/Revenue: avoid fan-out on timeout/500/429; show last-good data with freshness/error state. Handle missing RPC deployments explicitly rather than silently recomputing all financial history. Preserve accurate totals and admin access controls.
5. Consolidate revenue SQL aggregates locally and test exact results/security before proposing a separately approved migration. No financial totals cached across accounts, no broad service-role browser access, no blind index/cron/timeout changes.

This was an inspection-only request. No implementation changes or regression-test run was necessary; source arithmetic is not reported as a before/after production benchmark. Build62 APK is unchanged. Native/admin browser traces and historical resource/wait measurements are still required to quantify shared-backend impact.
