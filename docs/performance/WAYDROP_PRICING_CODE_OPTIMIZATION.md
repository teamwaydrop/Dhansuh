# Booking/pricing code correction — 3 November 2026

Deep source follow-up; preserves the previous Home, GPS, chat, upload and account fixes. Production remains read-only. No production connector inspection, DDL/DML, Edge deployment, configuration change, paid resource or new project in this batch. These corrections are local **after Build59**, which is unchanged; no new APK is packaged here.

## Verified problems and minimum corrections

| Problem | Evidence | Local correction |
|---|---|---|
| Invisible quote work on Parcel Specifications | `_estimatedFare` and `_loadingFare` are assigned but never read/rendered/passed onward. `_fetchPricingLive` runs on initialization with pickup and after route selection. Actual light-parcel widget reproduction sends two calculate-order-pricing requests. | Remove only this dead preview/controller/unused fields and its two call sites from `lib/features/local_parcels/booking/screens/parcel_details_screen.dart`. Measured on the same widget: **2 Edge requests → 0**. Contacts, route/weight/image state, validation and navigation remain. |
| Artificial fare loading floor | `PricingController.fetchMultiplePricing` awaited the remaining part of500ms even after successful immediate HTTP completion. | Remove the deliberate timer. Controlled immediate-response test now completes before a200ms test deadline. This removes a source-imposed minimum, not proof of a phone-wide500ms saving. |
| Older requests publish stale fare/error/loading | Paused old quote, completed newer quote, then resumed old response: fare9 became1. Old failure also cleared newer loading and set its error. | Latest generation and account ownership guard all shared state commits and final notification. Existing requests may finish, but older batches cannot publish over the current batch. |
| Reset/disposal do not invalidate pending work | After reset, an older response repopulated pricing. Disposed controller tried to notify and mutated quote data. | Reset advances generation; dispose invalidates ownership. Disposed controllers do not launch new batches or publish late state. |
| Incorrect request sharing from rounded key | Distance5.001/5.004 or latitude17.100001/17.100004 produce the same old dedup key despite different transmitted bodies. Actual SDK test sees one request where exact-input isolation requires two. | Canonical sorted JSON key over exact transmitted input plus in-memory user/credential identity. No coordinate/distance rounding in the key; no delimiter-based ambiguity. Tokens/key are not logged or persisted. |
| Visible timeout releases unfinished pricing transport | After the15-second deadline, retry starts a second invocation while the original raw HTTP operation remains held. | Per-vehicle visible deadlines remain15 seconds; raw Future retains shared ownership until actual settlement. Retry joins identical pending work instead of issuing a duplicate call. Cleanup is identity-fenced. |

No production incorrect-fare/overcharge claim is made from the key collision test: it proves conflated requests and a wrong synthetic quote result. Actual backend rounding/zone behavior determines whether a particular real pair would yield different fares. Exact input sharing avoids that unsupported assumption.

## Exact source and preserved flow

`lib/modules/payments/controllers/pricing_controller.dart`:

- Lines25–31: generation/disposal/account ownership.
- Lines42–55: same per-instance pending map, exact-input and credential-scoped key. Identical active input still shares; completed results are not cached.
- Lines59–96: one latest batch publishes loading/result/error; no artificial minimum timer.
- Lines101–199: original vehicle/weight routing retained; stale checks before starting and before committing results. Partial vehicle success/error behavior remains. The intermediate redundant notification is removed; the owner publishes the final state.
- Lines150–181: pending raw-request sharing and15-second per-caller timeout. Raw completion cleans only its own map entry.
- Lines208 onward: existing calculate-order-pricing invocation and response decoding retained; no new abort option or SDK upgrade. Verbose successful fare/coordinate/address response logging is removed; existing failure markers remain.
- Lines357–377: reset/dispose invalidation.

The removed Parcel Details preview returned no data to its caller and its fields were unused. **Actual fare calculation stays in `ParcelBookingScreen.initState` / `_fetchPricing`** (`lib/features/local_parcels/booking/screens/parcel_booking_screen.dart:195,400`), with full route/weight/location inputs. Ride/intercity booking and post-plan callers continue using the same controller. Local parcel still offers every weight-eligible Bike/Auto choice; intercity retains its existing weight-based vehicle behavior. Server fare computation, boost application, commission/GST, subscription waiver, order creation, acceptance and payment security are unchanged. Existing caller/vehicle/boost regression guards pass.

## Reproduction and verification

`test/pricing_request_lifecycle_test.dart` uses actual pinned SDK invocations through a MockClient with explicit request-start events/response gates; no real pricing endpoint is called. Nine original cases: **1 passed / 8 expected failures**. After correction: **10 passed**, including a separately added account-switch case that cannot share or publish the earlier account quote. Cases cover immediate completion, stale success/failure, reset, dispose, exact distance/coordinate keys, identical work sharing/fresh revalidation and timeout/retry ownership.

`test/parcel_photo_screen_recovery_test.dart` adds the actual Parcel Specifications route-ready widget check. Original **0 passed / 1 expected failure**, observed two unnecessary Edge invocations; corrected five widget cases pass, including prior upload/recovery/disposal checks. An initial fake-time draft of the new pricing harness was stopped because its blocked continuation could not advance the old deliberate timer; the retained baseline is the completed gate-based harness, not that incomplete draft.

Combined focused pricing/parcel/vehicle/boost suite: **37 passed / 0 failed**. Analyzer on four changed files: **0 errors / 0 warnings / 8 existing infos** in legacy Parcel Details (doc/deprecated APIs), exit1, not clean. The pricing controller and new/changed tests subset: **no issues**, exit0. Removing the dead fields also removes their previous two unused-field warnings. Final full Flutter: **2,203 passed / 0 failed**, previous2,192 plus11 new cases (10 controller,1 hidden-preview widget). Final full-suite outcome and source fingerprints: [verification](pricing-code-20261103/VERIFICATION.json).

SDK/docs: [Flutter invoke reference](https://supabase.com/docs/reference/dart/functions-invoke) and current changelog reviewed against pinned local code. No new API/version is assumed. The [CBC TLS deprecation](https://supabase.com/changelog/cbc-tls-ciphers-deprecated) is scheduled no earlier thanNovember10; it is not evidence of a November1/2 incident cause and is not acted on in this client correction.

## Limits and remaining work

The confirmed reductions are hidden preview2→0 and timeout retry's identical invocation2→1. Distinct exact inputs now intentionally produce separate requests; this can increase calls compared with the unsafe rounded key. Already-started distinct requests are not cancelled; this batch does not debounce every route/boost interaction or claim all API amplification is resolved. Existing screens' native WebView/payment/provider integrations and Android timing still require device validation.

No production CPU, I/O, lock or Storage-pool initiating cause is established here. Storage504/57014 and the missing historical service/onset telemetry remain outstanding. The previous Rider Realtime correction and these pricing changes are local beyond the signed Build59 artifact. Combined SQL/Edge rollout gates remain unchanged; no migration is required for these client changes. Real Android acceptance must cover rapid route/boost changes, vehicle eligibility, account switch, quote failure/retry, photo recovery, final fare/order/payment validation and leaving a screen while pricing is pending.
