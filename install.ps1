<#
.SYNOPSIS
Install, upgrade or uninstall troupe on Windows.

.DESCRIPTION
Works on Windows PowerShell 5.1 and PowerShell 7. Installs to
%LOCALAPPDATA%\Programs\troupe\troupe.exe and puts that directory on the user PATH.

The download base is configurable with TROUPE_RELEASE_URL, so artifacts can live on
a Forgejo release, an S3-compatible bucket, or anywhere else — nothing here is
hardwired to one host.

Nothing unverified is ever executed: the SHA-256 is compared against the published
SHA256SUMS before the binary is moved into place, and a mismatch aborts with the
download discarded.

.EXAMPLE
irm <base>/install.ps1 | iex

.EXAMPLE
.\install.ps1 -Uninstall

.EXAMPLE
.\install.ps1 -Uninstall -Purge
#>
[CmdletBinding()]
param(
    [switch]$Uninstall,
    [switch]$Purge,
    [string]$Version,
    [string]$ReleaseUrl = $env:TROUPE_RELEASE_URL,
    [string]$InstallDir = $env:TROUPE_INSTALL_DIR
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not $ReleaseUrl) {
    $ReleaseUrl = 'https://github.com/objective-mj/troupe/releases/latest/download'
}

if (-not $InstallDir) {
    $InstallDir = Join-Path $env:LOCALAPPDATA 'Programs\troupe'
}

$BinaryName = 'troupe.exe'
$PathMarker = 'troupe installer'

function Write-Log { param([string]$Message) Write-Host $Message }
function Fail { param([string]$Message) Write-Error "troupe: $Message"; exit 1 }

function Get-Target {
    # Windows on ARM runs the x86_64 build under emulation; there is no native ARM
    # build, and asking for one would only produce a 404.
    'windows_x86_64'
}

function Get-Fetched {
    param([string]$Url, [string]$Destination)

    if ($Url.StartsWith('file://')) {
        # A local release directory, which is how the installer is tested offline.
        Copy-Item -LiteralPath $Url.Substring(7) -Destination $Destination -Force
        return
    }

    # Invoke-WebRequest, like curl, does not attach the mark-of-the-web that a
    # browser download would, so SmartScreen has one fewer reason to object.
    $previous = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing
    } finally {
        $ProgressPreference = $previous
    }
}

function Get-Sha256 {
    param([string]$Path)
    (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-PayloadCache {
    # Where Burrito extracts the payload on first run.
    Join-Path $env:LOCALAPPDATA '.burrito'
}

function Get-ConfigDir { Join-Path $env:APPDATA 'troupe' }
function Get-StateDir { Join-Path $env:LOCALAPPDATA 'troupe' }

function Add-ToUserPath {
    param([string]$Directory)

    $current = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($null -eq $current) { $current = '' }

    $entries = $current -split ';' | Where-Object { $_ -ne '' }

    # Idempotent: a re-run must not add a second copy.
    if ($entries -contains $Directory) {
        Write-Log "PATH already contains $Directory"
        return
    }

    $updated = (@($entries) + $Directory) -join ';'
    [Environment]::SetEnvironmentVariable('Path', $updated, 'User')

    # So the current session can use it without reopening a terminal.
    $env:Path = "$env:Path;$Directory"
    Write-Log "Added $Directory to your user PATH"
}

function Remove-FromUserPath {
    param([string]$Directory)

    $current = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($null -eq $current) { return }

    $entries = $current -split ';' | Where-Object { $_ -ne '' -and $_ -ne $Directory }
    [Environment]::SetEnvironmentVariable('Path', ($entries -join ';'), 'User')
    Write-Log "Removed $Directory from your user PATH"
}

function Install-Troupe {
    $target = Get-Target
    $temp = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Path $temp -Force | Out-Null

    try {
        $sumsPath = Join-Path $temp 'SHA256SUMS'
        Get-Fetched -Url "$ReleaseUrl/SHA256SUMS" -Destination $sumsPath

        if ($Version) {
            $artifact = "troupe-$Version-$target.exe"
        } else {
            # Without an explicit version the checksums file names the artifact, which
            # keeps this working against a "latest" URL.
            $artifact = Get-Content $sumsPath |
                ForEach-Object { ($_ -split '\s+')[-1] } |
                Where-Object { $_ -like "*$target*" } |
                Select-Object -First 1
        }

        if (-not $artifact) { Fail "no artifact for $target in SHA256SUMS" }

        Write-Log "Downloading $artifact"
        $downloaded = Join-Path $temp $artifact
        Get-Fetched -Url "$ReleaseUrl/$artifact" -Destination $downloaded

        $expected = Get-Content $sumsPath |
            Where-Object { $_ -match [Regex]::Escape($artifact) } |
            ForEach-Object { ($_ -split '\s+')[0] } |
            Select-Object -First 1

        if (-not $expected) { Fail "SHA256SUMS has no entry for $artifact" }

        $actual = Get-Sha256 -Path $downloaded

        if ($expected.ToLowerInvariant() -ne $actual) {
            Remove-Item -LiteralPath $downloaded -Force
            Fail "checksum mismatch for $artifact (expected $expected, got $actual) — nothing was installed"
        }

        Write-Log 'Checksum verified'

        New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
        $destination = Join-Path $InstallDir $BinaryName

        # Keep the previous binary so a bad upgrade can be rolled back by hand.
        if (Test-Path $destination) {
            Move-Item -LiteralPath $destination -Destination "$destination.previous" -Force
            Write-Log "Kept the previous binary at $destination.previous"
        }

        Move-Item -LiteralPath $downloaded -Destination $destination -Force

        Add-ToUserPath -Directory $InstallDir

        Write-Log "Installed to $destination"
        & $destination --version
    } finally {
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Uninstall-Troupe {
    $destination = Join-Path $InstallDir $BinaryName

    foreach ($path in @($destination, "$destination.previous")) {
        if (Test-Path $path) {
            Remove-Item -LiteralPath $path -Force
            Write-Log "Removed $path"
        }
    }

    $cache = Get-PayloadCache
    if (Test-Path $cache) {
        # Only troupe's own extracted payloads; other Burrito apps share this directory.
        Get-ChildItem -LiteralPath $cache -Filter 'troupe_erts-*' -Directory -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force
        Write-Log 'Removed the extracted payload cache'
    }

    Remove-FromUserPath -Directory $InstallDir

    if (Test-Path $InstallDir) {
        $remaining = Get-ChildItem -LiteralPath $InstallDir -Force
        if (-not $remaining) { Remove-Item -LiteralPath $InstallDir -Force }
    }

    if ($Purge) {
        foreach ($path in @((Get-ConfigDir), (Get-StateDir))) {
            if (Test-Path $path) { Remove-Item -LiteralPath $path -Recurse -Force }
        }
        Write-Log 'Removed configuration and session history'
    } else {
        Write-Log "Kept configuration in $(Get-ConfigDir) and session history in $(Get-StateDir)"
        Write-Log 'Pass -Purge to remove those too.'
    }
}

if ($Uninstall) { Uninstall-Troupe } else { Install-Troupe }
