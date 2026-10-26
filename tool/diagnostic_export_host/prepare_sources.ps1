$ErrorActionPreference = 'Stop'
$sharedSource = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../../lib')).Path
$linkPath = Join-Path $PSScriptRoot 'lib/shared_sources'
if (Test-Path -LiteralPath $linkPath) {
    $existing = Get-Item -LiteralPath $linkPath
    if ($existing.LinkType -ne 'Junction' -or $existing.Target.Count -ne 1 -or
        [System.IO.Path]::GetFullPath($existing.Target[0]) -ne $sharedSource) {
        throw 'Refusing to overwrite the existing shared-source path.'
    }
} else {
    New-Item -ItemType Junction -Path $linkPath -Target $sharedSource | Out-Null
}
# No copying, package resolution, build, launch, network or deletion.
