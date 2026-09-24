<#
.SYNOPSIS
  Troupe installer for Windows (PowerShell 5.1 and 7): the daemon, and the clients asked for.
.DESCRIPTION
  The release counterpart of scripts/install-local, with the same choices. Installs, from
  one release of this repository:
    * troupe-daemon, the local harness, always: a release directory under
      %LOCALAPPDATA%\Programs\troupe-daemon and a troupe-daemon.cmd shim in
      %LOCALAPPDATA%\Programs\troupe. The desktop app finds it there (or on the PATH, or
      through TROUPE_DAEMON_COMMAND) and starts it when a session needs one. A daemon
      running from that directory holds its files open, so it is stopped first.
    * with -Tui, troupe.exe, the terminal client, beside the shim. It uses a running
      daemon if there is one and otherwise runs the same harness in its own process.
    * with -Gui, the desktop app, from the release's per-user setup, run silently.
  Everything is checked against the release's SHA256SUMS before anything is replaced.

  With no TROUPE_VERSION it installs the latest release, which GitHub names at
  /releases/latest. A private repository answers that only to somebody signed in: set
  TROUPE_VERSION, and TROUPE_RELEASE_URL to wherever your organisation mirrors releases.

  `irm ... | iex` cannot pass switches; the scriptblock form below can.
