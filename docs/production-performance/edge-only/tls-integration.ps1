$ErrorActionPreference='Stop'
$workspace=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$runtime=Join-Path $workspace '.dart_tool/waydrop-local-runtime'
$tlsDirectory=Join-Path $runtime 'synthetic-pg-tls'
New-Item -ItemType Directory -Path $tlsDirectory -Force | Out-Null
$openssl='C:/Program Files/Git/usr/bin/openssl.exe'
if (-not (Test-Path -LiteralPath $openssl)) { throw 'Existing Git OpenSSL required; no automatic install' }
$caKey=Join-Path $tlsDirectory 'ca.key'; $caCert=Join-Path $tlsDirectory 'ca.crt'
$serverKey=Join-Path $tlsDirectory 'server.key'; $csr=Join-Path $tlsDirectory 'server.csr'; $cert=Join-Path $tlsDirectory 'server.crt'
$extensions=Join-Path $tlsDirectory 'server.ext'
Set-Content -LiteralPath $extensions -Value "subjectAltName=IP:127.0.0.1,DNS:localhost`nextendedKeyUsage=serverAuth" -Encoding ascii
# Windows PowerShell treats OpenSSL progress on stderr as NativeCommandError.
# Check actual exit codes rather than mistaking progress for test failure.
$ErrorActionPreference='Continue'
& $openssl req -x509 -newkey rsa:2048 -noenc -keyout $caKey -out $caCert -days 2 -subj '/CN=Waydrop Synthetic Local CA' 2> (Join-Path $tlsDirectory 'openssl.log')
if ($LASTEXITCODE) { throw 'Synthetic CA creation failed' }
& $openssl req -newkey rsa:2048 -noenc -keyout $serverKey -out $csr -subj '/CN=localhost' 2>> (Join-Path $tlsDirectory 'openssl.log')
if ($LASTEXITCODE) { throw 'Synthetic server key creation failed' }
& $openssl x509 -req -in $csr -CA $caCert -CAkey $caKey -CAcreateserial -out $cert -days 2 -extfile $extensions 2>> (Join-Path $tlsDirectory 'openssl.log')
if ($LASTEXITCODE) { throw 'Synthetic certificate signing failed' }
$ErrorActionPreference='Stop'
$pg=Join-Path $runtime 'postgresql-17.11-core/pgsql/bin/pg_ctl.exe'
$data=Join-Path $runtime 'pg17-synthetic-data'
if ((Get-Content -LiteralPath (Join-Path $data 'PG_VERSION')).Trim() -ne '17') { throw 'Expected existing isolated PG17 cluster' }
$sslOptions="-h 127.0.0.1 -p 54329 -c max_connections=24 -c shared_buffers=32MB -c ssl=on -c ssl_cert_file=$($cert.Replace('\','/')) -c ssl_key_file=$($serverKey.Replace('\','/'))"
$ErrorActionPreference='Continue'
& $pg -D $data status *> $null
$operation=if ($LASTEXITCODE -eq 0) { 'restart' } else { 'start' }
# Detach server handles from the caller's redirected PowerShell pipeline.
# Do not use Start-Process -Wait: PostgreSQL intentionally outlives pg_ctl.
$launcher=Start-Process -FilePath $pg -ArgumentList @('-D',$data,'-l',(Join-Path $runtime 'postgres.log'),'-o',('"'+$sslOptions+'"'),'-w',$operation) -WindowStyle Hidden -PassThru
if (-not $launcher.WaitForExit(30000)) { throw 'Local pg_ctl startup timeout' }
if ($launcher.ExitCode -ne 0) { throw 'Isolated TLS server restart failed' }
$env:DENO_DIR=Join-Path $runtime 'deno-cache'; $env:DENO_NO_PACKAGE_JSON='1'; $env:PGPASSWORD=''
$lockFile=Join-Path $PSScriptRoot 'deno.lock'
$resultFile=Join-Path $PSScriptRoot 'TLS_RESULTS.json'
& (Join-Path $runtime 'deno-2.9.8-core/deno.exe') run --config (Join-Path $PSScriptRoot 'deno-network.json') --cached-only --frozen "--lock=$lockFile" --allow-env --allow-net=127.0.0.1:54329 "--allow-read=$caCert" "--allow-write=$resultFile" (Join-Path $PSScriptRoot 'tls_integration.ts')
if ($LASTEXITCODE) { throw 'TLS integration tests failed' }
