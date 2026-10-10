#!/bin/sh
# Troupe installer for Linux and macOS (POSIX sh): the daemon, and the clients chosen.
#
#   curl -fsSLO https://github.com/it-minds/troupe/releases/latest/download/install.sh
#   sh install.sh                        # asks which clients, shows the plan, asks to go on
#
#   sh install.sh --tui --gui -y         # daemon, TUI and desktop app; no questions
#   sh install.sh --tui --vscode         # daemon, TUI and the VS Code extension
#   sh install.sh -y                     # the daemon alone; no questions
#   sh install.sh --tui -y --start-at-login   # daemon and TUI, and the daemon starts at login
#   sh install.sh --clean-install        # remove the current install first; config and state stay
#   sh install.sh --uninstall [--purge]  # --purge removes config and state as well
#   sh install.sh --no-modify-path       # leave shell profiles alone
#
# The release counterpart of scripts/install-local. Installs, from one release of this
# repository:
#   * `troupe-daemon`, the local harness, always -- a release directory under
#     ~/.local/lib/troupe-daemon and a link in ~/.local/bin. The desktop app finds it there
#     (or on the PATH, or through TROUPE_DAEMON_COMMAND) and starts it when a session needs
#     one.
#   * `troupe`, the terminal client (--tui) -- one binary, in ~/.local/bin. It uses a
#     running daemon if there is one and otherwise runs the same harness in its own process.
#   * the desktop app (--gui): on Linux the release's AppImage, as ~/.local/bin/troupe-desktop
#     with a menu entry; on macOS Troupe.app in ~/Applications.
#   * the VS Code extension (--vscode): the release's troupe.vsix, handed to VS Code's own
#     `code --install-extension`. It opens `troupe` in VS Code, so it goes with the TUI.
#   * LICENSE, NOTICE and THIRD-PARTY-NOTICES.txt, from the daemon's release, in
#     ~/.local/share/doc/troupe.
# Everything is downloaded and checked against the release's SHA256SUMS before anything is
# replaced, and a daemon or TUI running from what is replaced is stopped first.
#
# In a terminal it shows what it is about to do and asks first, and with none of --tui,
# --gui and --vscode it asks which clients to install. -y asks nothing: it installs what the
# flags name, and the daemon alone if they name none. Without a terminal it asks nothing
# either, and naming none then needs -y.
#
# Once the daemon is installed it offers to start it every time you log in: the installed
# `troupe-daemon login on`, which writes this platform's own per-user entry (a launchd
# agent on macOS; a systemd user unit on Linux, or an autostart entry without systemd). In
# a terminal it asks, Enter meaning no, and where the daemon starts at login already it
# says so instead. --start-at-login says yes and --no-start-at-login no, without a
# question; -y alone leaves it as it is, asking nothing and turning nothing on.
# --uninstall runs `troupe-daemon login off` before it removes anything.
#
# The copy attached to a release installs that release. TROUPE_VERSION names another; with
# neither it installs the latest release, which GitHub names at /releases/latest. A private
# repository answers that only to somebody signed in: set TROUPE_VERSION, and
# TROUPE_RELEASE_URL to wherever your organisation mirrors releases. TROUPE_BIN_DIR and
# TROUPE_LIB_DIR move the two directories.
set -eu

# Set in the copy attached to a release (scripts/release-installers); empty in the repository.
PINNED_VERSION=""

REPO="${TROUPE_REPO:-it-minds/troupe}"
BIN_DIR="${TROUPE_BIN_DIR:-${TROUPE_INSTALL_DIR:-$HOME/.local/bin}}"
# Burrito reads <APP>_INSTALL_DIR as where to unpack the TUI, so the older name for the
# directory above would send every `troupe` this script runs to unpack itself into it.
unset TROUPE_INSTALL_DIR
LIB_DIR="${TROUPE_LIB_DIR:-$HOME/.local/lib/troupe-daemon}"
BIN="$BIN_DIR/troupe-daemon"
TUI="$BIN_DIR/troupe"
GUI="$BIN_DIR/troupe-desktop"
MAC_APP="$HOME/Applications/Troupe.app"
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}"
DESKTOP_FILE="$DATA_DIR/applications/troupe.desktop"
ICON="$DATA_DIR/icons/hicolor/128x128/apps/troupe.png"
# LICENSE, NOTICE and THIRD-PARTY-NOTICES.txt: the daemon's release carries them at its
# root, and a copy goes here for the programs in $BIN_DIR, which is no place for them.
DOC_DIR="$DATA_DIR/doc/troupe"
LICENCE_FILES="LICENSE NOTICE THIRD-PARTY-NOTICES.txt"
STATE_DIR="${TROUPE_STATE_HOME:-${XDG_STATE_HOME:-$HOME/.local/state}/troupe}"
CONFIG_DIR="${TROUPE_CONFIG_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/troupe}"
OS=$(uname -s)
# Where the TUI's Burrito wrapper unpacks itself on first run, once per version.
if [ "$OS" = Darwin ]; then BURRITO_DIR="$HOME/Library/Application Support/.burrito"; else BURRITO_DIR="$DATA_DIR/.burrito"; fi
MARK='# added by troupe installer'
# The VS Code extension: its id, and the file a release attaches.
VSCODE_EXTENSION="objective-mj.troupe"
VSIX="troupe.vsix"
# A mirror may be plain HTTP; GitHub never is, and a redirect off HTTPS is refused.
case "${TROUPE_RELEASE_URL:-}" in http://*) PROTO='=http,https' ;; *) PROTO='=https' ;; esac