.EXAMPLE
  & ([scriptblock]::Create((irm https://raw.githubusercontent.com/it-minds/troupe/main/install.ps1))) -Tui -Gui
  .\install.ps1 -Tui -Gui         # daemon, TUI and desktop app
  .\install.ps1 -Tui              # daemon and TUI
  .\install.ps1 -Gui              # daemon and desktop app
  .\install.ps1                   # the daemon alone; asks first (-Yes skips that)
  $env:TROUPE_VERSION = "0.3.0"; .\install.ps1 -Tui
  .\install.ps1 -Uninstall [-Purge]
#>
param(
  [switch]$Tui,
  [switch]$Gui,
  [switch]$Yes,
  [switch]$NoTui,
  [switch]$Uninstall,
  [switch]$Purge
)
$ErrorActionPreference = "Stop"
# -NoTui is the daemon alone, as before -Tui and -Gui.
if ($NoTui) { $Yes = $true }

$Repo = if ($env:TROUPE_REPO) { $env:TROUPE_REPO } else { "it-minds/troupe" }
$BinDir = Join-Path $env:LOCALAPPDATA "Programs\troupe"
$LibDir = Join-Path $env:LOCALAPPDATA "Programs\troupe-daemon"
$Shim = Join-Path $BinDir "troupe-daemon.cmd"
$TuiExe = Join-Path $BinDir "troupe.exe"
$StateDir = if ($env:TROUPE_STATE_HOME) { $env:TROUPE_STATE_HOME } else { Join-Path $env:LOCALAPPDATA "troupe" }
$ConfigDir = if ($env:TROUPE_CONFIG_HOME) { $env:TROUPE_CONFIG_HOME } else { Join-Path $env:APPDATA "troupe" }

function Remove-FromUserPath {
  $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
  if ($null -eq $userPath) { return }
  $parts = $userPath -split ";" | Where-Object { $_ -and ($_ -ne $BinDir) }
  [Environment]::SetEnvironmentVariable("Path", ($parts -join ";"), "User")
}

function Add-ToUserPath {
  $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
  $parts = @()
  if ($userPath) { $parts = $userPath -split ";" }
  if ($parts -notcontains $BinDir) {
    [Environment]::SetEnvironmentVariable("Path", (($parts + $BinDir) -join ";"), "User")
    Write-Host "added $BinDir to the user PATH (open a new terminal)"
  }
  if (($env:Path -split ";") -notcontains $BinDir) { $env:Path = "$BinDir;$env:Path" }
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

# The desktop app's per-user uninstall entry, which its setup writes.
function Get-DesktopUninstall {
  Get-ChildItem "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall" -ErrorAction SilentlyContinue |
    ForEach-Object { Get-ItemProperty $_.PSPath } |
    Where-Object { $_.DisplayName -eq "Troupe" -and $_.UninstallString } |
    Select-Object -First 1
}

# `return`, not `exit`, throughout: run through iex or a scriptblock, `exit` closes the
# person's terminal.
if ($Uninstall) {
  Stop-RunningDaemon
  Write-Host "removing $TuiExe, $Shim, $LibDir and the desktop app, where installed"
  Remove-Item -Force -ErrorAction SilentlyContinue $Shim, $TuiExe, "$TuiExe.previous"
  Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $LibDir, "$LibDir.previous"
  $entry = Get-DesktopUninstall
  if ($entry) {
    $uninstaller = $entry.UninstallString.Trim('"')
    Start-Process -Wait -FilePath $uninstaller -ArgumentList "/S"
  }
  if ((Test-Path $BinDir) -and -not (Get-ChildItem $BinDir)) {
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $BinDir
    Remove-FromUserPath
  }
  if ($Purge) {
    Write-Host "purging config $ConfigDir and state $StateDir"
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $ConfigDir, $StateDir
  } else {
    Write-Host "kept config ($ConfigDir) and state ($StateDir); pass -Purge to remove them"
  }
  Write-Host "troupe uninstalled"
  return
}

# The daemon is always installed, the clients only when named. Naming neither is more often
# a forgotten switch than a wish, so it is confirmed.
if (-not $Tui -and -not $Gui -and -not $Yes) {
  Write-Host "warning: neither -Tui nor -Gui given; this installs the daemon only."
  if ([Console]::IsInputRedirected) { throw "no terminal to ask on; pass -Yes to install the daemon only" }
  $answer = Read-Host "continue? (y/n)"
  if ($answer -notmatch '^(y|yes)$') { Write-Host "nothing installed"; return }
}

# The newest release that is not a release candidate: GitHub redirects /releases/latest to
# its tag.
$Version = $env:TROUPE_VERSION
if (-not $Version) {
  try {
    $response = Invoke-WebRequest -UseBasicParsing -Uri "https://github.com/$Repo/releases/latest"
    $final = $response.BaseResponse.ResponseUri
    if (-not $final) { $final = $response.BaseResponse.RequestMessage.RequestUri }
    if ("$final" -match "/tag/v(.+)$") { $Version = $Matches[1] }
  } catch { }
  if (-not $Version) { throw "could not find the latest release of $Repo (a private repository needs TROUPE_VERSION, and TROUPE_RELEASE_URL if releases are mirrored)" }
}
$BaseUrl = if ($env:TROUPE_RELEASE_URL) { $env:TROUPE_RELEASE_URL } else { "https://github.com/$Repo/releases/download/v$Version" }

$Artifact = "troupe-daemon-$Version-windows_x86_64.tar.gz"
$TuiArtifact = "troupe-$Version-windows_x86_64.exe"
# The desktop app's version drops the pre-release part (WiX refuses one; see
# scripts/version.exs), so its setup is named after 0.3.3 in release 0.3.3-rc.1.
$GuiArtifact = "Troupe_$(($Version -split '-')[0])_x64-setup.exe"
$Tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("troupe-install-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $Tmp | Out-Null

# Download one artifact of the release into $Tmp and check it against SHA256SUMS.
function Get-Verified([string]$Name) {
  Write-Host "downloading $BaseUrl/$Name"
  Invoke-WebRequest -UseBasicParsing -Uri "$BaseUrl/$Name" -OutFile (Join-Path $Tmp $Name)
  $line = Get-Content (Join-Path $Tmp "SHA256SUMS") | Where-Object { $_ -match " \*?$([regex]::Escape($Name))$" } | Select-Object -First 1
  if (-not $line) { throw "no checksum for $Name in SHA256SUMS" }
  $expected = ($line -split "\s+")[0].ToLower()
  $actual = (Get-FileHash -Algorithm SHA256 (Join-Path $Tmp $Name)).Hash.ToLower()
  if ($expected -ne $actual) { throw "checksum mismatch for $Name (expected $expected, got $actual); nothing installed" }
}

try {
  Invoke-WebRequest -UseBasicParsing -Uri "$BaseUrl/SHA256SUMS" -OutFile (Join-Path $Tmp "SHA256SUMS")
  # Everything is downloaded and checked before anything is replaced.
  Get-Verified $Artifact
  if ($Tui) { Get-Verified $TuiArtifact }
  if ($Gui) { Get-Verified $GuiArtifact }

  Stop-RunningDaemon

  # Unpack beside the current install, then swap, so the shim never points at a
  # half-extracted tree and the previous release stays for rollback.
  $Staging = "$LibDir.new"
  if (Test-Path $Staging) { Remove-Item -Recurse -Force $Staging }
  New-Item -ItemType Directory -Force -Path $Staging | Out-Null
  tar -xzf (Join-Path $Tmp $Artifact) -C $Staging
  if ($LASTEXITCODE -ne 0) { throw "could not unpack $Artifact" }
  if (-not (Test-Path (Join-Path $Staging "bin\troupe-daemon.cmd"))) { throw "$Artifact does not contain bin\troupe-daemon.cmd" }
  if (Test-Path $LibDir) {
    if (Test-Path "$LibDir.previous") { Remove-Item -Recurse -Force "$LibDir.previous" }
    Move-Item -Force $LibDir "$LibDir.previous"
    Write-Host "keeping the previous release as $LibDir.previous"
  }
  Move-Item -Force $Staging $LibDir

  New-Item -ItemType Directory -Force -Path $BinDir | Out-Null
  Set-Content -Path $Shim -Encoding ASCII -Value "@echo off`r`ncall `"$LibDir\bin\troupe-daemon.cmd`" %*`r`nexit /b %errorlevel%"
  Write-Host "installed troupe-daemon $Version to $LibDir ($Shim)"

  # One binary; the one it replaces is kept beside it for rollback.
  if ($Tui) {
    if (Test-Path $TuiExe) { Move-Item -Force $TuiExe "$TuiExe.previous" }
    Move-Item -Force (Join-Path $Tmp $TuiArtifact) $TuiExe
    Write-Host "installed troupe $Version to $TuiExe"
  }

  # The setup installs per user (no elevation) and replaces an older version in place.
  if ($Gui) {
    Write-Host "running $GuiArtifact silently"
    $setup = Start-Process -Wait -PassThru -FilePath (Join-Path $Tmp $GuiArtifact) -ArgumentList "/S"
    if ($setup.ExitCode -ne 0) { throw "$GuiArtifact exited with $($setup.ExitCode); close Troupe if it is running and try again" }
    Write-Host "installed the Troupe desktop app $Version (Start menu: Troupe)"
  }

  Add-ToUserPath
  & $Shim version
  if ($Tui) { & $TuiExe --version }
  Write-Host "note: the release is unsigned; SmartScreen may ask for confirmation the first time it runs."
  Write-Host "done. The desktop app starts the daemon when it needs one; troupe in a workspace starts the TUI."
} finally {
  Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $Tmp
}
