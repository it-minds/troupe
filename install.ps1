<#
.SYNOPSIS
  Troupe installer for Windows (PowerShell 5.1 and 7): the daemon, and the clients chosen.
.DESCRIPTION
  The release counterpart of scripts/install-local.ps1. Installs, from one release of this
  repository:
    * troupe-daemon, the local harness, always: a release directory under
      %LOCALAPPDATA%\Programs\troupe-daemon and a troupe-daemon.cmd shim in
      %LOCALAPPDATA%\Programs\troupe. The desktop app finds it there (or on the PATH, or
      through TROUPE_DAEMON_COMMAND) and starts it when a session needs one.
    * troupe.exe, the terminal client (-Tui), beside the shim. It uses a running daemon if
      there is one and otherwise runs the same harness in its own process.
    * the desktop app (-Gui), from the release's per-user setup, run silently. It installs
      into %LOCALAPPDATA%\Programs\troupe-desktop.
    * the VS Code extension (-VSCode): the release's troupe.vsix, handed to VS Code's own
      `code --install-extension`. It opens troupe in VS Code, so it goes with the TUI.
  Everything is downloaded and checked against the release's SHA256SUMS before anything is
  replaced, and Troupe processes running from what is replaced are stopped first.

  In a terminal it shows what it is about to do and asks first, and with none of -Tui,
  -Gui and -VSCode it asks which clients to install. -Yes asks nothing: it installs what the
  switches name, and the daemon alone if they name none. Without a terminal it asks nothing
  either, and naming none then needs -Yes.

  Once the daemon is installed it offers to start it every time you log in: the installed
  troupe-daemon login on, which writes this platform's own per-user entry (here a
  troupe-daemon.cmd in your Startup folder). In a terminal it asks, Enter meaning no, and
  where the daemon starts at login already it says so instead. -StartAtLogin says yes and
  -NoStartAtLogin no, without a question; -Yes alone leaves it as it is, asking nothing
  and turning nothing on. -Uninstall runs troupe-daemon login off before it removes
  anything.

  The copy attached to a release installs that release. TROUPE_VERSION names another; with
  neither it installs the latest release, which GitHub names at /releases/latest. A private
  repository answers that only to somebody signed in: set TROUPE_VERSION, and
  TROUPE_RELEASE_URL to wherever your organisation mirrors releases. TROUPE_BIN_DIR and
  TROUPE_LIB_DIR move the two directories.
.EXAMPLE
  irm https://github.com/it-minds/troupe/releases/latest/download/install.ps1 -OutFile install.ps1
  powershell -ExecutionPolicy Bypass -File .\install.ps1
.EXAMPLE
  .\install.ps1 -Tui -Gui -Yes        # daemon, TUI and desktop app; no questions
  .\install.ps1 -Tui -VSCode          # daemon, TUI and the VS Code extension
  .\install.ps1 -Yes                  # the daemon alone; no questions
  .\install.ps1 -Tui -Yes -StartAtLogin   # daemon and TUI, and the daemon starts at login
  .\install.ps1 -CleanInstall         # remove the current install first; config and state stay
  .\install.ps1 -Uninstall [-Purge]   # -Purge removes config and state as well
  .\install.ps1 -NoModifyPath         # leave the user PATH alone
#>
param(
  [switch]$Tui,
  [switch]$Gui,
  [switch]$VSCode,
  [switch]$Yes,
  [switch]$CleanInstall,
  [switch]$Uninstall,
  [switch]$Purge,
  [switch]$NoModifyPath,
  # Whether the daemon starts at login, answered without the question.
  [switch]$StartAtLogin,
  [switch]$NoStartAtLogin,
  # The daemon alone, as before -Tui and -Gui: the same as -Yes with neither.
  [switch]$NoTui
)
$ErrorActionPreference = "Stop"
# Windows PowerShell 5.1 redraws its progress bar for every chunk, which makes fetching the
# desktop app's setup many times slower than the transfer itself.
$ProgressPreference = "SilentlyContinue"
if ($NoTui) { $Yes = $true }
if ($StartAtLogin -and $NoStartAtLogin) { throw "-StartAtLogin and -NoStartAtLogin say opposite things; pass one of them" }
if ($StartAtLogin -and $Uninstall) { throw "-StartAtLogin goes with an install; -Uninstall turns starting at login off" }

# Set in the copy attached to a release (scripts/release-installers); empty in the repository.
$PinnedVersion = ""