if [ -t 1 ]; then BOLD=$(printf '\033[1m'); PLAIN=$(printf '\033[0m'); else BOLD=; PLAIN=; fi
say() { printf '%s\n' "$*"; }
heading() { printf '\n%s%s%s\n' "$BOLD" "$*" "$PLAIN"; }
item() { printf '  * %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
get() { curl -fsSL --retry 3 --proto "$PROTO" --tlsv1.2 "$@"; }

# y or n, from the terminal: `curl | sh` still has one although its stdin is the script.
ask() {
  if [ "$2" = y ]; then hint="[Y/n]"; else hint="[y/N]"; fi
  while :; do
    printf '%s %s ' "$1" "$hint"
    read -r answer </dev/tty || answer=
    case "$answer" in
      "") [ "$2" = y ]; return ;;
      [Yy] | [Yy][Ee][Ss]) return 0 ;;
      [Nn] | [Nn][Oo]) return 1 ;;
    esac
  done
}

detect_target() {
  case "$OS" in
    Linux) os=linux ;;
    Darwin) os=macos ;;
    *) die "unsupported OS: $OS" ;;
  esac
  case "$(uname -m)" in
    x86_64 | amd64) arch=x86_64 ;;
    aarch64 | arm64) arch=aarch64 ;;
    *) die "unsupported architecture: $(uname -m)" ;;
  esac
  printf '%s_%s' "$os" "$arch"
}

# The desktop app's version drops the pre-release part (WiX refuses one; see
# scripts/version.exs), so its artifacts are named after 0.3.3 in release 0.3.3-rc.1.
gui_artifact_for() {
  case "$1" in
    linux_x86_64) printf 'Troupe_%s_amd64.AppImage' "${VERSION%%-*}" ;;
    macos_*) printf 'Troupe_%s_universal.dmg' "${VERSION%%-*}" ;;
  esac
}

daemon_version() {
  if [ -f "$LIB_DIR/releases/start_erl.data" ]; then
    awk '{print $2}' "$LIB_DIR/releases/start_erl.data"
  elif [ -d "$LIB_DIR" ]; then
    printf 'unknown version'
  fi
}

gui_installed() {
  if [ "$OS" = Darwin ]; then [ -d "$MAC_APP" ]; else [ -e "$GUI" ]; fi
}

installed_summary() {
  summary=
  dv=$(daemon_version)
  if [ -n "$dv" ]; then summary="troupe-daemon $dv"; fi
  if [ -e "$TUI" ]; then summary="${summary:+$summary, }troupe"; fi
  if gui_installed; then summary="${summary:+$summary, }the desktop app"; fi
  printf '%s' "$summary"
}

# VS Code's command line, which installs an extension: TROUPE_VSCODE_CLI, else `code` on the
# PATH, else the one inside the macOS app, which VS Code puts on the PATH only when asked.
# In a WSL or SSH window's terminal, `code` is the remote's, and installs it there. It is
# run only where the extension is in question: a first `code` in WSL sets up VS Code's
# server there, which is no part of a summary.
code_cli() {
  for cli in "${TROUPE_VSCODE_CLI:-}" "$(command -v code 2>/dev/null || true)" \
    "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code" \
    "$HOME/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"; do
    if [ -n "$cli" ] && [ -x "$cli" ]; then printf '%s' "$cli"; return 0; fi
  done
  return 1
}

extension_installed() {
  cli=$(code_cli) || return 1
  "$cli" --list-extensions 2>/dev/null | grep -qix "$VSCODE_EXTENSION"
}

# The extension, from the release, into every VS Code that `code` installs into. A failure
# here leaves the rest installed, so it is said, not fatal.
install_extension() {
  if "$code" --install-extension "$tmp/$VSIX" --force >/dev/null 2>&1; then
    say "installed the VS Code extension $VERSION with $code"
  else
    say "warning: $code --install-extension failed; install $BASE_URL/$VSIX from VS Code (Extensions: Install from VSIX...)"
  fi
}

