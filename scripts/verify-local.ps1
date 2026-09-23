<#
.SYNOPSIS
  Smoke-test what `install-local.ps1` just installed: the binaries run, the daemon comes up.
.DESCRIPTION
  The checks every fix gets after it is installed, whatever it touched:

    * troupe-daemon and troupe report the version in VERSION
    * `troupe-daemon config` loads the configuration from a scratch workspace
    * `troupe-daemon run` starts, and `troupe-daemon status` sees it inside the timeout
    * `troupe-daemon models` answers while it runs

  The daemon it starts is stopped again at the end, and only that one. Exit status 0 is
  a pass; anything else names the check that failed. An issue's own reproduction is not
  here -- it goes after this, and is written up in the pull request.
.EXAMPLE
  .\scripts\verify-local.ps1
  .\scripts\verify-local.ps1 -NoTui          # after install-local.ps1 -NoTui
  .\scripts\verify-local.ps1 -Workspace C:\some\repo
#>
param(
  [switch]$NoTui,
  [string]$Workspace = "",
  [int]$StartTimeoutSeconds = 45
)

$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $PSScriptRoot
$BinDir = Join-Path $env:LOCALAPPDATA "Programs\troupe"
$LibDir = Join-Path $env:LOCALAPPDATA "Programs\troupe-daemon"
$Shim = Join-Path $BinDir "troupe-daemon.cmd"
$Tui = Join-Path $BinDir "troupe.exe"
$Version = (Get-Content (Join-Path $Root "VERSION") -Raw).Trim()

$failures = @()
function Pass($what) { Write-Host "PASS  $what" }
function Fail($what) { Write-Host "FAIL  $what"; $script:failures += $what }

function Stop-OurDaemon {
  Get-Process erl, erlsrv, beam.smp -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -and $_.Path.StartsWith($LibDir, [StringComparison]::OrdinalIgnoreCase) } |
    ForEach-Object { Stop-Process -Id $_.Id -Force }
}

if (-not (Test-Path $Shim)) { throw "no $Shim -- run scripts\install-local.ps1 first" }

if (-not $Workspace) {
  $Workspace = Join-Path ([IO.Path]::GetTempPath()) "troupe-verify-$PID"
  New-Item -ItemType Directory -Force -Path $Workspace | Out-Null
}
Push-Location $Workspace
try {
  $out = (& $Shim version 2>&1 | Out-String)
  if ($LASTEXITCODE -eq 0 -and $out -match [regex]::Escape($Version)) { Pass "troupe-daemon version is $Version" }
  else { Fail "troupe-daemon version: expected $Version, got: $($out.Trim())" }

  if (-not $NoTui) {
    $out = (& $Tui --version 2>&1 | Out-String)
    if ($LASTEXITCODE -eq 0 -and $out -match [regex]::Escape($Version)) { Pass "troupe version is $Version" }
    else { Fail "troupe version: expected $Version, got: $($out.Trim())" }
  }

  $out = (& $Shim config 2>&1 | Out-String)
  if ($LASTEXITCODE -eq 0) { Pass "troupe-daemon config loads" }
  else { Fail "troupe-daemon config exited $LASTEXITCODE`: $($out.Trim())" }

  # A daemon left over from before the install would answer `status` for the new build.
  Stop-OurDaemon
  $log = Join-Path $Workspace "daemon.log"
  $proc = Start-Process -FilePath $Shim -ArgumentList "run" -WorkingDirectory $Workspace `
    -RedirectStandardOutput $log -RedirectStandardError "$log.err" -PassThru -WindowStyle Hidden

  $up = $false
  $deadline = (Get-Date).AddSeconds($StartTimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    & $Shim status *> $null
    if ($LASTEXITCODE -eq 0) { $up = $true; break }
    if ($proc.HasExited) { break }
    Start-Sleep -Milliseconds 750
  }
  if ($up) { Pass "troupe-daemon run starts and status sees it" }
  else {
    Fail "troupe-daemon did not come up within $StartTimeoutSeconds s (log: $log)"
    if (Test-Path "$log.err") { Get-Content "$log.err" -Tail 20 | ForEach-Object { Write-Host "      $_" } }
  }

  if ($up) {
    $out = (& $Shim models 2>&1 | Out-String)
    if ($LASTEXITCODE -eq 0) { Pass "troupe-daemon models answers" }
    else { Fail "troupe-daemon models exited $LASTEXITCODE`: $($out.Trim())" }
  }
}
finally {
  Stop-OurDaemon
  if ($proc -and -not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
  Pop-Location
}

Write-Host ""
if ($failures.Count -gt 0) {
  Write-Host "$($failures.Count) check(s) failed. To go back:  .\scripts\install-local.ps1 -Rollback"
  exit 1
}
Write-Host "all checks passed for $Version"
