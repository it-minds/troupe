<#
.SYNOPSIS
  Smoke-test what `install-local.ps1` just installed: the binaries run, the daemon comes up.
.DESCRIPTION
  The checks every fix gets after it is installed, whatever it touched:

    * troupe-daemon and troupe report the version in VERSION
    * `troupe-daemon config` loads the configuration from a scratch workspace
    * `troupe-daemon run` starts, and `troupe-daemon status` sees it inside the timeout:
      the daemon installed in %LOCALAPPDATA%\Programs\troupe-daemon, by the program that
      listens where daemon.json says, not whichever daemon answers there
    * `troupe-daemon models` answers while it runs

  The daemon it starts is stopped again at the end, and only that one. Another that
  answers in its place -- a TUI that found no daemon serves its own harness -- fails the
  check and is left running. Exit status 0 is a pass; anything else names the check that
  failed. An issue's own reproduction is not here -- it goes after this, and is written up
  in the pull request.
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

# The program listening where daemon.json says the daemon is, which is what `status` asks:
# the TCP port, or beside a Unix socket the loopback WebSocket every daemon opens. $null
# when there is no such file or nothing listens there.
function Get-DaemonListener {
  $discovery = Join-Path $env:LOCALAPPDATA "troupe\daemon.json"
  try { $json = Get-Content -Raw -LiteralPath $discovery -ErrorAction Stop | ConvertFrom-Json } catch { return $null }
  $port = $null
  if ($json.transport -eq "tcp") { $port = $json.port } elseif ($json.ws) { $port = $json.ws.port }
  if (-not $port) { return $null }
  $listening = $null
  try { $listening = Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction Stop | Select-Object -First 1 } catch { }
  if (-not $listening) { return $null }
  $path = $null
  try { $path = (Get-Process -Id $listening.OwningProcess -ErrorAction Stop).Path } catch { }
  [pscustomobject]@{ Port = $port; Id = $listening.OwningProcess; Path = $path }
}

function Test-Installed($Listener) {
  [bool]($Listener -and $Listener.Path -and $Listener.Path.StartsWith("$LibDir\", [StringComparison]::OrdinalIgnoreCase))
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

  # `run` defers to a daemon that already answers, and `status` passes for any daemon, so
  # it is the program listening that says whose daemon this is.
  $up = $false
  $answers = $false
  $deadline = (Get-Date).AddSeconds($StartTimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    & $Shim status *> $null
    $answers = ($LASTEXITCODE -eq 0)
    if ($answers -and (Test-Installed (Get-DaemonListener))) { $up = $true; break }
    if ($proc.HasExited) { break }
    Start-Sleep -Milliseconds 750
  }
  if ($up) { Pass "troupe-daemon run starts and status sees it" }
  elseif ($answers) {
    $other = Get-DaemonListener
    if ($other) {
      Fail "troupe-daemon status sees a daemon that is not the one installed in $LibDir"
      Write-Host "      pid $($other.Id), listening on port $($other.Port): $($other.Path)"
      Write-Host "      run defers to a daemon that already answers, so the installed one was not started."
      Write-Host "      A TUI that finds no daemon serves its own harness: close it and run this again."
      Write-Host "      It was left running."
    }
    else {
      Fail "troupe-daemon status answers, but no program could be found listening where daemon.json says"
    }
  }
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
