<#
.SYNOPSIS
  Build troupe-daemon and the TUI from this checkout and install them, as a release would.
.DESCRIPTION
  The same two artifacts `install.ps1` downloads, built here instead: the daemon release
  and the TUI's Burrito binary. They land exactly where the installer puts them --
  %LOCALAPPDATA%\Programs\troupe-daemon, with troupe.exe and the troupe-daemon.cmd shim
  in %LOCALAPPDATA%\Programs\troupe -- so the desktop app, the TUI and anything else on
  this machine pick the build up with no further arrangement, and `install.ps1` can put
  a real release back over it at any time.

  A running daemon holds its own files open on Windows, so it is stopped first. Nothing
  starts it again here: the desktop app starts one when a session needs it, and the TUI
  embeds the harness when none is running.

  The previous install is kept as `<dir>.previous` and `troupe.exe.previous`, which is
  what `install.ps1` does and what makes going back one step a rename.

  Needs the toolchain from `scripts\setup-windows-toolchain.ps1` (Erlang, Elixir, Zig).
.EXAMPLE
  .\scripts\install-local.ps1                # both, from the current checkout
  .\scripts\install-local.ps1 -NoTui         # the daemon alone, for the desktop app
  .\scripts\install-local.ps1 -DaemonOnly    # same thing, said the other way
  .\scripts\install-local.ps1 -Rollback      # put the kept previous install back
#>
param(
  [switch]$NoTui,
  [switch]$DaemonOnly,
  [switch]$Rollback
)

$ErrorActionPreference = "Stop"
if ($DaemonOnly) { $NoTui = $true }

$Root = Split-Path -Parent $PSScriptRoot
$BinDir = Join-Path $env:LOCALAPPDATA "Programs\troupe"
$LibDir = Join-Path $env:LOCALAPPDATA "Programs\troupe-daemon"
$Shim = Join-Path $BinDir "troupe-daemon.cmd"
$Tui = Join-Path $BinDir "troupe.exe"
$Target = "windows_x86_64"

function Add-ToUserPath {
  $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
  $parts = if ($userPath) { $userPath -split ";" } else { @() }
  if ($parts -notcontains $BinDir) {
    [Environment]::SetEnvironmentVariable("Path", (($parts + $BinDir) -join ";"), "User")
    Write-Host "added $BinDir to the user PATH (open a new terminal)"
  }
  if (($env:Path -split ";") -notcontains $BinDir) { $env:Path = "$BinDir;$env:Path" }
}

# The ERTS Burrito wraps the TUI in. Left empty when 7-Zip is here, so the build matches
# CI exactly: Burrito downloads the target's precompiled ERTS and unpacks the NSIS
# installer with 7z. Without 7-Zip -- which needs administrator rights to install, and a
# laptop may not have -- it uses the OTP already installed on this machine, which the
# toolchain script pinned to the version CI builds with.
#
# Burrito looks for `erts-*` and `lib` one level below what it is given, so it is handed
# a directory whose only child is a junction to the OTP tree. A junction, because copying
# the tree is hundreds of megabytes and creating one needs no elevation.
function Get-LocalErts {
  if (Get-Command 7z, 7zz -ErrorAction SilentlyContinue) { return "" }

  $otp = Join-Path $env:LOCALAPPDATA "Programs\erlang"
  if (-not (Get-ChildItem (Join-Path $otp "erts-*") -ErrorAction SilentlyContinue)) {
    throw "no 7-Zip, and no OTP in $otp to build against. Run scripts\setup-windows-toolchain.ps1."
  }

  $holder = Join-Path $env:LOCALAPPDATA "Programs\troupe-build\erts"
  $link = Join-Path $holder "otp"
  New-Item -ItemType Directory -Force -Path $holder | Out-Null
  if (Test-Path $link) { (Get-Item $link).Delete() }
  New-Item -ItemType Junction -Path $link -Target $otp | Out-Null
  Write-Host "no 7-Zip: wrapping the TUI in the OTP at $otp"

  # Relative, because Burrito asks "is this a URI?" before "is this a directory?" and a
  # Windows path answers yes: the drive letter in `C:\Users\...` parses as the scheme
  # `c`, and the build then tries to download it. A path with no drive letter has no
  # scheme. It is resolved from the TUI directory, which is where mix runs.
  Push-Location (Join-Path $Root "clients\tui")
  try { return (Resolve-Path -Relative $holder) } finally { Pop-Location }
}

# A daemon serving from the directory about to be replaced. Only that one: another BEAM
# on this machine is somebody else's work.
function Stop-RunningDaemon {
  $running = Get-Process erl, erlsrv, beam.smp -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -and $_.Path.StartsWith($LibDir, [StringComparison]::OrdinalIgnoreCase) }
  foreach ($p in $running) {
    Write-Host "stopping the running daemon (pid $($p.Id))"
    Stop-Process -Id $p.Id -Force
  }
  if ($running) { Start-Sleep -Milliseconds 500 }
}

