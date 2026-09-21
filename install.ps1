<#
.SYNOPSIS
  Troupe installer for Windows (PowerShell 5.1 and 7): the TUI and the daemon it stands on.
.DESCRIPTION
  Installs, from one release of this repository:
    * troupe.exe, the terminal client, in %LOCALAPPDATA%\Programs\troupe;
    * troupe-daemon, the local harness every client stands on: a release directory under
      %LOCALAPPDATA%\Programs\troupe-daemon and a troupe-daemon.cmd shim beside
      troupe.exe. The TUI and the desktop app find it on the PATH (or through
      TROUPE_DAEMON_COMMAND) and start it when a session needs one.
  Both are checked against the release's SHA256SUMS before anything is replaced.

  With no TROUPE_VERSION it installs the latest release, which GitHub names at
  /releases/latest. A private repository answers that only to somebody signed in: set
  TROUPE_VERSION, and TROUPE_RELEASE_URL to wherever your organisation mirrors releases.
.EXAMPLE
  irm https://raw.githubusercontent.com/it-minds/troupe/main/install.ps1 | iex
  $env:TROUPE_VERSION = "0.3.0"; .\install.ps1
  .\install.ps1 -NoTui            # the daemon alone, for the desktop app
  .\install.ps1 -Uninstall [-Purge]
#>
param(
  [switch]$Uninstall,
  [switch]$Purge,
  [switch]$NoTui
)
$ErrorActionPreference = "Stop"

$Repo = if ($env:TROUPE_REPO) { $env:TROUPE_REPO } else { "it-minds/troupe" }
$BinDir = Join-Path $env:LOCALAPPDATA "Programs\troupe"
$LibDir = Join-Path $env:LOCALAPPDATA "Programs\troupe-daemon"
$Shim = Join-Path $BinDir "troupe-daemon.cmd"
$Tui = Join-Path $BinDir "troupe.exe"
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

if ($Uninstall) {
  Write-Host "removing $Tui, $Shim and $LibDir"
  Remove-Item -Force -ErrorAction SilentlyContinue $Shim, $Tui, "$Tui.previous"
  Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $LibDir, "$LibDir.previous"
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
  Write-Host "troupe and troupe-daemon uninstalled"
  exit 0
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
  if (-not $NoTui) { Get-Verified $TuiArtifact }

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
  if (-not $NoTui) {
    if (Test-Path $Tui) { Move-Item -Force $Tui "$Tui.previous" }
    Move-Item -Force (Join-Path $Tmp $TuiArtifact) $Tui
    Write-Host "installed troupe $Version to $Tui"
  }
  Add-ToUserPath
  Write-Host "note: the release is unsigned; SmartScreen may ask for confirmation the first time it runs."
} finally {
  Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $Tmp
}