# Pids whose command line matches, space-separated. A release's BEAM names its own
# erts-*/bin on it, which is how a daemon or a TUI running from here is told apart.
pids_of() {
  { pgrep -f "$1" 2>/dev/null || true; } | grep -vx "$$" | tr '\n' ' ' | sed 's/ *$//'
}
DAEMON_MATCH="$LIB_DIR[^ /]*/erts-"
TUI_MATCH="$BURRITO_DIR/troupe_"

stop_pids() {
  if [ -z "$2" ]; then return 0; fi
  for pid in $2; do
    say "stopping $1 (pid $pid)"
    kill "$pid" 2>/dev/null || true
  done
  tries=0
  while [ "$tries" -lt 10 ]; do
    alive=
    for pid in $2; do
      if kill -0 "$pid" 2>/dev/null; then alive=1; fi
    done
    if [ -z "$alive" ]; then return 0; fi
    sleep 1
    tries=$((tries + 1))
  done
  say "warning: $1 did not stop within ten seconds"
}

# The file a new terminal of this person's shell reads. A fresh Mac has no ~/.zshrc, and
# zsh never reads ~/.profile, so the first existing file is not good enough.
profile_file() {
  shell=${SHELL:-sh}
  case "${shell##*/}" in
    zsh) printf '%s' "${ZDOTDIR:-$HOME}/.zshrc" ;;
    bash) if [ "$OS" = Darwin ]; then printf '%s' "$HOME/.bash_profile"; else printf '%s' "$HOME/.bashrc"; fi ;;
    fish) printf '%s' "${XDG_CONFIG_HOME:-$HOME/.config}/fish/conf.d/troupe.fish" ;;
    *) printf '%s' "$HOME/.profile" ;;
  esac
}

on_path() {
  case ":$PATH:" in *":$BIN_DIR:"*) return 0 ;; esac
  return 1
}

add_to_path() {
  rc=$(profile_file)
  if [ -f "$rc" ] && grep -q "$MARK" "$rc" 2>/dev/null; then return 0; fi
  mkdir -p "$(dirname "$rc")"
  case "$rc" in
    *.fish) line="contains -- \"$BIN_DIR\" \$PATH; or set -gx PATH \"$BIN_DIR\" \$PATH $MARK" ;;
    *) line="export PATH=\"$BIN_DIR:\$PATH\" $MARK" ;;
  esac
  printf '\n%s\n' "$line" >>"$rc"
  say "added $BIN_DIR to PATH in $rc"
}

remove_path_line() {
  for rc in "${ZDOTDIR:-$HOME}/.zshrc" "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.profile"; do
    [ -f "$rc" ] || continue
    if grep -q "$MARK" "$rc" 2>/dev/null; then
      scratch=$(mktemp)
      grep -v "$MARK" "$rc" >"$scratch" || true
      cat "$scratch" >"$rc"
      rm -f "$scratch"
    fi
  done
  rm -f "${XDG_CONFIG_HOME:-$HOME/.config}/fish/conf.d/troupe.fish"
}

clear_tui_payload() {
  [ -d "$BURRITO_DIR" ] || return 0
  for dir in "$BURRITO_DIR"/troupe_*; do
    if [ -d "$dir" ]; then rm -rf "$dir"; fi
  done
}

# What this installer (or scripts/install-local) put on the machine, bar config and state,
# and bar the PATH line: a clean install puts everything back in the same place.
remove_installed() {
  rm -f "$BIN" "$TUI" "$TUI.previous" "$GUI" "$GUI.previous" "$DESKTOP_FILE" "$ICON"
  rm -rf "$LIB_DIR" "$LIB_DIR.previous" "$LIB_DIR.new" "$DOC_DIR"
  if [ "$OS" = Darwin ]; then rm -rf "$MAC_APP"; fi
  clear_tui_payload
}

plan_removal() {
  dv=$(daemon_version)
  if [ -n "$dv" ]; then item "remove troupe-daemon $dv ($LIB_DIR, $BIN)"; fi
  if [ -e "$TUI" ]; then item "remove troupe ($TUI) and its unpacked payload"; fi
  if gui_installed; then
    if [ "$OS" = Darwin ]; then item "remove the desktop app ($MAC_APP)"; else item "remove the desktop app ($GUI) and its menu entry"; fi
  fi
  if [ "$mode" = uninstall ] && [ "$ext" = 1 ]; then item "remove the VS Code extension ($VSCODE_EXTENSION)"; fi
  if [ "$1" = 1 ]; then
    item "DELETE config ($CONFIG_DIR) and state, sessions included ($STATE_DIR)"
  else
    item "keep config ($CONFIG_DIR) and state ($STATE_DIR)"
  fi
}

