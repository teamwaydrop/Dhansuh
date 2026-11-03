$ErrorActionPreference='Stop'
$workspace=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$runtime=Join-Path $workspace '.dart_tool/waydrop-local-runtime'
& (Join-Path $runtime 'postgresql-17.11-core/pgsql/bin/pg_ctl.exe') -D (Join-Path $runtime 'pg17-synthetic-data') -m fast -w stop
if ($LASTEXITCODE) { throw 'Local PostgreSQL shutdown failed' }
