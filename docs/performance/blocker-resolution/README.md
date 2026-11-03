# Local blocker verification

Only synthetic data and loopback PostgreSQL 17.11 are used. Production PostgreSQL is a different 17.x build; managed Auth, RLS gateway, pg_net scheduling, Cron and FCM receipt/device presentation are not reproduced. No Docker, paid service or remote connection string is required. `SYNTHETIC_BASE.sql` contains synthetic seed rows and sanitized schema definitions; it is not a production backup.

From the workspace root, install/start the existing portable tools using `docs/production-performance/setup-local-tools.ps1` and `docs/production-performance/local-tests/start-postgres.ps1`. Then:

```powershell
# Once only; refuses to overwrite an existing fixed test database.
python docs/performance/blocker-resolution/prepare_fixture.py
# Resets only the private candidate schema/fixtures in waydrop_blocker_test.
python docs/performance/blocker-resolution/native_test.py
$env:DENO_DIR = Join-Path (Get-Location) '.dart_tool/waydrop-local-runtime/deno-cache'
$env:DENO_NO_PACKAGE_JSON = '1'
& ./.dart_tool/waydrop-local-runtime/deno-2.9.8-core/deno.exe test --config docs/performance/blocker-resolution/deno.json --allow-env --allow-run --allow-read --deny-net docs/performance/blocker-resolution/edge_test.ts
& ./.dart_tool/waydrop-local-runtime/deno-2.9.8-core/deno.exe check --config docs/production-performance/local-tests/deno-runtime.json --cached-only --frozen-lockfile --lock=docs/production-performance/local-tests/deno.lock supabase/functions/start-dispatch/index.ts supabase/functions/send-push-notification/index.ts
& ./.dart_tool/waydrop-local-runtime/deno-2.9.8-core/deno.exe check --config supabase/functions/accept-order/deno.json --cached-only --frozen-lockfile --lock=docs/production-performance/edge-only/deno.lock supabase/functions/accept-order/index.ts
flutter test --reporter expanded
flutter analyze --no-pub
& ./docs/production-performance/local-tests/stop-postgres.ps1
```

First-time dependency resolution needs the official HTTPS hosts; the frozen check above needs the previously populated Deno cache. The test import map replaces only the SDK/HTTP listener; RPC adapters execute the actual candidate SQL in PostgreSQL. Full push handlers use synthetic Auth/preferences and FCM, actual RSA signing and actual durable RPCs. Native claims use independent PostgreSQL sessions. Lease expiry is advanced by fixture writes instead of wall-clock sleeps. The KYC serialization test waits for observed PostgreSQL lock/PgSleep states and asserts a real blocked writer. Synthetic intercity acceptance preserves only a stub transaction: full travel-plan, booking capacity and payment integration remain a managed verification gate.

The cutover preflight in native tests approves fingerprints of the synthetic fixture automatically. **That is test setup, never production drift approval.** Production reviewers must independently capture and approve definitions, owners and ACLs for every replaced function and install the explicit preflight mapping. The executable cutover has no default fingerprints and refuses to proceed without them.

SQL and Edge candidates must ship as a coordinated protocol. Do not apply every historical migration, restore old unfenced workers, run blanket `db push`, or point this harness at production. The old acceptance-only frozen manifest does not describe the changed acceptance SQL.