# Go on only if the person says so, when there is a person to ask.
go_ahead() {
  if [ "$tty" = 0 ]; then return 0; fi
  printf '\n'
  if ask "Go ahead?" "$1"; then return 0; fi
  say "nothing changed"
  exit 1
}

uninstall() {
  heading "Uninstall Troupe"
  ext=0
  if extension_installed; then ext=1; fi
  if [ -z "$(installed_summary)" ] && [ "$ext" = 0 ] && [ "$purge" = 0 ]; then
    say "  nothing of Troupe's is installed here"
    remove_path_line
    return 0
  fi
  daemon_pids=$(pids_of "$DAEMON_MATCH")
  tui_pids=$(pids_of "$TUI_MATCH")
  if entry=$(login_entry); then item "remove what starts troupe-daemon at login ($entry)"; fi
  if [ -n "$daemon_pids" ]; then item "stop troupe-daemon (pid $daemon_pids); the sessions it runs end"; fi
  if [ -n "$tui_pids" ]; then item "stop troupe (pid $tui_pids)"; fi
  plan_removal "$purge"
  item "take the PATH line out of your shell profile, if this installer added one"
  if [ "$purge" = 1 ]; then go_ahead n; else go_ahead y; fi

  stop_at_login
  stop_pids troupe-daemon "$(pids_of "$DAEMON_MATCH")"
  stop_pids troupe "$(pids_of "$TUI_MATCH")"
  remove_installed
  if [ "$ext" = 1 ]; then
    "$(code_cli)" --uninstall-extension "$VSCODE_EXTENSION" >/dev/null 2>&1 || say "warning: could not remove the VS Code extension; remove it in VS Code"
  fi
  remove_path_line
  if [ "$purge" = 1 ]; then rm -rf "$CONFIG_DIR" "$STATE_DIR"; fi
  say "troupe uninstalled"
}

# The newest release that is not a pre-release: GitHub redirects /releases/latest to its tag.
latest_version() {
  url=$(get -I -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest") || return 1
  case "$url" in */tag/v*) printf '%s' "${url##*/tag/v}" ;; *) return 1 ;; esac
}

# Download one artifact of the release into $tmp and check it against SHA256SUMS.
fetch() {
  artifact=$1
  printf '  %s ' "$artifact"
  get -o "$tmp/$artifact" "$BASE_URL/$artifact" || die "download of $BASE_URL/$artifact failed"
  expected=$(grep " \*\{0,1\}$artifact\$" "$tmp/SHA256SUMS" | awk '{print $1}')
  [ -n "$expected" ] || die "no checksum for $artifact in SHA256SUMS"
  if command -v sha256sum >/dev/null 2>&1; then
    actual=$(sha256sum "$tmp/$artifact" | awk '{print $1}')
  else
    actual=$(shasum -a 256 "$tmp/$artifact" | awk '{print $1}')
  fi
  [ "$expected" = "$actual" ] || die "checksum mismatch for $artifact (expected $expected, got $actual); nothing installed"
  say "ok"
}

# FUSE 2, which an AppImage needs to start. ldconfig lives in /sbin, which a person's PATH
# often leaves out; with no ldconfig at all, say nothing rather than guess.
fuse2_missing() {
  for ldconfig in "$(command -v ldconfig 2>/dev/null || true)" /sbin/ldconfig /usr/sbin/ldconfig; do
    if [ -n "$ldconfig" ] && [ -x "$ldconfig" ]; then
      if "$ldconfig" -p 2>/dev/null | grep -q 'libfuse\.so\.2'; then return 1; fi
      return 0
    fi
  done
  return 1
}

install_gui_linux() {
  if [ -e "$GUI" ]; then mv -f "$GUI" "$GUI.previous"; fi
  mv -f "$tmp/$gui_artifact" "$GUI"
  chmod +x "$GUI"
  mkdir -p "$(dirname "$DESKTOP_FILE")" "$(dirname "$ICON")"
  # The AppImage carries its own icon; unpacking it needs no FUSE. Without one the menu
  # entry falls back to the theme's generic icon.
  if (cd "$tmp" && "$GUI" --appimage-extract 'usr/share/icons/hicolor/128x128/*' >/dev/null 2>&1); then
    icon_src=$(find "$tmp/squashfs-root" -type f -name '*.png' 2>/dev/null | head -n 1)
    if [ -n "$icon_src" ]; then cp "$icon_src" "$ICON"; fi
  fi
  cat >"$DESKTOP_FILE" <<EOF
[Desktop Entry]
Type=Application
Name=Troupe
Comment=The Troupe desktop app, release $VERSION
Exec=$GUI
Icon=troupe
Terminal=false
Categories=Development;
EOF
  # scripts/install-local's entry names a local build this has just replaced.
  rm -f "$DATA_DIR/applications/troupe-local.desktop"
  if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$(dirname "$DESKTOP_FILE")" 2>/dev/null || true
  fi
  say "installed the desktop app $VERSION as $GUI (menu entry: Troupe)"
  if fuse2_missing; then
    say "note: an AppImage needs FUSE 2 to start (Ubuntu: sudo apt install libfuse2t64; older: libfuse2)"
  fi
}

