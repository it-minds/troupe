<#
.SYNOPSIS
  troupe-daemon installer for Windows (PowerShell 5.1 and 7).
.DESCRIPTION
  Installs the local daemon the Troupe clients stand on: a release directory under
  %LOCALAPPDATA%\Programs\troupe-daemon and a troupe-daemon.cmd shim in
  %LOCALAPPDATA%\Programs\troupe on the user PATH. The TUI and the desktop app find it
  there (or through TROUPE_DAEMON_COMMAND) and start it when a session needs one.
.EXAMPLE
  irm https://raw.githubusercontent.com/it-minds/troupe/main/install.ps1 | iex
  $env:TROUPE_RELEASE_URL = "https://github.com/it-minds/troupe/releases/download/v0.1.0"; .\install.ps1
  .\install.ps1 -Uninstall [-Purge]
#>
param(
  [switch]$Uninstall,
  [switch]$Purge
)
$ErrorActionPreference = "Stop"

$Version = if ($env:TROUPE_VERSION) { $env:TROUPE_VERSION } else { "0.1.0" }
$BaseUrl = if ($env:TROUPE_RELEASE_URL) { $env:TROUPE_RELEASE_URL } else { "https://github.com/it-minds/troupe/releases/download/v$Version" }
$BinDir = Join-Path $env:LOCALAPPDATA "Programs\troupe"
$LibDir = Join-Path $env:LOCALAPPDATA "Programs\troupe-daemon"
$Shim = Join-Path $BinDir "troupe-daemon.cmd"
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
  Write-Host "removing $Shim and $LibDir"
  Remove-Item -Force -ErrorAction SilentlyContinue $Shim
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
  Write-Host "troupe-daemon uninstalled"
  exit 0
}

$Artifact = "troupe-daemon-$Version-windows_x86_64.tar.gz"
$Tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("troupe-daemon-install-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $Tmp | Out-Null
try {
  Write-Host "downloading $BaseUrl/$Artifact"
  Invoke-WebRequest -UseBasicParsing -Uri "$BaseUrl/$Artifact" -OutFile (Join-Path $Tmp $Artifact)
  Invoke-WebRequest -UseBasicParsing -Uri "$BaseUrl/SHA256SUMS" -OutFile (Join-Path $Tmp "SHA256SUMS")
  $line = Get-Content (Join-Path $Tmp "SHA256SUMS") | Where-Object { $_ -match " \*?$([regex]::Escape($Artifact))$" } | Select-Object -First 1
  if (-not $line) { throw "no checksum for $Artifact in SHA256SUMS" }
  $expected = ($line -split "\s+")[0].ToLower()
  $actual = (Get-FileHash -Algorithm SHA256 (Join-Path $Tmp $Artifact)).Hash.ToLower()
  if ($expected -ne $actual) { throw "checksum mismatch for $Artifact (expected $expected, got $actual); nothing installed" }

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
  Add-ToUserPath
  Write-Host "installed troupe-daemon $Version to $LibDir ($Shim)"
  Write-Host "note: the release is unsigned; SmartScreen may ask for confirmation the first time it runs."
} finally {
  Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $Tmp
}
