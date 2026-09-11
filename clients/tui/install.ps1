<#
.SYNOPSIS
  Troupe installer for Windows (PowerShell 5.1 and 7).
.EXAMPLE
  irm https://<host>/install.ps1 | iex
  $env:TROUPE_RELEASE_URL = "https://forge.example.com/org/troupe/releases/download/v0.1.0"; .\install.ps1
  .\install.ps1 -Uninstall [-Purge]
#>
param(
  [switch]$Uninstall,
  [switch]$Purge
)
$ErrorActionPreference = "Stop"

$Version = if ($env:TROUPE_VERSION) { $env:TROUPE_VERSION } else { "0.1.0" }
$BaseUrl = if ($env:TROUPE_RELEASE_URL) { $env:TROUPE_RELEASE_URL } else { "https://github.com/it-minds/troupe/releases/download/v$Version" }
$InstallDir = Join-Path $env:LOCALAPPDATA "Programs\troupe"
$Bin = Join-Path $InstallDir "troupe.exe"
$StateDir = if ($env:TROUPE_STATE_DIR) { $env:TROUPE_STATE_DIR } else { Join-Path $env:LOCALAPPDATA "troupe" }
$ConfigDir = if ($env:TROUPE_CONFIG_DIR) { $env:TROUPE_CONFIG_DIR } else { Join-Path $env:APPDATA "troupe" }
$PayloadCacheBase = Join-Path $env:LOCALAPPDATA ".burrito"

function Remove-FromUserPath {
  $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
  if ($null -eq $userPath) { return }
  $parts = $userPath -split ";" | Where-Object { $_ -and ($_ -ne $InstallDir) }
  [Environment]::SetEnvironmentVariable("Path", ($parts -join ";"), "User")
}

function Add-ToUserPath {
  $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
  $parts = @()
  if ($userPath) { $parts = $userPath -split ";" }
  if ($parts -notcontains $InstallDir) {
    [Environment]::SetEnvironmentVariable("Path", (($parts + $InstallDir) -join ";"), "User")
    Write-Host "added $InstallDir to the user PATH (open a new terminal)"
  }
  if (($env:Path -split ";") -notcontains $InstallDir) { $env:Path = "$InstallDir;$env:Path" }
}

if ($Uninstall) {
  Write-Host "removing $Bin"
  Remove-Item -Force -ErrorAction SilentlyContinue $Bin, "$Bin.previous"
  if (Test-Path $InstallDir) { Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $InstallDir }
  Remove-FromUserPath
  if (Test-Path $PayloadCacheBase) {
    Get-ChildItem -Directory -Path $PayloadCacheBase -Filter "troupe_*" | ForEach-Object {
      Write-Host "removing payload cache $($_.FullName)"; Remove-Item -Recurse -Force $_.FullName
    }
  }
  if ($Purge) {
    Write-Host "purging config $ConfigDir and state $StateDir"
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $ConfigDir, $StateDir
  } else {
    Write-Host "kept config ($ConfigDir) and state ($StateDir); pass -Purge to remove them"
  }
  Write-Host "troupe uninstalled"
  exit 0
}

$Artifact = "troupe-$Version-windows_x86_64.exe"
$Tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("troupe-install-" + [guid]::NewGuid())
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

  New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
  if (Test-Path $Bin) {
    Write-Host "keeping previous binary as $Bin.previous"
    Move-Item -Force $Bin "$Bin.previous"
  }
  Move-Item -Force (Join-Path $Tmp $Artifact) $Bin
  Add-ToUserPath
  Write-Host "installed troupe $Version to $Bin"
  Write-Host "note: the binary is unsigned; SmartScreen may ask for confirmation the first time it runs."
} finally {
  Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $Tmp
}
