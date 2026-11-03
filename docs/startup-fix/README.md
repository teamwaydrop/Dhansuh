# APK startup hotfix — 1 November 2026

Implemented locally. Production database/schema/data and Edge Functions were not changed. The installed APK must be rebuilt to receive this fix.

## Confirmed root cause and authority

The startup projection selected `users.is_suspended`, which does not exist in the live public schema. The same bad projection existed in the admin account guard. Earlier HTTP fixtures fabricated that field, so green tests did not catch the incompatibility. The new fixture validates projections against captured production column definitions.

The reported 33 HTTP 400s during 20:53–20:59 IST are user-provided production evidence. This task verified column definitions and compiled the corrected SELECT with `WHERE false`, returning zero rows. No production user profiles were retrieved, and no timing/request-count improvement on the APK is invented.

Authoritative checks:

- Account bans: `auth.users.banned_until`, enforced through a **server Auth getUser check**, not a profile boolean or user-editable metadata. A missing/failed Auth response blocks account loading; it never becomes an implicit false suspension decision. Current [Supabase Auth middleware](https://github.com/supabase/auth/blob/master/internal/api/auth.go) rejects banned users even with a previously issued access token. The installed Dart SDK does not expose `banned_until` as a User property; no such field is inferred from cached User data.
- Deletion: `public.users.deleted_at`. The projection explicitly includes it; missing/malformed required profile identity/deletion fields are an error, while explicit null means no deletion tombstone.
- Rider restrictions remain separate: `rider_kyc.activation_status='suspended'`, future `blocked_until`, and `riders.account_status='blocked'` deny rider entry. Existing KYC approval, payout activation and service-mode checks remain.
- Production `is_admin()` uses active `public.admins`; it contains no `users.is_suspended` check. No admin SQL/RLS or role permissions changed. Existing UI role checks remain and now use the verified account loader.

All five executable Flutter references were addressed: two in `app_start_screen.dart` (projection and false default), two in `account_guard.dart` (projection and permissive missing-value comparison), and one in `user_session_service.dart` (nonexistent realtime field). No executable Flutter reference remains. Deliberate negative tests and historical proposal/report text may still mention the old name.

## Exact implementation

| File | Functions / relevant lines | Change |
|---|---|---|
| `lib/core/services/session/account_profile_service.dart` | projection 22; postgrestCode 33; isSchemaError 45; isTransient 55; _read 85; verifyAuth 113; load/_load 130–177 | Shared coalesced account loader; server Auth verification before profile access; schema-correct SELECT; required identity/deletion checks; no success/suspension default on unknown state |
| `lib/app_start_screen.dart` | profile batch around 117–123; account result around 172; restriction catch around 238; error classification around 260–290 | Uses shared loader while public maintenance/version configuration remains independent; preserves onboarding/navigation; invokes existing shared restriction cleanup; actionable error classification |
| `lib/shared/widgets/account_guard.dart` | _check around 43–51; error UI around 66–75 | Removes invalid projection/false assumption; admin role checked only after verified account load; terminal failures cannot trigger futile retry |
| `lib/core/services/session/user_session_service.dart` | listenUserSuspension; _verifyAuth; didChangeAppLifecycleState; stopListening | Watches actual public deletion field; revalidates Auth on resume/token refresh/user update; observes errors and releases subscriptions/observer; retains restriction/logout/cache cleanup |
| `lib/core/services/session/auth_routing_policy.dart` | shouldRecheck | Duplicate same-identity signedIn events no longer restart startup; real identity transitions and user updates remain handled |
| `lib/core/services/session/rider_access_service.dart` | decide around 40–48 | Explicit suspended activation/blocked rider states deny rider access; other eligibility requirements preserved |
| `lib/shared/screens/connection_error_screen.dart` | retryEnabled field and button around 8–14 / 103 | Keeps the existing screen/layout; disables Try Again for terminal compatibility failures; transient failures remain retryable |
| `lib/features/intercity/shared/screens/intercity_searching_screen.dart` | capacity enrichment around 500 / 568 | Removes nonexistent, unreadable `rider_travel_plans.seats_preference`; preserves `max_bookings`, weight fields and existing matching/payment rules |
| `lib/features/intercity/shared/screens/intercity_tracking_screen.dart` | booked seats around 2751–2758 | Removes nonexistent `orders.capacity`; keeps authoritative `seats_requested` and the existing null fallback of one seat |

Corrected startup projection:

```text
id, full_name, deleted_at, profile_completed, onboarding_completed,
preferred_mode, is_developer, role
```

## Retry/error behavior

- Each read gets at most **three attempts**, with **500 ms then 1,000 ms** backoff, within a shared **12-second** account-load budget and up to three seconds per attempt. Identity changes stop obsolete work.
- Only transient network/timeouts, throttling and recognized temporary HTTP/database availability failures retry. HTTP 400/schema/auth-denial errors do not enter automatic retry.
- Terminal schema failures are remembered per account for this process, so duplicate callers/rechecks do not reissue the broken SELECT. Logout clears that failure state. Concurrent account loaders share an in-flight read.
- Installed `postgrest 2.5.0` can wrap maybeSingle SQLSTATE errors as HTTP 400 with the original JSON in `message`. The loader extracts the original code safely, so a real `42703` remains a terminal compatibility failure.
- Schema errors show an update/support message and disable pointless retries. Genuine service outages show a temporary account-service error with a retry button. Invalid/banned Auth and deleted profiles cannot enter app content. Bans/deletion use the existing bounded cleanup and login route; remote cleanup/network errors do not grant access.

## Projection search and evidence

`PRODUCTION_PUBLIC_COLUMNS.json` contains schema names only, not user rows. `check-projections.mjs` checks literal, adjacent-string and known-constant SELECTs plus wildcard table validity. Final result: **176 selectors checked, zero missing fields, zero unresolved selectors in this scan**. It found and fixed the two additional intercity mismatches above. This does not certify arbitrary future dynamic SQL, filter columns, RPC output or foreign-key relationship resolution.

The production syntax-only check was:

```sql
SELECT id,full_name,deleted_at,profile_completed,onboarding_completed,
       preferred_mode,is_developer,role
FROM public.users WHERE false;
```

It returned `[]`. It verifies column compatibility, not a real user's Auth/RLS/API or APK navigation.

## Verification

- **17 new regressions**: valid server-verified profile; original missing-column rejection; terminal schema caching; non-retried deterministic 400; bounded transient/network retries; ban/unknown Auth/deletion handling; eight-way coalescing; rider suspension; duplicate signedIn; actual startup success/error/outage/ban UI.
- **57 focused tests passed, zero failed** across the new file and maintenance, session, GPS/badge, logout and KYC regression files.
- **2,082 full Flutter tests passed, zero failed.** Two stale source-contract expectations were updated to assert the equivalent shared cleanup and correct backend error classification, rather than the nonexistent column. No test was skipped, deleted or disabled.
- Exact changed startup/account files plus new test: **zero analyzer issues**. Unchanged legacy warnings elsewhere were not cosmetically rewritten.
- `git diff --check` passed for the hotfix source; the existing five-file atomic Edge release hash verifier still passes. No Supabase acceptance implementation/deployment payload changed in this hotfix.

Raw logs are `.dart_tool/waydrop-local-runtime/startup-hotfix-{focused,full,analyze}.log`. Machine-readable evidence is `VERIFICATION.json`; the selector scan is `PROJECTION_AUDIT.json`.

## Rebuild and device confirmation

Using the existing approved build configuration, without printing its secrets:

```powershell
flutter build apk --release --dart-define-from-file=.env
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

If your approved build defines file has another name, use that existing file. These commands were **not executed** in this task; no replacement APK/device run is claimed.

After installing, verify a normal existing passenger/rider reaches the correct screen; missing profile reaches onboarding; maintenance/version gates still win; suspended/deleted accounts are denied; a network outage shows a useful retryable error; no new profile GET requests include `is_suspended` or repeatedly return missing-column 400. Check real logs over a matched session. Do not create/ban production users or modify production data merely to exercise negative cases; those are covered locally and need an authorized isolated target for managed end-to-end tests.