install_gui_macos() {
  mnt="$tmp/dmg"
  mkdir -p "$mnt"
  hdiutil attach -nobrowse -readonly -quiet -mountpoint "$mnt" "$tmp/$gui_artifact" || die "could not open $gui_artifact"
  # A mounted image under $tmp would stop the cleanup from removing it.
  trap 'hdiutil detach -quiet "$mnt" 2>/dev/null || true; rm -rf "$tmp"' EXIT
  app=$(find "$mnt" -maxdepth 1 -name '*.app' | head -n 1)
  [ -n "$app" ] || die "$gui_artifact contains no .app"
  mkdir -p "$(dirname "$MAC_APP")"
  rm -rf "$MAC_APP.new"
  cp -R "$app" "$MAC_APP.new"
  hdiutil detach -quiet "$mnt" || true
  trap 'rm -rf "$tmp"' EXIT
  rm -rf "$MAC_APP"
  mv "$MAC_APP.new" "$MAC_APP"
  say "installed the desktop app $VERSION as $MAC_APP"
}

# A model is the one thing a first run cannot do without. opencode's providers are copied
# by the daemon, once: Troupe does not read opencode's settings. Otherwise, or after a no,
# the next step is `troupe config` where the TUI is installed, and the desktop app's
# Models panel or the file itself where it is not: only the TUI has the command.
model_settings() {
  heading "Model settings"
  config_file="$CONFIG_DIR/config.yaml"
  opencode_file="${TROUPE_OPENCODE_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/opencode/opencode.jsonc}"
  if [ "$with_tui" = 1 ]; then report="troupe config"; else report="troupe-daemon config"; fi
  if [ -f "$config_file" ]; then
    say "  $config_file"
    say "  $report shows what Troupe will use."
    return 0
  fi
  say "  No $config_file yet, so no model is set up."
  if [ -f "$opencode_file" ]; then
    say "  opencode is set up here ($opencode_file). Troupe does not read its settings;"
    say "  it can copy its providers."
    if [ "$tty" = 0 ]; then
      say "  troupe-daemon config import-opencode copies them into $config_file."
      return 0
    fi
    if ask "  Copy them into $config_file, keys as opencode has them written?" y; then
      # A daemon from before the command answers "unknown arguments"; say so, not its usage.
      if copied=$("$BIN" config import-opencode 2>&1); then
        printf '%s\n' "$copied" | sed 's/^/  /'
        return 0
      fi
      say "  could not copy them: $(printf '%s\n' "$copied" | head -n 1)"
    fi
  fi
  if [ "$with_tui" = 1 ] && [ "$tty" = 1 ]; then
    if ask "  Set it up now, with troupe config?" y; then
      "$TUI" config </dev/tty || true
      return 0
    fi
  fi
  if [ "$with_tui" = 1 ]; then
    say "  Next: troupe config sets one up, then troupe in a project directory opens a session."
  elif [ "$with_gui" = 1 ] || gui_installed; then
    say "  Next: set one up in the desktop app (This computer > Models), or write that file."
  else
    say "  Next: write that file."
  fi
  say "  The simplest config.yaml takes the key from the environment:"
  say "      provider: anthropic"
  say "      api_key: \"{env:ANTHROPIC_API_KEY}\""
  if [ "$with_tui" = 1 ]; then
    say "  Or take your organisation's settings: troupe login <plane-url>, then troupe config pull."
  else
    say "  $report then shows what Troupe will use."
  fi
  say "  First run: https://github.com/$REPO/blob/v$VERSION/docs/user/README.md#first-run"
}

# Where the entry that starts the daemon at login is, as the installed daemon says (the
# entry is the daemon's, and so are its paths: Decision 762); fails when there is none. A
# daemon from before `login` answers "unknown arguments", and wrote none either.
login_entry() {
  [ -x "$BIN" ] || return 1
  said=$("$BIN" login status 2>/dev/null) || return 1
  printf '%s' "${said#*starts at login: }"
}

