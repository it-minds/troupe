<#
Exercise install.ps1 end to end on a Windows runner: install, re-run as an upgrade,
reject a corrupted artifact, then uninstall and check nothing is left behind outside
config and state.

Everything is scoped to a scratch directory so the runner's real PATH, config and
state are untouched.
#>
[CmdletBinding()]
param([string]$ReleaseDir = (Join-Path $PSScriptRoot '..\release'))

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$installer = Join-Path $PSScriptRoot '..\install.ps1'
$scratch = Join-Path ([System.IO.Path]::GetTempPath()) "troupe-install-test-$([System.IO.Path]::GetRandomFileName())"
$installDir = Join-Path $scratch 'Programs\troupe'
$releaseUrl = "file://$((Resolve-Path $ReleaseDir).Path -replace '\\', '/')"

function Step { param([string]$Message) Write-Host "`n=== $Message" }
function Fail { param([string]$Message) Write-Error "FAIL: $Message"; exit 1 }

$pathBefore = [Environment]::GetEnvironmentVariable('Path', 'User')

try {
    New-Item -ItemType Directory -Path $scratch -Force | Out-Null

    Step 'install'
    & $installer -ReleaseUrl $releaseUrl -InstallDir $installDir
    $binary = Join-Path $installDir 'troupe.exe'
    if (-not (Test-Path $binary)) { Fail 'binary not installed' }
    & $binary --version | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail 'installed binary does not run' }

    Step 'PATH entry added exactly once'
    $entries = ([Environment]::GetEnvironmentVariable('Path', 'User') -split ';') |
        Where-Object { $_ -eq $installDir }
    if ($entries.Count -ne 1) { Fail "expected one PATH entry, found $($entries.Count)" }

    Step 're-run is a clean upgrade and does not duplicate the PATH entry'
    & $installer -ReleaseUrl $releaseUrl -InstallDir $installDir
    if (-not (Test-Path "$binary.previous")) { Fail 'no rollback copy kept' }
    $entries = ([Environment]::GetEnvironmentVariable('Path', 'User') -split ';') |
        Where-Object { $_ -eq $installDir }
    if ($entries.Count -ne 1) { Fail 'PATH entry duplicated on upgrade' }

    Step 'a corrupted artifact fails the checksum and installs nothing'
    $bad = Join-Path $scratch 'bad'
    New-Item -ItemType Directory -Path $bad -Force | Out-Null
    Copy-Item (Join-Path $ReleaseDir 'SHA256SUMS') $bad
    $artifact = (Get-Content (Join-Path $ReleaseDir 'SHA256SUMS') |
        ForEach-Object { ($_ -split '\s+')[-1] } |
        Where-Object { $_ -like '*windows*' } | Select-Object -First 1)
    Set-Content -Path (Join-Path $bad $artifact) -Value 'this is not a binary'
    Remove-Item -LiteralPath $binary -Force

    $badUrl = "file://$((Resolve-Path $bad).Path -replace '\\', '/')"
    $failed = $false
    try {
        & $installer -ReleaseUrl $badUrl -InstallDir $installDir 2>&1 | Out-String -OutVariable output
    } catch {
        $failed = $true
    }
    if (-not $failed -and (Test-Path $binary)) { Fail 'a corrupted artifact was installed' }
    if (Test-Path $binary) { Fail 'a corrupted artifact was installed anyway' }

    Step 'reinstall, then run once so the payload cache exists'
    & $installer -ReleaseUrl $releaseUrl -InstallDir $installDir
    & $binary --version | Out-Null

    Step 'uninstall leaves nothing outside config and state'
    & $installer -Uninstall -InstallDir $installDir
    if (Test-Path $binary) { Fail 'binary still present' }
    if (Test-Path "$binary.previous") { Fail 'rollback copy still present' }
    $entries = ([Environment]::GetEnvironmentVariable('Path', 'User') -split ';') |
        Where-Object { $_ -eq $installDir }
    if ($entries.Count -ne 0) { Fail 'PATH entry still present' }

    $stale = Get-ChildItem -LiteralPath (Join-Path $env:LOCALAPPDATA '.burrito') `
        -Filter 'troupe_erts-*' -Directory -ErrorAction SilentlyContinue
    if ($stale) { Fail 'payload cache still present' }

    Write-Host "`nAll installer checks passed."
} finally {
    # Never leave the runner's PATH modified, whatever happened above.
    [Environment]::SetEnvironmentVariable('Path', $pathBefore, 'User')
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}
