<#
.SYNOPSIS
  The installers' own checks, for install.ps1 (install.sh has scripts/check-installers).
.DESCRIPTION
  Runs install.ps1, in this PowerShell, against a release of stand-ins in a scratch
  directory: its troupe-daemon only writes down what it is asked, and its login entry is a
  file. Nothing is downloaded and no real install, user PATH entry or login entry is
  touched. The directories, APPDATA and LOCALAPPDATA are the scratch directory's, a
  download is a copy out of it, VS Code's command line is a stand-in, and the desktop
  app's registry entry reads as absent, so its uninstaller is never found. Starting or
  stopping a process fails the check instead.

  The installer asks only on a console, which a check does not have, so the function that
  asks is also checked on its own: lifted out of install.ps1 with the parser, with
  Read-Host answering.

    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\check-installers.ps1
    pwsh -NoProfile -File scripts\check-installers.ps1
#>
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
$Installer = Join-Path $Root "install.ps1"
$Version = "0.0.0-check"
$Work = Join-Path ([System.IO.Path]::GetTempPath()) ("troupe-check-installers-" + [guid]::NewGuid())
$CheckRelease = Join-Path $Work "release"
$CodeCli = Join-Path $Work "code.cmd"
$Failures = 0
$CheckTripped = New-Object System.Collections.ArrayList
$CheckAnswers = New-Object System.Collections.Queue
$CheckAsked = New-Object System.Collections.ArrayList
$Question = "Start troupe-daemon when you log in"

# -- what install.ps1 meets instead of the machine --------------------------------------
# A function here is found before the cmdlet of the same name by install.ps1 too, which
# runs in a scope below this one; the installer's own functions are its own. Called from
# there, `$script:` would be install.ps1's scope, so these read this script's variables by
# names the installer does not use.

# Nothing leaves the machine: a download is a copy out of the release directory.
function Invoke-WebRequest {
  param([string]$Uri, [string]$OutFile, [switch]$UseBasicParsing)
  $from = Join-Path $CheckRelease ($Uri.Substring($Uri.LastIndexOf("/") + 1))
  if (-not (Test-Path -LiteralPath $from)) { throw "404: $Uri" }
  Copy-Item -LiteralPath $from -Destination $OutFile
}

# The desktop app's uninstall entry is in the registry, which a check cannot redirect.
function Get-ChildItem {
  if ("$args" -match "HKCU:|HKLM:|Registry::") { return }
  Microsoft.PowerShell.Management\Get-ChildItem @args
}

# A check starts no setup or uninstaller and stops no process.
function Start-Process { [void]$CheckTripped.Add("Start-Process $args"); throw "check-installers: Start-Process $args" }
function Stop-Process { [void]$CheckTripped.Add("Stop-Process $args"); throw "check-installers: Stop-Process $args" }

function Read-Host([string]$Prompt) {
  [void]$CheckAsked.Add($Prompt)
  if ($CheckAnswers.Count -eq 0) { throw "check-installers: asked '$Prompt' with no answer ready" }
  return $CheckAnswers.Dequeue()
}

# -- the release ------------------------------------------------------------------------

# troupe-daemon as the installer sees it. TROUPE_CHECK_DAEMON=old answers `login` as a
# daemon from before it had one; =failing refuses to write or remove the entry.
$StandIn = @'
@echo off
>>"%TROUPE_CHECK_LOG%" echo %*
if "%~1"=="version" goto version
if not "%~1"=="login" goto unknown
if "%TROUPE_CHECK_DAEMON%"=="old" goto unknown
if "%~2"=="status" goto status
if "%TROUPE_CHECK_DAEMON%"=="failing" goto failing
if "%~2"=="on" goto on
if "%~2"=="off" goto off
:unknown
1>&2 echo unknown arguments: %*
exit /b 1
:version
echo troupe-daemon 0.0.0-check
exit /b 0
:status
if not exist "%TROUPE_CHECK_ENTRY%" goto status_off
echo troupe-daemon starts at login: %TROUPE_CHECK_ENTRY%
exit /b 0
:status_off
echo troupe-daemon does not start at login
exit /b 1
:failing
1>&2 echo could not write the entry: permission denied
exit /b 1
:on
>"%TROUPE_CHECK_ENTRY%" echo entry
echo troupe-daemon starts at login: %TROUPE_CHECK_ENTRY%
exit /b 0
:off
if exist "%TROUPE_CHECK_TUI%" >>"%TROUPE_CHECK_LOG%" echo troupe still installed
if not exist "%TROUPE_CHECK_ENTRY%" goto off_nothing
del "%TROUPE_CHECK_ENTRY%"
echo troupe-daemon no longer starts at login: removed %TROUPE_CHECK_ENTRY%
exit /b 0
:off_nothing
echo troupe-daemon does not start at login; there was nothing to remove
exit /b 0
'@

