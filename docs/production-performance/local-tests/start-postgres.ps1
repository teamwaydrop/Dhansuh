$ErrorActionPreference='Stop'
$workspace=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$runtime=Join-Path $workspace '.dart_tool/waydrop-local-runtime'
$pgBin=Join-Path $runtime 'postgresql-17.11-core/pgsql/bin'
$data=Join-Path $runtime 'pg17-synthetic-data'
if (-not (Test-Path -LiteralPath (Join-Path $data 'PG_VERSION'))) {
  & (Join-Path $pgBin 'initdb.exe') -D $data -U waydrop_local --auth-local=trust --auth-host=trust --encoding=UTF8 --locale=C
  if ($LASTEXITCODE) { throw 'initdb failed' }
}
# Synthetic data only. No service, firewall, global PATH or production linkage.
& (Join-Path $pgBin 'pg_ctl.exe') -D $data status *> $null
if ($LASTEXITCODE -ne 0) {
  & (Join-Path $pgBin 'pg_ctl.exe') -D $data -l (Join-Path $runtime 'postgres.log') -o '-h 127.0.0.1 -p 54329 -c max_connections=24 -c shared_buffers=32MB' -w start
  if ($LASTEXITCODE) { throw 'Local PostgreSQL startup failed; inspect workspace postgres.log' }
}
$exists=& (Join-Path $pgBin 'psql.exe') -X -A -t -h 127.0.0.1 -p 54329 -U waydrop_local -d postgres -v ON_ERROR_STOP=1 -c "SELECT 1 FROM pg_database WHERE datname='waydrop_perf_test';"
if ($LASTEXITCODE) { throw 'Could not check the fixed local test database' }
if ($exists -ne '1') {
  & (Join-Path $pgBin 'psql.exe') -X -h 127.0.0.1 -p 54329 -U waydrop_local -d postgres -v ON_ERROR_STOP=1 -c 'CREATE DATABASE waydrop_perf_test;'
  if ($LASTEXITCODE) { throw 'Test database creation failed; do not use a different database automatically' }
}
