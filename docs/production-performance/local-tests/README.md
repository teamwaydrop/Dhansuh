# Workspace-local PostgreSQL 17 and Deno verification

The tools were downloaded and executed successfully on Windows. No Docker, WSL, service installation, firewall, registry or global PATH changes are needed. Cost: **$0**. All data is synthetic. The loopback cluster uses trust authentication: other processes on this computer can access its synthetic data while it runs. Never put real users, keys or production connection strings in this cluster.

Sources: PostgreSQL's [Windows download page](https://www.postgresql.org/download/windows/) links to the [EDB binary archives](https://www.enterprisedb.com/download-postgresql-binaries); Deno's [manual installation instructions](https://docs.deno.com/runtime/getting_started/installation/) link to official release ZIPs. The pinned tools are PostgreSQL **17.11** and Deno **2.9.8**. Production is PostgreSQL 17.6; same major, different patch/build. Managed Edge runtime parity is not proven.

Run from the workspace root in ordinary PowerShell:

```powershell
& ./docs/production-performance/setup-local-tools.ps1
& ./docs/production-performance/local-tests/start-postgres.ps1
node docs/production-performance/local-tests/pg17-tests.mjs --with-atomic-acceptance
node docs/production-performance/acceptance/atomic-tests.mjs
node docs/production-performance/local-tests/scaled-benchmark.mjs
node docs/production-performance/local-tests/prepare-push.mjs
$env:DENO_DIR = Join-Path (Get-Location) '.dart_tool/waydrop-local-runtime/deno-cache'
$env:DENO_NO_PACKAGE_JSON = '1'
$deno = './.dart_tool/waydrop-local-runtime/deno-2.9.8-core/deno.exe'
& $deno check --config docs/production-performance/local-tests/deno-runtime.json --cached-only --frozen-lockfile --lock=docs/production-performance/local-tests/deno.lock .dart_tool/waydrop-local-runtime/push-under-test/functions/proposed/index.ts
& $deno test --config docs/production-performance/local-tests/deno-test.json --allow-read=.dart_tool/waydrop-local-runtime/push-under-test,docs/production-performance/local-tests/push-mocks --allow-env=SUPABASE_URL,SUPABASE_SERVICE_ROLE_KEY,FIREBASE_SERVICE_ACCOUNT_KEY --deny-net docs/production-performance/local-tests/push_test.ts
$pg = Join-Path (Get-Location) '.dart_tool/waydrop-local-runtime/postgresql-17.11-core/pgsql/bin/psql.exe'
& $deno test --config docs/production-performance/local-tests/deno-test.json --allow-read=supabase/functions,docs/production-performance,.dart_tool/production_performance_preflight_20261101 --allow-run=$pg --allow-write=docs/production-performance/local-tests/ACCEPTANCE_RESULTS.json --allow-env=SUPABASE_URL,SUPABASE_SERVICE_ROLE_KEY --deny-net docs/production-performance/local-tests/acceptance_test.ts
& ./docs/production-performance/local-tests/stop-postgres.ps1
```

The acceptance race is now fixed: both handler tests and the one-accepted-assignment assertion pass. Fifteen additional native acceptance groups and six real local REST/JWT/SDK integration checks pass; see `../acceptance/README.md`. The frozen dependency check needs the downloaded cache created during this run; first-time setup requires HTTPS dependency resolution using `deno check --lock=...` without `--cached-only`. Never use `--no-check` or disable certificate validation to make a check pass. `prepare-push.mjs` also prepares compat/timing/oauth intermediates; all four prepared push stages type-check with the frozen cache.

`pg17-tests.mjs` rebuilds only the fixed `waydrop_perf_test` database on `127.0.0.1:54329`. The generated schema SQL includes the same database/address/port guard. `fixture-source.json` contains sanitized definitions, not user data. Seven tables retain exact column types/typmods/defaults/constraints. Twenty-two RLS policies and eight relevant triggers are installed. `auth.uid/role/email` emulate gateway claim settings; the actual managed JWT verifier is absent. Unrelated FK targets are key-only placeholders. `pgcrypto` and `uuid-ossp` run locally. Vault, pg_net, Cron, managed Auth, Realtime and PostgREST integration are **not** reproduced. Outbound push SQL calls are captured in `local_push_capture`.

`local-evidence.mjs` successfully created a custom-format **synthetic** dump and restored it into `waydrop_perf_restore`; row counts, function hashes and policy/index counts matched. `verify-restore.mjs` performed a stronger second drill into `waydrop_perf_restore_verified`: exact content hashes of 10 synthetic tables plus function definitions/owners/ACL, policy, index and trigger definitions matched. These scripts intentionally fail if their restore databases already exist. For a repeat drill, verify the target is the disposable local restore database and remove it explicitly using the local `dropdb.exe` before rerunning. They never drop a database automatically. The snapshot source files in `.dart_tool/production_performance_preflight_20261101` must remain available for exact rollback tests.

The initial restricted Windows process token prevented `pg_ctl` from starting its child process. Running the portable launcher outside that process sandbox succeeded. This required no administrator installation. If launching a hidden process manually, use `Start-Process -WindowStyle Hidden`; these scripts use pg_ctl directly and create no Windows service.

PostgreSQL archive SHA256 `80379b2c04d51c30225532e0ae04509899141e9957ed096fe749d7fd9df8f82f` was recorded from the official HTTPS download; it is not an independently published checksum. Deno archive SHA256 `cba84b26e0df5ae7f74fc66b86a95b866872a86292ebd84fa1e959927edd93bf` matched the official GitHub release metadata. The lockfile freezes the locally resolved dependency graph (`supabase-js` 2.118.0); the dependency version embedded in deployed v24 remains unverified. This lockfile does not prove Supabase's deployment tool will reproduce the old bundle.

No actual Firebase test destination exists, as confirmed by the user. Full-handler tests use actual crypto signing/verification and timeout helpers with mocked DB/Auth/provider transports under `--deny-net`; they do not prove device delivery. No production function is invoked by any test.

The isolated runtime config and `DENO_NO_PACKAGE_JSON` keep unrelated root JavaScript dependencies out of the Edge lockfile. Checking all four stages without that isolation initially attempted to add the root application's dependency metadata; the corrected isolated, frozen check passed without installing those packages.