# Whether the daemon starts when this person logs in, offered once it is installed
# (Decision 818). A yes is the installed `troupe-daemon login on`, a no is nothing at all,
# and where an entry is there already there is nothing to ask. --start-at-login and
# --no-start-at-login answer without the question; -y alone, or no terminal, asks nothing
# and turns nothing on.
start_at_login() {
  heading "Start at login"
  if [ "$at_login" = off ]; then
    say "  Left as it is (--no-start-at-login); troupe-daemon login on or off changes it."
    return 0
  fi
  if [ "$at_login" = ask ]; then
    if entry=$(login_entry); then
      say "  troupe-daemon starts when you log in: $entry"
      say "  troupe-daemon login off takes that back."
      return 0
    fi
    if [ "$tty" = 0 ]; then
      say "  troupe-daemon starts when a client needs it; troupe-daemon login on has it start"
      say "  every time you log in instead (--start-at-login, when installing)."
      return 0
    fi
    if ! ask "  Start troupe-daemon when you log in, so it is running before any window is?" n; then
      say "  Left off: troupe-daemon login on turns it on later."
      return 0
    fi
  fi
  if said=$("$BIN" login on 2>&1); then
    printf '%s\n' "$said" | sed 's/^/  /'
  else
    say "warning: could not have troupe-daemon start at login: $(printf '%s\n' "$said" | head -n 1)"
  fi
}

# The first thing an uninstall does, while the daemon that knows where its entry is is
# still there (Decision 818): otherwise the entry would go on starting a program that is
# gone. A daemon from before `login` wrote none, and answers "unknown arguments".
stop_at_login() {
  [ -x "$BIN" ] || return 0
  if said=$("$BIN" login off 2>&1); then
    printf '%s\n' "$said"
    return 0
  fi
  case "$said" in *"unknown arguments"*) return 0 ;; esac
  say "warning: troupe-daemon login off failed ($(printf '%s\n' "$said" | head -n 1)); what starts it at login may be left behind"
}