$Repo = if ($env:TROUPE_REPO) { $env:TROUPE_REPO } else { "it-minds/troupe" }
$BinDir = if ($env:TROUPE_BIN_DIR) { $env:TROUPE_BIN_DIR } else { Join-Path $env:LOCALAPPDATA "Programs\troupe" }
$LibDir = if ($env:TROUPE_LIB_DIR) { $env:TROUPE_LIB_DIR } else { Join-Path $env:LOCALAPPDATA "Programs\troupe-daemon" }
$Shim = Join-Path $BinDir "troupe-daemon.cmd"
$TuiExe = Join-Path $BinDir "troupe.exe"
# The daemon's release carries these at its root, and a copy goes beside the programs.
$LicenceFiles = @("LICENSE", "NOTICE", "THIRD-PARTY-NOTICES.txt")
$StateDir = if ($env:TROUPE_STATE_HOME) { $env:TROUPE_STATE_HOME } else { Join-Path $env:LOCALAPPDATA "troupe" }
$ConfigDir = if ($env:TROUPE_CONFIG_HOME) { $env:TROUPE_CONFIG_HOME } else { Join-Path $env:APPDATA "troupe" }
# Where the TUI's Burrito wrapper unpacks itself on first run, once per version.
$BurritoDirs = @((Join-Path $env:APPDATA ".burrito"), (Join-Path $env:LOCALAPPDATA ".burrito"))
# The VS Code extension: its id, and the file a release attaches.
$VSCodeExtension = "objective-mj.troupe"
$Vsix = "troupe.vsix"

# `return`, not `exit`, throughout: run through iex or a scriptblock, `exit` closes the
# person's terminal.
$Interactive = (-not $Yes) -and [Environment]::UserInteractive -and -not [Console]::IsInputRedirected
$PathHadBinDir = ($env:Path -split ";") -contains $BinDir

# Burrito reads <APP>_INSTALL_DIR as where to unpack the TUI, so troupe.exe run from here
# goes without it: set for some other purpose, it would unpack the payload into it.
function Invoke-Tui {
  $saved = $env:TROUPE_INSTALL_DIR
  Remove-Item Env:TROUPE_INSTALL_DIR -ErrorAction SilentlyContinue
  try { & $TuiExe @args } finally { if ($saved) { $env:TROUPE_INSTALL_DIR = $saved } }
}

function Write-Heading([string]$Text) { Write-Host ""; Write-Host $Text -ForegroundColor Cyan }
function Write-Item([string]$Text) { Write-Host "  * $Text" }
function Write-Warn([string]$Text) { Write-Host "warning: $Text" -ForegroundColor Yellow }

function Read-YesNo([string]$Question, [bool]$Default) {
  $hint = if ($Default) { "[Y/n]" } else { "[y/N]" }
  while ($true) {
    $answer = "$(Read-Host "$Question $hint")".Trim().ToLower()
    if ($answer -eq "") { return $Default }
    if ($answer -eq "y" -or $answer -eq "yes") { return $true }
    if ($answer -eq "n" -or $answer -eq "no") { return $false }
  }
}

function Get-UserPathParts {
  $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
  if ($userPath) { return @($userPath -split ";" | Where-Object { $_ }) }
  return @()
}

function Remove-FromUserPath {
  $parts = Get-UserPathParts
  if ($parts -notcontains $BinDir) { return }
  [Environment]::SetEnvironmentVariable("Path", (($parts | Where-Object { $_ -ne $BinDir }) -join ";"), "User")
}

function Add-ToUserPath {
  $parts = Get-UserPathParts
  if ($parts -notcontains $BinDir) {
    [Environment]::SetEnvironmentVariable("Path", (($parts + $BinDir) -join ";"), "User")
    Write-Host "added $BinDir to the user PATH"
  }
  if (($env:Path -split ";") -notcontains $BinDir) { $env:Path = "$BinDir;$env:Path" }
}

# The desktop app's per-user uninstall entry, which its setup writes.
function Get-DesktopEntry {
  Get-ChildItem "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall" -ErrorAction SilentlyContinue |
    ForEach-Object { Get-ItemProperty $_.PSPath } |
    Where-Object { $_.DisplayName -eq "Troupe" -and $_.UninstallString } |
    Select-Object -First 1
}

