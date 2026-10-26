# Isolated synthetic Android export host

Prepared locally; **not built, installed or launched**. Build/device/retrieval approval is still required. Never run the normal WAY DROP entry point for this zero-backend validation.

## Isolation and shared sources

- Standalone Flutter package, Android project and application ID: **`com.waydrop.diagnosticvalidation`**. It does not depend on the parent `waydrop` package, read `.env`, include production signing files or copy Firebase configuration.
- `lib/main.dart` initializes Flutter only. One fixed synthetic `action`/`searching` event is generated per widget mount. It is not a ride or an API attempt. The screen uses the existing Save diagnostic capture tile.
- `lib/shared_sources` is an ignored Windows junction to the repository's existing `lib` directory. Only the real recorder, writer and tile are imported. Their code is not copied or forked. The shared tile's import is relative so it works in either package without importing the full application's dependency graph.
- `prepare_sources.ps1` creates only this junction and refuses to overwrite a different existing target. Windows script policy blocked invoking the file in this session; its reviewed commands were executed directly in the terminal, without changing execution policy. Future operators can review/paste those commands rather than bypass policy.
- The isolated lockfile was resolved **offline** using existing caches. Every resolved package version matches the parent lock. Generated Android plugin metadata contains only `jni`, `jni_flutter` and `path_provider_android`; JNI is the path-provider/native bridge, not a network or telemetry SDK. No Firebase, Supabase, Cashfree, authentication or location-tracking code is in the reachable source/dependency graph.
- The source Android manifest declares **no permissions**, including no Internet permission, and disables Android backup. The release build is explicitly non-debuggable and uses the local test signing configuration. The merged manifest/APK must still be inspected after an approved build; source/metadata tests are not APK proof.

## Enablement and future retrieval

Default builds remain disabled. To enable an approved synthetic build, supply a protected local defines file containing `WAYDROP_LOCAL_RIDE_DIAGNOSTICS=true` and `WAYDROP_DIAGNOSTIC_RUN_KEY` encoding exactly 32 random bytes in base64. Do not embed a key in source, reuse credentials, print it or use the production `.env`. The key is still recoverable from a diagnostic binary by someone possessing it; this is pseudonymization, not authentication.

After separate approval, from **this directory**, the proposed command is:

```
flutter build apk --no-pub --release --dart-define-from-file=<protected-local-defines.json>
```

Do not run it yet. Before building, verify cached Flutter/Android/Gradle artifacts and obtain approval for any missing downloads. AGP 8.9.1, Kotlin 2.1.0 and Gradle 8.11.1 match the parent project's versions. The small wrapper delegates to the existing repository wrapper with this host's explicit project directory; it does not execute the parent Android project. No Gradle wrapper or Android build was executed during preparation. Offline Dart resolution does not prove Gradle artifacts are cached.

Before installing, inspect the resulting APK/merged manifest: correct separate ID, non-debuggable release, no Internet/new permissions and no backend/telemetry components. Unexpected components or permissions mean stop. Installation must never target `com.waydrop.app`.

On each separately approved phone, launch only this host and select Save diagnostic capture. The shared writer enforces the existing 4 MiB cap, one-operation guard and temporary-file replacement. The expected primary-storage file is:

```
/sdcard/Android/data/com.waydrop.diagnosticvalidation/files/ride-diagnostics/capture.json
```

The actual storage root and ADB accessibility remain unverified. After approval, retrieve only that verified file using `adb -s <selected-phone> pull <verified-host-capture-path> <protected-phone-label>.json`. Keep phone association in a separate redacted local acquisition record; the JSON does not encode the phone ID. Validate size, JSON schema and pseudonyms locally without printing contents/key. Do not fall back to application logs, root access, storage permissions or network sharing. This validates shared export mechanics in a separate package, not the production app's ride flow, installed APK or performance.

## Local verification

The host's tests exercise actual widget startup, default gating, synthetic-event deduplication, the real local writer against a disposable directory, source reuse, package identity, permission declarations and resolved plugin/version metadata. Conditional enabled tests use a temporary synthetic key which is never printed and is removed afterward. Test seams are not used by the host's release entry point.

Run focused tests/analysis from this directory; no Android build is needed:

```
flutter test --no-pub test/diagnostic_export_host_test.dart --reporter expanded --timeout 30s
flutter analyze --no-pub lib/main.dart test/diagnostic_export_host_test.dart
```

The enabled widget/export test requires explicit test defines and otherwise skips. Shared writer/UI regressions are run from the parent project. The junction is excluded from broad host analysis because it links the full parent source tree; only the four reachable files are used. Shared implementation analysis remains in the parent project.

No device checks, runtime network checks, ride latency measurements or capacity claims have been made.


Final local results: host default/configuration tests **5 passed, 1 skipped, exit 0**; the explicitly enabled synthetic widget/local-export test **1 passed, exit 0** using a temporary unprinted key. Host and shared-tile targeted analysis each reported **0 findings, exit 0**. Final offline lock enforcement passed, and the pinned-version test verifies every host dependency matches the parent's version. An intermediate offline resolution selected newer cached transitives only in the new host; these were restored to parent-pinned versions before final validation. Parent dependency files were not changed. Source setup and cross-package path assertions were corrected without changing recorder/export behavior.

Shared export regressions: **22 passed, 1 skipped, exit 0**. `git diff --check`: **exit 0**. Skips are enabled-build-only tests in default-disabled runs. No Android build, install, launch, ADB, production access or commits/pushes occurred.