if ($Rollback) {
  Stop-RunningDaemon
  if (Test-Path "$LibDir.previous") {
    if (Test-Path $LibDir) { Remove-Item -Recurse -Force $LibDir }
    Move-Item "$LibDir.previous" $LibDir
    Write-Host "restored $LibDir from .previous"
  }
  else { Write-Host "no $LibDir.previous to restore" }
  if (Test-Path "$Tui.previous") {
    Move-Item -Force "$Tui.previous" $Tui
    Write-Host "restored $Tui from .previous"
  }
  exit 0
}

foreach ($tool in "mix", "zig") {
  if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
    throw "$tool is not on the PATH. Run scripts\setup-windows-toolchain.ps1, then open a new terminal."
  }
}

$Version = (Get-Content (Join-Path $Root "VERSION") -Raw).Trim()
Write-Host "building troupe $Version from $Root"
Write-Host ""

$env:MIX_ENV = "prod"

# -- the daemon --------------------------------------------------------------
# Built from its own directory, so this compiles the harness and not the plane's
# database and Kubernetes clients (Decision 667), exactly as native.yml does.
Push-Location (Join-Path $Root "apps\troupe_daemon")
try {
  mix deps.get
  if ($LASTEXITCODE -ne 0) { throw "mix deps.get failed for the daemon" }
  mix release troupe_daemon --overwrite
  if ($LASTEXITCODE -ne 0) { throw "the daemon release failed" }
}
finally { Pop-Location }

$Tarball = Join-Path $Root "_build\prod\troupe_daemon-$Version.tar.gz"
if (-not (Test-Path $Tarball)) { throw "expected $Tarball; the release did not produce it" }

# -- the TUI -----------------------------------------------------------------
$TuiBuilt = $null
if (-not $NoTui) {
  Push-Location (Join-Path $Root "clients\tui")
  try {
    $env:BURRITO_TARGET = $Target
    $env:BURRITO_CUSTOM_ERTS = Get-LocalErts
    mix deps.get
    if ($LASTEXITCODE -ne 0) { throw "mix deps.get failed for the TUI" }
    mix release --overwrite
    if ($LASTEXITCODE -ne 0) { throw "the TUI release failed" }
    $TuiBuilt = Join-Path $Root "clients\tui\burrito_out\troupe_$Target.exe"
    if (-not (Test-Path $TuiBuilt)) { throw "expected $TuiBuilt; the Burrito build did not produce it" }
  }
  finally {
    Remove-Item Env:\BURRITO_TARGET -ErrorAction SilentlyContinue
    Remove-Item Env:\BURRITO_CUSTOM_ERTS -ErrorAction SilentlyContinue
    Pop-Location
  }
}

Write-Host ""
Stop-RunningDaemon

# Unpacked beside the current install and then swapped, so the shim never points at a
# half-extracted tree.
$Staging = "$LibDir.new"
if (Test-Path $Staging) { Remove-Item -Recurse -Force $Staging }
New-Item -ItemType Directory -Force -Path $Staging | Out-Null
tar -xzf $Tarball -C $Staging
if ($LASTEXITCODE -ne 0) { throw "could not unpack $Tarball" }
if (-not (Test-Path (Join-Path $Staging "bin\troupe-daemon.cmd"))) {
  throw "the release does not contain bin\troupe-daemon.cmd"
}
if (Test-Path $LibDir) {
  if (Test-Path "$LibDir.previous") { Remove-Item -Recurse -Force "$LibDir.previous" }
  Move-Item -Force $LibDir "$LibDir.previous"
  Write-Host "keeping the previous install as $LibDir.previous"
}
Move-Item -Force $Staging $LibDir

New-Item -ItemType Directory -Force -Path $BinDir | Out-Null
Set-Content -Path $Shim -Encoding ASCII -Value "@echo off`r`ncall `"$LibDir\bin\troupe-daemon.cmd`" %*`r`nexit /b %errorlevel%"
Write-Host "installed troupe-daemon $Version to $LibDir ($Shim)"

if ($TuiBuilt) {
  if (Test-Path $Tui) { Move-Item -Force $Tui "$Tui.previous" }
  Copy-Item -Force $TuiBuilt $Tui
  Write-Host "installed troupe $Version to $Tui"

  # Burrito extracts its payload once per version, so without this a rebuild at the same
  # version keeps running the previous build. On Windows the data dir is %APPDATA%.
  foreach ($base in (Join-Path $env:APPDATA ".burrito"), (Join-Path $env:LOCALAPPDATA ".burrito")) {
    if (-not (Test-Path $base)) { continue }
    Get-ChildItem -Path $base -Directory -Filter "troupe_*" -ErrorAction SilentlyContinue | ForEach-Object {
      Write-Host "removing payload cache $($_.FullName)"
      Remove-Item -Recurse -Force $_.FullName
    }
  }
}

Add-ToUserPath

Write-Host ""
& $Shim version
if (-not $NoTui) { & $Tui --version }
Write-Host ""
Write-Host "done. The desktop app starts the daemon when it needs one; troupe in a workspace starts the TUI."
Write-Host "to go back:  .\scripts\install-local.ps1 -Rollback"