install() {
  if [ "$purge" = 1 ] && [ "$clean" = 0 ]; then die "--purge goes with --uninstall or --clean-install"; fi
  target=$(detect_target)

  version_from="the latest release"
  if [ -n "${TROUPE_VERSION:-}" ]; then
    VERSION=$TROUPE_VERSION; version_from="TROUPE_VERSION"
  elif [ -n "$PINNED_VERSION" ]; then
    VERSION=$PINNED_VERSION; version_from="the release this installer came with"
  else
    VERSION=$(latest_version) || die "could not find the latest release of $REPO (a private repository needs TROUPE_VERSION, and TROUPE_RELEASE_URL if releases are mirrored)"
  fi
  VERSION=${VERSION#v}
  BASE_URL="${TROUPE_RELEASE_URL:-https://github.com/$REPO/releases/download/v${VERSION}}"
  gui_offered=$(gui_artifact_for "$target")
  if [ "$with_gui" = 1 ] && [ -z "$gui_offered" ]; then die "no desktop app is released for $target; leave out --gui"; fi
  code=
  if [ "$with_vscode" = 1 ]; then
    code=$(code_cli) || die "--vscode, but no VS Code command line here: put \`code\` on the PATH (VS Code's command palette: Shell Command: Install 'code' command in PATH), or set TROUPE_VSCODE_CLI"
  fi

  was=$(installed_summary)
  heading "Troupe installer"
  say "  release    $VERSION ($version_from)"
  say "  platform   $target"
  say "  installed  ${was:-nothing yet}"

  if [ "$with_tui" = 0 ] && [ "$with_gui" = 0 ] && [ "$with_vscode" = 0 ]; then
    if [ "$tty" = 1 ]; then
      heading "What to install"
      say "  troupe-daemon, the local harness, always. And:"
      if [ -z "$was" ] || [ -e "$TUI" ]; then d=y; else d=n; fi
      if ask "  troupe, the terminal client?" "$d"; then with_tui=1; fi
      if [ -n "$gui_offered" ]; then
        if [ -z "$was" ] || gui_installed; then d=y; else d=n; fi
        if ask "  Troupe, the desktop app?" "$d"; then with_gui=1; fi
      else
        say "  (no desktop app is released for $target)"
      fi
      # Asked only where VS Code is, and yes by default where it opens a TUI being installed.
      if code=$(code_cli); then
        if { [ -z "$was" ] && [ "$with_tui" = 1 ]; } || extension_installed; then d=y; else d=n; fi
        if ask "  The VS Code extension, which opens troupe in VS Code?" "$d"; then with_vscode=1; else code=; fi
      fi
    elif [ "$yes" = 0 ]; then
      die "none of --tui, --gui and --vscode given, and no terminal to ask on; pass -y to install the daemon alone"
    fi
  fi
  gui_artifact=
  if [ "$with_gui" = 1 ]; then gui_artifact=$gui_offered; fi

  # The TUI is stopped only when its unpacked payload is about to go.
  stop_tui=0
  if [ "$with_tui" = 1 ] || [ "$clean" = 1 ]; then stop_tui=1; fi
  daemon_pids=$(pids_of "$DAEMON_MATCH")
  tui_pids=
  if [ "$stop_tui" = 1 ]; then tui_pids=$(pids_of "$TUI_MATCH"); fi

  heading "Plan"
  what="troupe-daemon"
  if [ "$with_tui" = 1 ]; then what="$what, troupe"; fi
  if [ "$with_gui" = 1 ]; then what="$what, the desktop app"; fi
  if [ "$with_vscode" = 1 ]; then what="$what, the VS Code extension"; fi
  item "download $what $VERSION and check each against SHA256SUMS"
  if [ -n "$daemon_pids" ]; then item "stop troupe-daemon (pid $daemon_pids); the sessions it runs end"; fi
  if [ -n "$tui_pids" ]; then item "stop troupe (pid $tui_pids)"; fi
  if [ "$clean" = 1 ] && [ -n "$was" ]; then plan_removal "$purge"; fi
  dv=$(daemon_version)
  if [ -n "$dv" ] && [ "$clean" = 0 ]; then
    item "replace troupe-daemon $dv in $LIB_DIR (kept as troupe-daemon.previous)"
  else
    item "install troupe-daemon in $LIB_DIR, linked as $BIN"
  fi
  if [ "$with_tui" = 1 ]; then
    if [ -e "$TUI" ] && [ "$clean" = 0 ]; then item "replace troupe at $TUI (kept as troupe.previous)"; else item "install troupe as $TUI"; fi
  fi
  if [ "$with_gui" = 1 ]; then
    if [ "$OS" = Darwin ]; then item "install the desktop app as $MAC_APP"; else item "install the desktop app as $GUI, with a menu entry"; fi
  fi
  if [ "$with_vscode" = 1 ]; then
    item "install the VS Code extension with $code"
    if [ "$with_tui" = 0 ] && [ ! -e "$TUI" ]; then item "(the extension runs troupe, which this leaves out: add --tui)"; fi
  fi
  # 1: this run adds the line; 2: an earlier one did, and a new terminal will have it.
  path_added=0
  if ! on_path && [ "$no_modify_path" = 0 ]; then
    rc=$(profile_file)
    if [ -f "$rc" ] && grep -q "$MARK" "$rc" 2>/dev/null; then
      path_added=2
    else
      item "add $BIN_DIR to PATH in $rc"
      path_added=1
    fi
  fi
  if [ "$at_login" = on ]; then item "have troupe-daemon start when you log in (troupe-daemon login on)"; fi
  if [ "$purge" = 1 ]; then go_ahead n; else go_ahead y; fi

  heading "Download"
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  get -o "$tmp/SHA256SUMS" "$BASE_URL/SHA256SUMS" || die "download of $BASE_URL/SHA256SUMS failed"
  daemon_artifact="troupe-daemon-${VERSION}-${target}.tar.gz"
  tui_artifact="troupe-${VERSION}-${target}"
  # Everything is downloaded and checked before anything is replaced.
  fetch "$daemon_artifact"
  if [ "$with_tui" = 1 ]; then fetch "$tui_artifact"; fi
  if [ -n "$gui_artifact" ]; then fetch "$gui_artifact"; fi
  if [ "$with_vscode" = 1 ]; then fetch "$VSIX"; fi

  heading "Install"
  stop_pids troupe-daemon "$(pids_of "$DAEMON_MATCH")"
  if [ "$stop_tui" = 1 ]; then stop_pids troupe "$(pids_of "$TUI_MATCH")"; fi
  if [ "$clean" = 1 ]; then
    say "removing the current install"
    remove_installed
    if [ "$purge" = 1 ]; then rm -rf "$CONFIG_DIR" "$STATE_DIR"; fi
  fi

  # Unpack beside the current install, then swap: a half-extracted tree is never what
  # `troupe-daemon` on the PATH points at, and the previous release stays for rollback.
  staging="$LIB_DIR.new"
  rm -rf "$staging"
  mkdir -p "$staging"
  tar -xzf "$tmp/$daemon_artifact" -C "$staging" || die "could not unpack $daemon_artifact"
  [ -x "$staging/bin/troupe-daemon" ] || die "$daemon_artifact does not contain bin/troupe-daemon"
  if [ -d "$LIB_DIR" ]; then
    rm -rf "$LIB_DIR.previous"
    mv "$LIB_DIR" "$LIB_DIR.previous"
  fi
  mv "$staging" "$LIB_DIR"
  mkdir -p "$BIN_DIR"
  ln -sf "$LIB_DIR/bin/troupe-daemon" "$BIN"
  say "installed troupe-daemon $VERSION in $LIB_DIR"
  # A release from before they were in the archive has none to copy.
  rm -rf "$DOC_DIR"
  if [ -f "$LIB_DIR/LICENSE" ]; then
    mkdir -p "$DOC_DIR"
    for doc in $LICENCE_FILES; do
      if [ -f "$LIB_DIR/$doc" ]; then cp "$LIB_DIR/$doc" "$DOC_DIR/$doc"; fi
    done
  fi

  # One binary; the one it replaces is kept beside it for rollback. Burrito unpacks once
  # per version, so a payload left by a build of the same version would run instead.
  if [ "$with_tui" = 1 ]; then
    chmod +x "$tmp/$tui_artifact"
    if [ -e "$TUI" ]; then mv -f "$TUI" "$TUI.previous"; fi
    mv -f "$tmp/$tui_artifact" "$TUI"
    clear_tui_payload
    say "installed troupe $VERSION as $TUI"
  fi

  if [ -n "$gui_artifact" ]; then
    case "$target" in
      linux_*) install_gui_linux ;;
      macos_*) install_gui_macos ;;
    esac
  fi

  if [ "$with_vscode" = 1 ]; then install_extension; fi

  if [ "$path_added" = 1 ]; then add_to_path; fi

  heading "Check"
  "$BIN" version || say "warning: troupe-daemon version failed"
  if [ "$with_tui" = 1 ]; then "$TUI" --version || say "warning: troupe --version failed"; fi
  if [ "$OS" = Darwin ]; then
    for f in "$TUI" "$MAC_APP"; do
      if [ -e "$f" ] && xattr -p com.apple.quarantine "$f" >/dev/null 2>&1; then
        say "note: the release is unsigned and quarantined; if Gatekeeper blocks it: xattr -dr com.apple.quarantine $LIB_DIR $TUI $MAC_APP"
        break
      fi
    done
  fi

  model_settings
  start_at_login

  heading "Done: Troupe $VERSION"
  if ! on_path; then
    if [ "$path_added" != 0 ]; then
      item "open a new terminal for the PATH change, or in this one: export PATH=\"$BIN_DIR:\$PATH\""
    else
      item "$BIN_DIR is not on your PATH; add it, or run the programs by their full path"
    fi
  fi
  if [ "$with_tui" = 1 ]; then
    item "troupe config     sets up a model, or shows the one in use"
    item "troupe            then the TUI, in a project directory"
  fi
  if [ "$with_gui" = 1 ]; then
    if [ "$OS" = Darwin ]; then item "Troupe            the desktop app, in ~/Applications"; else item "Troupe            the desktop app, in your applications menu"; fi
  fi
  if [ "$with_vscode" = 1 ]; then
    item "VS Code           Troupe: Open, or the mask in the activity bar (a window open already: Developer: Reload Window)"
  fi
  item "the desktop app starts the daemon when it needs one; so does troupe"
  item "sh install.sh --uninstall removes it again (--purge: config and state too)"
}