# VS Code's command line, which installs an extension: TROUPE_VSCODE_CLI, else code.cmd on
# the PATH, else where VS Code's user and system setups put it. Run only where the
# extension is in question, not for a summary: it starts VS Code's own Node.
function Get-CodeCli {
  $candidates = @(
    $env:TROUPE_VSCODE_CLI,
    $(try { (Get-Command code.cmd -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source } catch { $null }),
    (Join-Path $env:LOCALAPPDATA "Programs\Microsoft VS Code\bin\code.cmd"),
    $(if ($env:ProgramFiles) { Join-Path $env:ProgramFiles "Microsoft VS Code\bin\code.cmd" })
  )
  foreach ($c in $candidates) { if ($c -and (Test-Path -PathType Leaf $c)) { return $c } }
  return $null
}

# Windows PowerShell turns a native command's stderr into a terminating error under
# "Stop", and code.cmd's Node writes warnings there.
function Invoke-Code([string]$Cli) {
  $ErrorActionPreference = "Continue"
  $out = @(& $Cli @args 2>$null | ForEach-Object { "$_" })
  return [pscustomobject]@{ Ok = ($LASTEXITCODE -eq 0); Out = $out }
}

function Test-ExtensionInstalled([string]$Cli) {
  if (-not $Cli) { return $false }
  return [bool]((Invoke-Code $Cli --list-extensions).Out | Where-Object { $_ -eq $VSCodeExtension })
}

function Get-DaemonVersion {
  $data = Join-Path $LibDir "releases\start_erl.data"
  if (Test-Path $data) {
    $v = ((Get-Content $data -Raw).Trim() -split "\s+")[1]
    if ($v) { return $v }
  }
  if (Test-Path $LibDir) { return "unknown version" }
  return $null
}

function Test-Under([string]$Path, [string[]]$Prefixes) {
  foreach ($prefix in $Prefixes) {
    if ($prefix -and $Path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { return $true }
  }
  return $false
}

# Troupe processes running from what this installs, by what they are. Another BEAM on this
# machine is somebody else's work, so it is the executable's path that decides.
function Get-Running {
  $burrito = @($BurritoDirs | ForEach-Object { Join-Path $_ "troupe_" })
  $desktopExe = $null
  $entry = Get-DesktopEntry
  if ($entry -and $entry.DisplayIcon) { $desktopExe = "$($entry.DisplayIcon)".Trim('"') }
  foreach ($p in Get-Process) {
    $path = $null
    try { $path = $p.Path } catch { }
    if (-not $path) { continue }
    $what = $null
    if (Test-Under $path @($LibDir)) { $what = "troupe-daemon" }
    elseif (Test-Under $path (@($TuiExe) + $burrito)) { $what = "troupe" }
    elseif ($desktopExe -and (Test-Under $path @($desktopExe))) { $what = "the desktop app" }
    if ($what) { [pscustomobject]@{ What = $what; Id = $p.Id; Process = $p } }
  }
}

function Stop-Running($Procs) {
  foreach ($r in $Procs) {
    Write-Host "stopping $($r.What) (pid $($r.Id))"
    try { Stop-Process -Id $r.Id -Force } catch { }
  }
  foreach ($r in $Procs) { try { [void]$r.Process.WaitForExit(10000) } catch { } }
}

function Format-Pids($Procs, [string]$What) {
  (@($Procs | Where-Object { $_.What -eq $What } | ForEach-Object { $_.Id }) -join ", ")
}

# Burrito unpacks once per version, so a payload left by a build of the same version as the
# new binary would run instead of it.
function Clear-TuiPayload {
  foreach ($base in $BurritoDirs) {
    if (-not (Test-Path $base)) { continue }
    Get-ChildItem -Path $base -Directory -Filter "troupe_*" -ErrorAction SilentlyContinue | ForEach-Object {
      Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $_.FullName
      if (Test-Path $_.FullName) { Write-Warn "could not remove $($_.FullName); close troupe and delete it by hand" }
    }
  }
}

function Uninstall-Desktop {
  $entry = Get-DesktopEntry
  if (-not $entry) { return }
  $uninstaller = if ($entry.UninstallString -match '^"([^"]+)"') { $Matches[1] } else { $entry.UninstallString.Trim() }
  Write-Host "running the desktop app's uninstaller silently"
  Start-Process -Wait -FilePath $uninstaller -ArgumentList "/S"
  # An NSIS uninstaller copies itself to %TEMP% and returns at once, and the copy removes
  # the entry last: waiting for the entry to go is waiting for the uninstall.
  $deadline = (Get-Date).AddSeconds(60)
  while ((Get-DesktopEntry) -and ((Get-Date) -lt $deadline)) { Start-Sleep -Milliseconds 500 }
  if (Get-DesktopEntry) { Write-Warn "the desktop app's uninstaller has not finished after a minute; see Settings > Apps" }
}

# What this installer (or scripts/install-local.ps1) put on the machine, bar config and
# state, and bar the PATH entry: a clean install puts everything back in the same place.
# A desktop app set up before 0.5.2 is in %LOCALAPPDATA%\Troupe, which is the state
# directory, until a newer setup moves it; its uninstaller removes only its own files, so
# the state stays.
function Remove-Installed {
  Remove-Item -Force -ErrorAction SilentlyContinue $Shim, $TuiExe, "$TuiExe.previous"
  Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $LibDir, "$LibDir.previous", "$LibDir.new"
  foreach ($doc in $LicenceFiles) { Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $BinDir $doc) }
  foreach ($left in @($LibDir, $TuiExe)) {
    if (Test-Path $left) { Write-Warn "could not remove $left; something still runs from it" }
  }
  Clear-TuiPayload
  Uninstall-Desktop
}

# A model is the one thing a first run cannot do without. opencode's providers are copied
# by the daemon, once: Troupe does not read opencode's settings. Otherwise, or after a no,
# the next step is `troupe config` where the TUI is installed, and the desktop app's
# Models panel or the file itself where it is not: only the TUI has the command.
function Show-ModelSettings {
  # Windows PowerShell turns a native command's stderr into a terminating error under
  # "Stop"; here a failure is an answer to report, not a reason to stop.
  $ErrorActionPreference = "Continue"
  Write-Heading "Model settings"
  $configFile = Join-Path $ConfigDir "config.yaml"
  $home_ = if ($env:HOME) { $env:HOME } else { $env:USERPROFILE }
  $opencodeFile = if ($env:TROUPE_OPENCODE_CONFIG) { $env:TROUPE_OPENCODE_CONFIG }
    elseif ($env:XDG_CONFIG_HOME) { Join-Path $env:XDG_CONFIG_HOME "opencode\opencode.jsonc" }
    else { Join-Path $home_ ".config\opencode\opencode.jsonc" }
  $report = if ($Tui) { "troupe config" } else { "troupe-daemon config" }
  if (Test-Path $configFile) {
    Write-Host "  $configFile"
    Write-Host "  $report shows what Troupe will use."
    return
  }
  Write-Host "  No $configFile yet, so no model is set up."
  if (Test-Path $opencodeFile) {
    Write-Host "  opencode is set up here ($opencodeFile). Troupe does not read its settings;"
    Write-Host "  it can copy its providers."
    if (-not $Interactive) {
      Write-Host "  troupe-daemon config import-opencode copies them into $configFile."
      return
    }
    if (Read-YesNo "  Copy them into $configFile, keys as opencode has them written?" $true) {
      # A daemon from before the command answers "unknown arguments"; say so, not its usage.
      $copied = @(& $Shim config import-opencode 2>&1 | ForEach-Object { "$_" })
      if ($LASTEXITCODE -eq 0) {
        $copied | ForEach-Object { Write-Host "  $_" }
        return
      }
      Write-Host "  could not copy them: $($copied | Select-Object -First 1)"
    }
  }
  if ($Tui -and $Interactive) {
    if (Read-YesNo "  Set it up now, with troupe config?" $true) {
      Invoke-Tui config
      return
    }
  }
  if ($Tui) {
    Write-Host "  Next: troupe config sets one up, then troupe in a project directory opens a session."
  } elseif ($Gui -or (Get-DesktopEntry)) {
    Write-Host "  Next: set one up in the desktop app (This computer > Models), or write that file."
  } else {
    Write-Host "  Next: write that file."
  }
  Write-Host "  The simplest config.yaml takes the key from the environment:"
  Write-Host "      provider: anthropic"
  Write-Host "      api_key: `"{env:ANTHROPIC_API_KEY}`""
  if ($Tui) {
    Write-Host "  Or take your organisation's settings: troupe login <plane-url>, then troupe config pull."
  } else {
    Write-Host "  $report then shows what Troupe will use."
  }
  Write-Host "  First run: https://github.com/$Repo/blob/v$Version/docs/user/README.md#first-run"
}

# Where the entry that starts the daemon at login is, as the installed daemon says (the
# entry is the daemon's, and so are its paths: Decision 762), or $null when there is none.
# A daemon from before `login` answers "unknown arguments", and wrote none either.
function Get-StartAtLogin {
  $ErrorActionPreference = "Continue"
  if (-not (Test-Path $Shim)) { return $null }
  $said = @(& $Shim login status 2>&1 | ForEach-Object { "$_" })
  if ($LASTEXITCODE -ne 0) { return $null }
  foreach ($line in $said) { if ($line -match "starts at login: (.+)$") { return $Matches[1].Trim() } }
  return "$said".Trim()
}

# Whether the daemon starts when this person logs in, offered once it is installed
# (Decision 818). A yes is the installed `troupe-daemon login on`, a no is nothing at all,
# and where an entry is there already there is nothing to ask. -StartAtLogin and
# -NoStartAtLogin answer without the question; -Yes alone, or no terminal, asks nothing
# and turns nothing on.
function Set-StartAtLogin {
  $ErrorActionPreference = "Continue"
  Write-Heading "Start at login"
  if ($NoStartAtLogin) {
    Write-Host "  Left as it is (-NoStartAtLogin); troupe-daemon login on or off changes it."
    return
  }
  if (-not $StartAtLogin) {
    $entry = Get-StartAtLogin
    if ($entry) {
      Write-Host "  troupe-daemon starts when you log in: $entry"
      Write-Host "  troupe-daemon login off takes that back."
      return
    }
    if (-not $Interactive) {
      Write-Host "  troupe-daemon starts when a client needs it; troupe-daemon login on has it start"
      Write-Host "  every time you log in instead (-StartAtLogin, when installing)."
      return
    }
    if (-not (Read-YesNo "  Start troupe-daemon when you log in, so it is running before any window is?" $false)) {
      Write-Host "  Left off: troupe-daemon login on turns it on later."
      return
    }
  }
  $said = @(& $Shim login on 2>&1 | ForEach-Object { "$_" })
  if ($LASTEXITCODE -eq 0) {
    $said | ForEach-Object { Write-Host "  $_" }
  } else {
    Write-Warn "could not have troupe-daemon start at login: $($said | Select-Object -First 1)"
  }
}

# The first thing an uninstall does, while the daemon that knows where its entry is is
# still there (Decision 818): otherwise the entry would go on starting a program that is
# gone. A daemon from before `login` wrote none, and answers "unknown arguments".
function Disable-StartAtLogin {
  $ErrorActionPreference = "Continue"
  if (-not (Test-Path $Shim)) { return }
  $said = @(& $Shim login off 2>&1 | ForEach-Object { "$_" })
  if ($LASTEXITCODE -eq 0) {
    $said | ForEach-Object { Write-Host $_ }
    return
  }
  if ("$said" -match "unknown arguments") { return }
  Write-Warn "troupe-daemon login off failed ($($said | Select-Object -First 1)); what starts it at login may be left behind"
}

function Write-RemovalPlan([bool]$PurgeToo) {
  $daemonVersion = Get-DaemonVersion
  $entry = Get-DesktopEntry
  if ($daemonVersion) { Write-Item "remove troupe-daemon $daemonVersion ($LibDir, $Shim)" }
  if (Test-Path $TuiExe) { Write-Item "remove troupe ($TuiExe) and its unpacked payload" }
  if ($entry) { Write-Item "remove the desktop app $($entry.DisplayVersion), with its own uninstaller" }
  if ($PurgeToo) {
    Write-Item "DELETE config ($ConfigDir) and state, sessions included ($StateDir)"
  } else {
    Write-Item "keep config ($ConfigDir) and state ($StateDir)"
  }
}

function Write-StopPlan($Procs) {
  foreach ($what in @("troupe-daemon", "troupe", "the desktop app")) {
    $pids = Format-Pids $Procs $what
    if (-not $pids) { continue }
    if ($what -eq "troupe-daemon") { Write-Item "stop troupe-daemon (pid $pids); the sessions it runs end" }
    else { Write-Item "stop $what (pid $pids)" }
  }
}

function Get-InstalledSummary {
  $parts = @()
  $daemonVersion = Get-DaemonVersion
  $entry = Get-DesktopEntry
  if ($daemonVersion) { $parts += "troupe-daemon $daemonVersion" }
  if (Test-Path $TuiExe) { $parts += "troupe" }
  if ($entry) { $parts += "the desktop app $($entry.DisplayVersion)" }
  return ($parts -join ", ")
}

if ($Uninstall) {
  Write-Heading "Uninstall Troupe"
  $codeCli = Get-CodeCli
  $extensionWas = Test-ExtensionInstalled $codeCli
  if (-not (Get-InstalledSummary) -and -not $extensionWas -and -not $Purge) {
    Write-Host "  nothing of Troupe's is installed here"
    Remove-FromUserPath
    return
  }
  $running = @(Get-Running)
  $atLogin = Get-StartAtLogin
  if ($atLogin) { Write-Item "remove what starts troupe-daemon at login ($atLogin)" }
  Write-StopPlan $running
  Write-RemovalPlan $Purge
  if ($extensionWas) { Write-Item "remove the VS Code extension ($VSCodeExtension)" }
  if ((Get-UserPathParts) -contains $BinDir) { Write-Item "take $BinDir off the user PATH" }
  if ($Interactive) {
    Write-Host ""
    if (-not (Read-YesNo "Go ahead?" (-not $Purge))) { Write-Host "nothing changed"; return }
  }
  Disable-StartAtLogin
  Stop-Running @(Get-Running)
  Remove-Installed
  if ($extensionWas -and -not (Invoke-Code $codeCli --uninstall-extension $VSCodeExtension).Ok) {
    Write-Warn "could not remove the VS Code extension; remove it in VS Code"
  }
  if ((Test-Path $BinDir) -and -not (Get-ChildItem $BinDir)) { Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $BinDir }
  Remove-FromUserPath
  # After the desktop app's uninstaller: one set up before 0.5.2 is in the state directory.
  if ($Purge) { Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $ConfigDir, $StateDir }
  Write-Host "troupe uninstalled" -ForegroundColor Green
  return
}

if ($Purge -and -not $CleanInstall) { throw "-Purge goes with -Uninstall or -CleanInstall" }

# TROUPE_VERSION, else the release this copy came with, else the newest release that is not
# a pre-release: GitHub redirects /releases/latest to its tag.
$Version = $null
$VersionFrom = "the latest release"
if ($env:TROUPE_VERSION) {
  $Version = $env:TROUPE_VERSION; $VersionFrom = "TROUPE_VERSION"
} elseif ($PinnedVersion) {
  $Version = $PinnedVersion; $VersionFrom = "the release this installer came with"
} else {
  try {
    $response = Invoke-WebRequest -UseBasicParsing -Uri "https://github.com/$Repo/releases/latest"
    $final = $response.BaseResponse.ResponseUri
    if (-not $final) { $final = $response.BaseResponse.RequestMessage.RequestUri }
    if ("$final" -match "/tag/v(.+)$") { $Version = $Matches[1] }
  } catch { }
  if (-not $Version) { throw "could not find the latest release of $Repo (a private repository needs TROUPE_VERSION, and TROUPE_RELEASE_URL if releases are mirrored)" }
}
$Version = $Version.TrimStart("v")
$BaseUrl = if ($env:TROUPE_RELEASE_URL) { $env:TROUPE_RELEASE_URL } else { "https://github.com/$Repo/releases/download/v$Version" }

$Was = Get-InstalledSummary
$TuiWas = Test-Path $TuiExe
$DesktopWas = [bool](Get-DesktopEntry)
Write-Heading "Troupe installer"
Write-Host "  release    $Version ($VersionFrom)"
Write-Host "  platform   windows_x86_64"
Write-Host "  installed  $(if ($Was) { $Was } else { 'nothing yet' })"

$CodeCli = $null
if ($VSCode) {
  $CodeCli = Get-CodeCli
  if (-not $CodeCli) { throw "-VSCode, but no VS Code command line here (code.cmd): install VS Code, or set TROUPE_VSCODE_CLI" }
}

if (-not $Tui -and -not $Gui -and -not $VSCode) {
  if ($Interactive) {
    Write-Heading "What to install"
    Write-Host "  troupe-daemon, the local harness, always. And:"
    $Tui = Read-YesNo "  troupe, the terminal client?" ((-not $Was) -or $TuiWas)
    $Gui = Read-YesNo "  Troupe, the desktop app?" ((-not $Was) -or $DesktopWas)
    # Asked only where VS Code is, and yes by default where it opens a TUI being installed.
    $CodeCli = Get-CodeCli
    if ($CodeCli) {
      $VSCode = Read-YesNo "  The VS Code extension, which opens troupe in VS Code?" (((-not $Was) -and $Tui) -or (Test-ExtensionInstalled $CodeCli))
    }
  } elseif (-not $Yes) {
    throw "none of -Tui, -Gui and -VSCode given, and no terminal to ask on; pass -Yes to install the daemon alone"
  }
}

$Artifact = "troupe-daemon-$Version-windows_x86_64.tar.gz"
$TuiArtifact = "troupe-$Version-windows_x86_64.exe"
# The desktop app's version drops the pre-release part (WiX refuses one; see
# scripts/version.exs), so its setup is named after 0.3.3 in release 0.3.3-rc.1.
$GuiArtifact = "Troupe_$(($Version -split '-')[0])_x64-setup.exe"

# The TUI is stopped only when its unpacked payload is about to go, the desktop app only
# when it is about to be replaced (its setup would close it anyway).
function Select-ToStop($Procs) {
  @($Procs | Where-Object {
      $_.What -eq "troupe-daemon" -or
      ($_.What -eq "troupe" -and ($Tui -or $CleanInstall)) -or
      ($_.What -eq "the desktop app" -and ($Gui -or $CleanInstall))
    })
}

Write-Heading "Plan"
$names = @("troupe-daemon")
if ($Tui) { $names += "troupe" }
if ($Gui) { $names += "the desktop app" }
if ($VSCode) { $names += "the VS Code extension" }
Write-Item "download $($names -join ', ') $Version and check each against SHA256SUMS"
Write-StopPlan (Select-ToStop @(Get-Running))
if ($CleanInstall -and $Was) { Write-RemovalPlan $Purge }
$daemonVersion = Get-DaemonVersion
if ($daemonVersion -and -not $CleanInstall) {
  Write-Item "replace troupe-daemon $daemonVersion in $LibDir (kept as troupe-daemon.previous)"
} else {
  Write-Item "install troupe-daemon in $LibDir, with $Shim"
}
if ($Tui) {
  if ($TuiWas -and -not $CleanInstall) { Write-Item "replace troupe at $TuiExe (kept as troupe.exe.previous)" }
  else { Write-Item "install troupe as $TuiExe" }
}
if ($Gui) { Write-Item "run the desktop app's setup silently (per user, no admin rights)" }
if ($VSCode) {
  Write-Item "install the VS Code extension with $CodeCli"
  if (-not $Tui -and -not $TuiWas) { Write-Item "(the extension runs troupe, which this leaves out: add -Tui)" }
}
$AddPath = (-not $NoModifyPath) -and ((Get-UserPathParts) -notcontains $BinDir)
if ($AddPath) { Write-Item "add $BinDir to the user PATH" }
if ($StartAtLogin) { Write-Item "have troupe-daemon start when you log in (troupe-daemon login on)" }
if ($Interactive) {
  Write-Host ""
  if (-not (Read-YesNo "Go ahead?" (-not $Purge))) { Write-Host "nothing changed"; return }
}

$Tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("troupe-install-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $Tmp | Out-Null

# Download one artifact of the release into $Tmp and check it against SHA256SUMS.
function Get-Verified([string]$Name) {
  Write-Host "  $Name " -NoNewline
  try {
    Invoke-WebRequest -UseBasicParsing -Uri "$BaseUrl/$Name" -OutFile (Join-Path $Tmp $Name)
  } catch {
    Write-Host ""
    throw "download of $BaseUrl/$Name failed: $($_.Exception.Message)"
  }
  $line = Get-Content (Join-Path $Tmp "SHA256SUMS") | Where-Object { $_ -match " \*?$([regex]::Escape($Name))$" } | Select-Object -First 1
  if (-not $line) { Write-Host ""; throw "no checksum for $Name in SHA256SUMS" }
  $expected = ($line -split "\s+")[0].ToLower()
  $actual = (Get-FileHash -Algorithm SHA256 (Join-Path $Tmp $Name)).Hash.ToLower()
  if ($expected -ne $actual) { Write-Host ""; throw "checksum mismatch for $Name (expected $expected, got $actual); nothing installed" }
  Write-Host "ok" -ForegroundColor Green
}

try {
  Write-Heading "Download"
  try {
    Invoke-WebRequest -UseBasicParsing -Uri "$BaseUrl/SHA256SUMS" -OutFile (Join-Path $Tmp "SHA256SUMS")
  } catch {
    throw "download of $BaseUrl/SHA256SUMS failed: $($_.Exception.Message)"
  }
  # Everything is downloaded and checked before anything is replaced.
  Get-Verified $Artifact
  if ($Tui) { Get-Verified $TuiArtifact }
  if ($Gui) { Get-Verified $GuiArtifact }
  if ($VSCode) { Get-Verified $Vsix }

  Write-Heading "Install"
  Stop-Running (Select-ToStop @(Get-Running))
  if ($CleanInstall) {
    Write-Host "removing the current install"
    Remove-Installed
    if ($Purge) { Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $ConfigDir, $StateDir }
  }

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
    try {
      Move-Item -Force $LibDir "$LibDir.previous"
    } catch {
      throw "could not move $LibDir aside; something still runs from it (Task Manager: erl.exe). Nothing was replaced."
    }
  }
  Move-Item -Force $Staging $LibDir

  New-Item -ItemType Directory -Force -Path $BinDir | Out-Null
  Set-Content -Path $Shim -Encoding ASCII -Value "@echo off`r`ncall `"$LibDir\bin\troupe-daemon.cmd`" %*`r`nexit /b %errorlevel%"
  Write-Host "installed troupe-daemon $Version in $LibDir"
  # A release from before they were in the archive has none to copy.
  foreach ($doc in $LicenceFiles) {
    $target = Join-Path $BinDir $doc
    Remove-Item -Force -ErrorAction SilentlyContinue $target
    if (Test-Path (Join-Path $LibDir $doc)) { Copy-Item -Force (Join-Path $LibDir $doc) $target }
  }

  # One binary; the one it replaces is kept beside it for rollback.
  if ($Tui) {
    if (Test-Path $TuiExe) {
      if (Test-Path "$TuiExe.previous") { Remove-Item -Force "$TuiExe.previous" }
      Move-Item -Force $TuiExe "$TuiExe.previous"
    }
    Move-Item -Force (Join-Path $Tmp $TuiArtifact) $TuiExe
    Clear-TuiPayload
    Write-Host "installed troupe $Version as $TuiExe"
  }

  # The setup installs per user (no elevation) and replaces an older version in place.
  if ($Gui) {
    Write-Host "running $GuiArtifact silently"
    $setup = Start-Process -Wait -PassThru -FilePath (Join-Path $Tmp $GuiArtifact) -ArgumentList "/S"
    if ($setup.ExitCode -ne 0) { throw "$GuiArtifact exited with $($setup.ExitCode); close Troupe if it is running and try again" }
    Write-Host "installed the desktop app $Version"
  }

  # Into every VS Code profile code.cmd installs into. A failure leaves the rest installed,
  # so it is said, not thrown.
  if ($VSCode) {
    if ((Invoke-Code $CodeCli --install-extension (Join-Path $Tmp $Vsix) --force).Ok) {
      Write-Host "installed the VS Code extension $Version with $CodeCli"
    } else {
      Write-Warn "$CodeCli --install-extension failed; install $BaseUrl/$Vsix from VS Code (Extensions: Install from VSIX...)"
    }
  }

  if ($AddPath) { Add-ToUserPath }

  Write-Heading "Check"
  & $Shim version
  if ($Tui) { Invoke-Tui --version }
} finally {
  Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $Tmp
}

Show-ModelSettings
Set-StartAtLogin

Write-Heading "Done: Troupe $Version"
if (-not $PathHadBinDir) {
  if ($NoModifyPath -and -not ((Get-UserPathParts) -contains $BinDir)) {
    Write-Item "$BinDir is not on your PATH; add it, or run the programs by their full path"
  } else {
    Write-Item "open a new terminal for the PATH change, or in this one:"
    Write-Host "      `$env:Path = `"$BinDir;`" + `$env:Path"
  }
}
if ($Tui) {
  Write-Item "troupe config     sets up a model, or shows the one in use"
  Write-Item "troupe            then the TUI, in a project directory"
}
if ($Gui) { Write-Item "Troupe            the desktop app, in the Start menu" }
if ($VSCode) { Write-Item "VS Code           Troupe: Open, or the mask in the activity bar (a window open already: Developer: Reload Window)" }
Write-Item "the desktop app starts the daemon when it needs one; so does troupe"
Write-Item "the release is unsigned: SmartScreen may ask the first time something runs"
Write-Item "install.ps1 -Uninstall removes it again (-Purge: config and state too)"
