<#
.SYNOPSIS
  The Windows toolchain that builds `troupe-daemon` and the TUI from source.
.DESCRIPTION
  Installs, per user and without administrator rights, the three tools the native
  builds need, at the versions `.github/workflows/native.yml` pins:

    * Erlang/OTP     -- the official installer, into %LOCALAPPDATA%\Programs\erlang
    * Elixir         -- the precompiled `elixir-otp-28` zip, into %LOCALAPPDATA%\Programs\elixir
    * Zig            -- through winget, which carries the pinned version

  A Mix release carries the build host's ERTS, so the machine that runs the binary is
  the machine that builds it: WSL's toolchain produces Linux binaries and cannot make
  the Windows ones. That is why this exists beside the mise setup the umbrella uses.

  Everything lands under %LOCALAPPDATA%\Programs and on the user PATH. Nothing is
  installed twice: a version already present is left alone.
.EXAMPLE
  .\scripts\setup-windows-toolchain.ps1
  .\scripts\setup-windows-toolchain.ps1 -Force      # reinstall even if the version matches
#>
param([switch]$Force)

$ErrorActionPreference = "Stop"

# The versions CI builds with. Change them here and in native.yml together.
$OtpVersion = "28.5.0.5"
$ElixirVersion = "1.20.4"
$ElixirOtpMajor = "28"
$ZigVersion = "0.16.0"

$Programs = Join-Path $env:LOCALAPPDATA "Programs"
$ErlangDir = Join-Path $Programs "erlang"
$ElixirDir = Join-Path $Programs "elixir"
$Downloads = Join-Path $env:TEMP "troupe-toolchain"

function Add-ToUserPath([string]$Dir) {
  $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
  $parts = if ($userPath) { $userPath -split ";" } else { @() }
  if ($parts -notcontains $Dir) {
    [Environment]::SetEnvironmentVariable("Path", (($parts + $Dir) -join ";"), "User")
    Write-Host "  added $Dir to the user PATH (open a new terminal to see it)"
  }
  if (($env:Path -split ";") -notcontains $Dir) { $env:Path = "$Dir;$env:Path" }
}

function Get-File([string]$Url, [string]$Into) {
  New-Item -ItemType Directory -Force -Path $Downloads | Out-Null
  $path = Join-Path $Downloads $Into
  if (Test-Path $path) { return $path }
  Write-Host "  downloading $Url"
  Invoke-WebRequest -Uri $Url -OutFile $path -UseBasicParsing
  return $path
}

# -- Erlang ------------------------------------------------------------------
# The installer is NSIS: /S is silent and /D= is the target, which must come last and
# unquoted. Installing under LOCALAPPDATA keeps it out of Program Files and so out of
# the elevation prompt.
$erlBin = Join-Path $ErlangDir "erts-*\bin\erl.exe"
if ($Force -or -not (Get-ChildItem -Path $erlBin -ErrorAction SilentlyContinue)) {
  Write-Host "Erlang/OTP $OtpVersion"
  $url = "https://github.com/erlang/otp/releases/download/OTP-$OtpVersion/otp_win64_$OtpVersion.exe"
  $exe = Get-File $url "otp_win64_$OtpVersion.exe"
  Write-Host "  installing into $ErlangDir"
  $p = Start-Process -FilePath $exe -ArgumentList "/S", "/D=$ErlangDir" -Wait -PassThru
  if ($p.ExitCode -ne 0) { throw "the Erlang installer exited $($p.ExitCode)" }
}
else {
  Write-Host "Erlang/OTP already in $ErlangDir"
}
Add-ToUserPath (Join-Path $ErlangDir "bin")

# -- Elixir ------------------------------------------------------------------
# The precompiled build for this OTP major. Elixir is BEAM bytecode, so there is no
# installer: unzip it and put its bin on the PATH.
$elixirBat = Join-Path $ElixirDir "bin\elixir.bat"
if ($Force -or -not (Test-Path $elixirBat)) {
  Write-Host "Elixir $ElixirVersion (OTP $ElixirOtpMajor)"
  $url = "https://github.com/elixir-lang/elixir/releases/download/v$ElixirVersion/elixir-otp-$ElixirOtpMajor.zip"
  $zip = Get-File $url "elixir-$ElixirVersion-otp-$ElixirOtpMajor.zip"
  Write-Host "  unpacking into $ElixirDir"
  Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $ElixirDir
  Expand-Archive -Path $zip -DestinationPath $ElixirDir -Force
}
else {
  Write-Host "Elixir already in $ElixirDir"
}
Add-ToUserPath (Join-Path $ElixirDir "bin")

# -- Zig ---------------------------------------------------------------------
# Burrito builds the TUI's launcher with it, and the ezstd NIF is compiled with it on
# Windows (the it-minds/ezstd win32-zig fork this repository pins).
if ($Force -or -not (Get-Command zig -ErrorAction SilentlyContinue)) {
  Write-Host "Zig $ZigVersion (winget)"
  winget install --id zig.zig --version $ZigVersion --exact --accept-package-agreements --accept-source-agreements --silent
}
else {
  Write-Host "Zig already installed: $((Get-Command zig).Source)"
}

# -- Hex and rebar -----------------------------------------------------------
Write-Host "Hex and rebar3"
& (Join-Path $ElixirDir "bin\mix.bat") local.hex --force --if-missing | Out-Null
& (Join-Path $ElixirDir "bin\mix.bat") local.rebar --force --if-missing | Out-Null

# Burrito packs the TUI with xz as well as zig. Nobody ships it for Windows on its own,
# and Git for Windows carries one, so this reports rather than installs: the build script
# finds it there without anything being put on the PATH.
$xz =
  Get-Command xz -ErrorAction SilentlyContinue |
  Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue

if (-not $xz) {
  $xz =
    Get-ChildItem (Join-Path $env:ProgramFiles "Git\mingw64\bin\xz.exe"), (Join-Path $env:ProgramFiles "Git\usr\bin\xz.exe") -ErrorAction SilentlyContinue |
    Select-Object -First 1 -ExpandProperty FullName
}

Write-Host ""
Write-Host "toolchain ready:"
foreach ($c in "erl", "elixir", "mix", "zig") {
  $found = Get-Command $c -ErrorAction SilentlyContinue
  Write-Host ("  {0,-6} {1}" -f $c, $(if ($found) { $found.Source } else { "NOT ON PATH -- open a new terminal" }))
}
Write-Host ("  {0,-6} {1}" -f "xz", $(if ($xz) { $xz } else { "NOT FOUND -- install Git for Windows, or build with -NoTui (the TUI needs it)" }))
Write-Host ""
Write-Host "now build and install from this checkout:  .\scripts\install-local.ps1"