purge=0; mode=install; with_tui=0; with_gui=0; with_vscode=0; ext=0; yes=0; clean=0; no_modify_path=0
# ask, on (--start-at-login) or off (--no-start-at-login).
at_login=ask
for arg in "$@"; do
  case "$arg" in
    --tui) with_tui=1 ;;
    --gui) with_gui=1 ;;
    --vscode) with_vscode=1 ;;
    -y | --yes) yes=1 ;;
    --no-tui) yes=1 ;; # the daemon alone, as before --tui and --gui
    --clean-install) clean=1 ;;
    --uninstall) mode=uninstall ;;
    --purge) purge=1 ;;
    --no-modify-path) no_modify_path=1 ;;
    --start-at-login | --no-start-at-login)
      if [ "$arg" = --start-at-login ]; then said=on; else said=off; fi
      if [ "$at_login" != ask ] && [ "$at_login" != "$said" ]; then die "--start-at-login and --no-start-at-login say opposite things; pass one of them"; fi
      at_login=$said
      ;;
    --help | -h)
      say "usage: install.sh [--tui] [--gui] [--vscode] [-y] [--start-at-login | --no-start-at-login]"
      say "                  [--clean-install [--purge]] [--no-modify-path]"
      say "       install.sh --uninstall [--purge] [-y]"
      exit 0
      ;;
    *) die "unknown argument $arg (--help lists them)" ;;
  esac
done
if [ "$mode" = uninstall ] && [ "$at_login" = on ]; then die "--start-at-login goes with an install; --uninstall turns starting at login off"; fi

tty=0
if [ "$yes" = 0 ] && (: </dev/tty) 2>/dev/null; then tty=1; fi

if [ "$mode" = uninstall ]; then uninstall; else install; fi
