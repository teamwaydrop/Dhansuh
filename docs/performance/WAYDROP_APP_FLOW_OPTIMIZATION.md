# App flow correction — 2 November 2026

Scope: follow the user's visible waits through actual Flutter source, preserve previous corrections, change local code only. Production was not queried or modified in this follow-up. No APK was rebuilt.

## Confirmed Rider Home critical-path defect

Before this correction, `_loadRiderOnceMeasured` performed:

`riders + nested KYC read → await today's completed-order earnings → publish rider / hide full-screen skeleton → install subscriptions → reconcile assignments / GPS state`.

The earnings query is display-only and has an eight-second timeout. A delayed earnings response therefore held both the core Home UI and subscription/reconciliation startup behind an unrelated secondary read. This is an actual source-level dependency, not a claim that the user's phone always spent eight seconds there.

The real `RiderHomeTab` widget with authenticated synthetic Supabase responses reproduces the defect: while only the earnings response is withheld, the rider response has completed but **SkeletonLoader remains visible**. This assertion fails against the saved original source in `.dart_tool/waydrop-local-runtime/home-critical-before.log`. That baseline ran the first two widget cases: one expected critical-path failure and one disposal pass; later fixture additions were not run against the original source.

## Minimum local correction

Implementation: [rider_home_tab.dart](../../lib/features/rider/home/rider_home_tab.dart), `_refreshHomeEarnings` around line 195, cold-start seed refresh around line 269, primary publication/background refresh around lines 445–460 and earnings display around line 3865. Exact changes against the pre-follow-up file are in `app-flow-20261102/LOCAL_CHANGE.patch`.

The flow is now:

`riders + nested KYC read → publish rider / hide skeleton → start separate earnings refresh → subscriptions and assignment/GPS reconciliation proceed without waiting for earnings`.

The existing single-flight earnings read, local-day filter and gross-fare calculation remain. No additional periodic polling. A pending card says **Loading…**; failure says **Unavailable** and retains the previous numeric value internally instead of replacing it with a fabricated zero. A successful response updates the card only while mounted, for the original authenticated user and rider. Seeded cold-start background earnings uses the same guarded path.

No KYC/profile requirement, eligibility, online mutation, order acceptance, payment, proof verification, GPS tracking or Realtime subscription was removed. The core rider response is still required. This improves the client dependency chain; it does not make SQL or Storage respond faster.

## Actual widget regression coverage

[rider_home_critical_path_test.dart](../../test/rider_home_critical_path_test.dart) runs the production widget and actual Supabase SDK against a stub HTTP transport, not a duplicate implementation of its loader:

1. Withhold earnings: Home skeleton clears, assignment reconciliation request starts, then successful earnings updates to 42.
2. Dispose before response: no disposed-widget update.
3. Secondary 503: preserve previous 17, show Unavailable and keep core Home rendered.
4. Refresh Home repeatedly while earnings is pending: one shared earnings request; successful current-fare fallback updates to 21.
5. Sign out before earnings returns: late 99 cannot overwrite the old account's earnings display.

All **5 pass** in `home-critical-five.log`. Full Flutter: **2,128 passed / 0 failed** (previous 2,123 plus these five). Analyzer on the changed implementation/test: **no issues**, exit 0; this is not a full-project analyzer claim. The first combined focused attempt exposed fixture scheduling issues (Unavailable rendered one pump later; sign-out needs the test's real async zone); those were corrected in the fixture. That interrupted attempt is not counted as a passing run. Earlier fixture setup also omitted HTTP response request metadata; it was corrected before the meaningful original-source critical-path reproduction.

Controlled before/after: original widget keeps the full-screen skeleton while the earnings request is pending; corrected widget renders core Home and requests assignments while the **same response is still pending**. This removes the secondary wait from that critical path. Three Home loads share **one** pending earnings read. No real-phone millisecond improvement or overall SQL-volume reduction is claimed.

Final full-suite/analyzer results and exact file hashes are recorded in [VERIFICATION.json](app-flow-20261102/VERIFICATION.json). Logs live in `.dart_tool/waydrop-local-runtime/`: `home-critical-before.log`, `home-critical-five.log`, `home-critical-full-flutter.log`, `home-critical-analyze.log`.

## Other traced waits and why they remain

| Flow | Actual dependency and next boundary |
|---|---|
| Startup, `lib/app_start_screen.dart:125–181` | Config/profile already start in parallel. Maintenance/version checks and authoritative profile routing remain required; bypassing them would weaken policy. Previous configuration failure coalescing correction remains local. |
| Passenger Home, `lib/features/user/home/home_tab.dart:735–890` | Users/riders/KYC/orders are already parallel with profile reuse, but a slow member holds the batch. Separating presentation requires explicit loading/error state for KYC cooldown, rider switching and orders; simply dropping a response or using an empty list would misrepresent eligibility/active orders. No speculative rewrite here. |
| Parcel details, `parcel_details_screen.dart:249–324,536–562` | Camera/gallery upload starts before continuing; already uploaded URLs are passed to booking. The normal path does **not** upload those same URLs a second time in booking. |
| Parcel booking, `parcel_booking_screen.dart:446–480` | Local-file fallback uploads before create-order; existing URL path is reused. Slow upload can precede the Edge request, so create-order alone cannot measure this wait. |
| Rider pickup/drop proof, `rider_active_order_screen.dart:422–490` | Upload is awaited before verification Edge processing and subsequent reload. Existing project-wide test-window uploads took 8.635–22.676 seconds; this is a separate proven waiting stage. Underlying transfer/Storage/auth timing remains unresolved. Proof must not be bypassed. |

Paths above are relative to `lib/features/local_parcels/booking/screens/` where abbreviated. Previous window evidence and resource limitations remain in [Free-plan analysis](WAYDROP_FREE_PLAN_BOTTLENECK_ANALYSIS.md); no additional broad log scan was necessary. Historical and project-wide observations do not identify the user's device.

## Release and remaining verification

This correction and the prior configuration retry correction are **not in the user's Build 55**. They need a new reviewed APK and a same-device comparison. The minimum useful next measurement is rider-row completion → first Home frame / assignment reconciliation while delaying only earnings, plus per-stage parcel upload timing on the same connection. The current tests establish dependency order and lifecycle behavior, not handset rendering performance or managed Realtime/FCM delivery.

Combined SQL/Edge production rollout gates are unchanged. No new migration, Edge deployment, compute upgrade or paid project is required for this local Flutter correction. The original November database-wide initiating cause remains unproven.
