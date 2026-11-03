param([switch]$DownloadOnly)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$runtime = Join-Path $workspace '.dart_tool/waydrop-local-runtime'
New-Item -ItemType Directory -Force $runtime | Out-Null
# Portable official distributions. No PATH/registry/service/firewall changes.
$archives = @(
  # PostgreSQL hash was recorded from this official HTTPS download, not an independent publisher checksum.
  @{ Name='postgresql-17.11.zip'; Uri='https://sbp.enterprisedb.com/getfile.jsp?fileid=1260616'; Hash='80379b2c04d51c30225532e0ae04509899141e9957ed096fe749d7fd9df8f82f' },
  @{ Name='deno-2.9.8.zip'; Uri='https://github.com/denoland/deno/releases/download/v2.9.8/deno-x86_64-pc-windows-msvc.zip'; Hash='cba84b26e0df5ae7f74fc66b86a95b866872a86292ebd84fa1e959927edd93bf' }
)
foreach ($archive in $archives) {
  $target = Join-Path $runtime $archive.Name
  if (-not (Test-Path -LiteralPath $target)) {
    Invoke-WebRequest -UseBasicParsing -Uri $archive.Uri -OutFile ($target+'.partial') -TimeoutSec 600
    Move-Item -LiteralPath ($target+'.partial') -Destination $target
  }
  $digest = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($archive.Hash -and $digest -ne $archive.Hash) { throw ('Checksum mismatch: '+$archive.Name) }
  [pscustomobject]@{ Archive=$archive.Name; SHA256=$digest; Source=$archive.Uri } | ConvertTo-Json -Compress
  if (-not $DownloadOnly) {
    $destination = Join-Path $runtime ($archive.Name.Replace('.zip','')+'-core')
    if (-not (Test-Path -LiteralPath $destination)) {
      if ($archive.Name -like 'postgresql-*') {
        # Omit pgAdmin/StackBuilder/docs: server, CLI, libraries and extension SQL only.
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip=[IO.Compression.ZipFile]::OpenRead($target)
        try {
          foreach ($entry in $zip.Entries) {
            if ($entry.FullName -notmatch '^pgsql/(bin|lib|share)/' -or $entry.FullName.EndsWith('/')) { continue }
            $output=[IO.Path]::GetFullPath((Join-Path $destination $entry.FullName))
            if (-not $output.StartsWith([IO.Path]::GetFullPath($destination)+[IO.Path]::DirectorySeparatorChar)) { throw 'Archive path escaped destination' }
            New-Item -ItemType Directory -Force ([IO.Path]::GetDirectoryName($output)) | Out-Null
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry,$output,$true)
          }
        } finally { $zip.Dispose() }
      } else { Expand-Archive -LiteralPath $target -DestinationPath $destination }
    }
  }
}