# cmd.exe reads a batch file's labels wrongly when its lines end in LF alone.
function Write-Batch([string]$Path, [string]$Text) {
  [System.IO.File]::WriteAllText($Path, ($Text -replace "`r?`n", "`r`n"), [System.Text.Encoding]::ASCII)
}

function New-Release {
  $daemon = Join-Path $Work "daemon"
  New-Item -ItemType Directory -Force -Path (Join-Path $daemon "bin"), (Join-Path $daemon "releases"), $CheckRelease | Out-Null
  Write-Batch (Join-Path $daemon "bin\troupe-daemon.cmd") $StandIn
  Set-Content -Encoding ASCII -Path (Join-Path $daemon "releases\start_erl.data") -Value "15.0 $Version"
  Write-Batch $CodeCli "@echo off`n>>`"%TROUPE_CHECK_LOG%`" echo code %*`nexit /b 0`n"
  $name = "troupe-daemon-$Version-windows_x86_64.tar.gz"
  & (Join-Path $env:SystemRoot "System32\tar.exe") -czf (Join-Path $CheckRelease $name) -C $daemon bin releases
  if ($LASTEXITCODE -ne 0) { throw "could not pack the stand-in release" }
  $hash = (Get-FileHash -Algorithm SHA256 (Join-Path $CheckRelease $name)).Hash.ToLower()
  Set-Content -Encoding ASCII -Path (Join-Path $CheckRelease "SHA256SUMS") -Value "$hash  $name"
}

# -- running it -------------------------------------------------------------------------

function Set-ProcessEnv([string]$Name, $Value) {
  if ($null -eq $Value -or "$Value" -eq "") { Remove-Item "Env:\$Name" -ErrorAction SilentlyContinue }
  else { Set-Item "Env:\$Name" "$Value" }
}

# The environment one run sees, in $Home_; what it was before comes back afterwards.
function Use-Home([string]$Name, [string]$Daemon) {
  $script:Home_ = Join-Path $Work $Name
  New-Item -ItemType Directory -Force -Path $script:Home_ | Out-Null
  $script:Log = Join-Path $script:Home_ "daemon.log"
  [System.IO.File]::WriteAllText($script:Log, "")
  $vars = @{
    TROUPE_BIN_DIR = (Join-Path $script:Home_ "bin")
    TROUPE_LIB_DIR = (Join-Path $script:Home_ "lib\troupe-daemon")
    TROUPE_STATE_HOME = (Join-Path $script:Home_ "state")
    TROUPE_CONFIG_HOME = (Join-Path $script:Home_ "config")
    TROUPE_OPENCODE_CONFIG = (Join-Path $script:Home_ "no-opencode.jsonc")
    TROUPE_VERSION = $Version
    TROUPE_RELEASE_URL = "https://release.invalid"
    TROUPE_VSCODE_CLI = $CodeCli
    APPDATA = (Join-Path $script:Home_ "Roaming")
    LOCALAPPDATA = (Join-Path $script:Home_ "Local")
    TROUPE_CHECK_LOG = $script:Log
    TROUPE_CHECK_ENTRY = (Join-Path $script:Home_ "login-entry")
    TROUPE_CHECK_TUI = (Join-Path $script:Home_ "bin\troupe.exe")
    TROUPE_CHECK_DAEMON = $Daemon
    TROUPE_REPO = $null
    TROUPE_DAEMON_COMMAND = $null
    TROUPE_INSTALL_DIR = $null
  }
  $saved = @{}
  foreach ($k in $vars.Keys) {
    $saved[$k] = [Environment]::GetEnvironmentVariable($k, "Process")
    Set-ProcessEnv $k $vars[$k]
  }
  return $saved
}

function Restore-Env($Saved) { foreach ($k in $Saved.Keys) { Set-ProcessEnv $k $Saved[$k] } }

# install.ps1 with these switches (-Yes always, and -NoModifyPath on an install) in NAME's
# home, which a later run of the same NAME finds as this one left it. What it printed is
# in $Out, whether it threw in $Threw.
function Invoke-Installer([string]$Name, [hashtable]$Switches, [string]$Daemon = "") {
  $Switches = $Switches.Clone()
  $Switches["Yes"] = $true
  if (-not $Switches["Uninstall"]) { $Switches["NoModifyPath"] = $true }
  $saved = Use-Home $Name $Daemon
  $lines = New-Object System.Collections.ArrayList
  $script:Threw = $false
  try {
    & $Installer @Switches *>&1 | ForEach-Object { [void]$lines.Add("$_") }
  } catch {
    $script:Threw = $true
    [void]$lines.Add("threw: $($_.Exception.Message)")
  } finally {
    Restore-Env $saved
  }
  $script:Out = @($lines)
}

# Set-StartAtLogin on its own, as install.ps1 defines it: an interactive run or not, the
# switches, and what Read-Host answers.
function Invoke-Step([string]$Name, [bool]$Console, [string[]]$Typed = @(), [string]$Daemon = "", [switch]$On, [switch]$Off) {
  $saved = Use-Home "step-$Name" $Daemon
  $script:Shim = Join-Path $Work "daemon\bin\troupe-daemon.cmd"
  $script:Interactive = $Console
  $script:StartAtLogin = [bool]$On
  $script:NoStartAtLogin = [bool]$Off
  $CheckAnswers.Clear()
  foreach ($t in $Typed) { $CheckAnswers.Enqueue($t) }
  $CheckAsked.Clear()
  $lines = New-Object System.Collections.ArrayList
  $script:Threw = $false
  try {
    Set-StartAtLogin *>&1 | ForEach-Object { [void]$lines.Add("$_") }
  } catch {
    $script:Threw = $true
    [void]$lines.Add("threw: $($_.Exception.Message)")
  } finally {
    Restore-Env $saved
  }
  $script:Out = @($lines)
}

# -- what is expected -------------------------------------------------------------------

function Expect([string]$What, [scriptblock]$Holds) {
  if (& $Holds) {
    Write-Host "ok    $What"
  } else {
    Write-Host "FAIL  $What" -ForegroundColor Red
    $script:Out | ForEach-Object { Write-Host "      | $_" }
    Get-Content -LiteralPath $script:Log -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "      daemon: $_" }
    $script:Failures++
  }
}

function Get-Asked { @(Get-Content -LiteralPath $script:Log -ErrorAction SilentlyContinue | ForEach-Object { "$_".Trim() } | Where-Object { $_ }) }
function Test-Asked([string]$Line) { (Get-Asked) -contains $Line }
function Test-Said([string]$Text) { [bool]($script:Out | Where-Object { $_.Contains($Text) }) }
function Test-InOrder([string]$First, [string]$Second) {
  $asked = Get-Asked
  $a = [array]::IndexOf($asked, $First)
  $b = [array]::IndexOf($asked, $Second)
  return ($a -ge 0) -and ($b -gt $a)
}
function Test-There([string]$Relative) { Test-Path -LiteralPath (Join-Path $script:Home_ $Relative) }
# An entry as `troupe-daemon login on` leaves one, from whichever client wrote it.
function Set-Entry([string]$In = $script:Home_) {
  New-Item -ItemType Directory -Force -Path $In | Out-Null
  Set-Content -Encoding ASCII -Path (Join-Path $In "login-entry") -Value "entry"
}

# -- the checks -------------------------------------------------------------------------

try {
  New-Release
  Write-Host "install.ps1 under PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"

  # Before anything runs the uninstall: the registry must read as empty from where the
  # installer runs, or the real desktop app's uninstaller would be found.
  $probe = Join-Path $Work "probe.ps1"
  Set-Content -Encoding ASCII -Path $probe -Value '@(Get-ChildItem "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall" -ErrorAction SilentlyContinue).Count'
  if ((& $probe) -ne 0) { throw "the registry is not hidden from install.ps1 here; stopping before it could uninstall anything real" }

  Invoke-Installer "yes" @{}
  Expect "-Yes installs the daemon" { -not $Threw }
  Expect "-Yes does not turn starting at login on" { -not (Test-Asked "login on") }
  Expect "-Yes says how to turn it on" { Test-Said "troupe-daemon login on" }

  Invoke-Installer "on" @{ StartAtLogin = $true }
  Expect "-StartAtLogin installs" { -not $Threw }
  Expect "-StartAtLogin is in the plan" { Test-Said "have troupe-daemon start when you log in" }
  Expect "-StartAtLogin runs the installed troupe-daemon login on" { Test-Asked "login on" }
  Expect "... once the daemon is installed" { Test-InOrder "version" "login on" }
  Expect "... and the entry is written" { Test-There "login-entry" }

  Set-Entry
  Invoke-Installer "on" @{}
  Expect "-Yes over an entry says it is there" { Test-Said "troupe-daemon starts when you log in" }
  Expect "... and writes nothing" { -not (Test-Asked "login on") }

  Invoke-Installer "off" @{ NoStartAtLogin = $true }
  Expect "-NoStartAtLogin installs" { -not $Threw }
  Expect "-NoStartAtLogin asks the daemon nothing about login" { -not ((Get-Asked) -like "login*") }

  Invoke-Installer "both" @{ StartAtLogin = $true; NoStartAtLogin = $true }
  Expect "-StartAtLogin with -NoStartAtLogin is refused" { $Threw }
  Expect "... before anything is installed" { -not (Test-There "lib\troupe-daemon") }

  Invoke-Installer "both" @{ StartAtLogin = $true; Uninstall = $true }
  Expect "-StartAtLogin with -Uninstall is refused" { $Threw -and (Test-Said "-StartAtLogin") }

  Invoke-Installer "refused" @{ StartAtLogin = $true } "failing"
  Expect "a refused login on leaves the install standing" { -not $Threw }
  Expect "... and says why" { Test-Said "permission denied" }
  Expect "... with the daemon in place" { Test-There "bin\troupe-daemon.cmd" }

  # An entry, and a TUI: what is there when login off runs had not been removed yet.
  Invoke-Installer "gone" @{}
  Set-Entry
  Set-Content -Encoding ASCII -Path (Join-Path $Home_ "bin\troupe.exe") -Value "a stand-in"
  Invoke-Installer "gone" @{ Uninstall = $true }
  Expect "-Uninstall uninstalls" { -not $Threw }
  Expect "-Uninstall's plan names the login entry" { Test-Said "remove what starts troupe-daemon at login" }
  Expect "-Uninstall runs troupe-daemon login off" { Test-Asked "login off" }
  Expect "... before it removes anything" { Test-Asked "troupe still installed" }
  Expect "... so the entry is gone" { -not (Test-There "login-entry") }
  Expect "... and so is the daemon" { -not (Test-There "lib\troupe-daemon") }

  Invoke-Installer "old" @{}
  Invoke-Installer "old" @{ Uninstall = $true } "old"
  Expect "-Uninstall of a daemon from before login on uninstalls" { -not $Threw }
  Expect "... asking it login off" { Test-Asked "login off" }
  Expect "... and saying nothing about its answer" { -not (Test-Said "warning") }
  Expect "... and the daemon is gone" { -not (Test-There "lib\troupe-daemon") }

  Invoke-Installer "stuck" @{}
  Set-Entry
  Invoke-Installer "stuck" @{ Uninstall = $true } "failing"
  Expect "-Uninstall goes on when login off fails" { -not $Threw }
  Expect "... saying why" { Test-Said "permission denied" }
  Expect "... and the daemon is gone" { -not (Test-There "lib\troupe-daemon") }

  Expect "nothing was started or stopped" { $CheckTripped.Count -eq 0 }

  # The question, which needs a console: install.ps1's own functions, lifted out of it.
  Write-Host ""
  Write-Host "the question, asked by install.ps1's own Set-StartAtLogin"
  $wanted = @("Read-YesNo", "Write-Heading", "Write-Item", "Write-Warn", "Get-StartAtLogin", "Set-StartAtLogin")
  $ast = [System.Management.Automation.Language.Parser]::ParseFile($Installer, [ref]$null, [ref]$null)
  $found = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false) |
      Where-Object { $wanted -contains $_.Name })
  foreach ($f in $found) { . ([scriptblock]::Create($f.Extent.Text)) }
  $script:Out = @()
  Expect "install.ps1 defines $($wanted -join ', ')" { $found.Count -eq $wanted.Count }
  if ($found.Count -eq $wanted.Count) {
    Invoke-Step "yes" $true @("y")
    Expect "the question is asked" { ($CheckAsked | Where-Object { $_ -like "*$Question*" }) -and -not $Threw }
    Expect "yes runs troupe-daemon login on" { Test-Asked "login on" }

    Invoke-Step "no" $true @("n")
    Expect "no asks the daemon to write nothing" { -not (Test-Asked "login on") -and -not $Threw }
    Expect "... and says how to later" { Test-Said "troupe-daemon login on" }

    Invoke-Step "enter" $true @("")
    Expect "Enter is no" { -not (Test-Asked "login on") -and -not $Threw }

    Set-Entry (Join-Path $Work "step-there")
    Invoke-Step "there" $true @()
    Expect "an entry already there is not asked about" { ($CheckAsked.Count -eq 0) -and -not $Threw }
    Expect "... but said" { Test-Said "troupe-daemon starts when you log in" }

    Invoke-Step "refused" $true @("y") "failing"
    Expect "a refused yes is said, not thrown" { (Test-Said "permission denied") -and -not $Threw }

    Invoke-Step "no-console" $false @()
    Expect "without a console nothing is asked or written" { ($CheckAsked.Count -eq 0) -and -not (Test-Asked "login on") -and -not $Threw }
  }
} finally {
  Microsoft.PowerShell.Management\Remove-Item -Recurse -Force -ErrorAction SilentlyContinue -LiteralPath $Work
}

Write-Host ""
if ($Failures -gt 0) {
  Write-Host "$Failures failed" -ForegroundColor Red
  exit 1
}
Write-Host "every check held"
