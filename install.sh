#!/bin/sh
# Troupe installer for Linux and macOS (POSIX sh): the daemon, and the clients chosen.
#
#   curl -fsSLO https://github.com/it-minds/troupe/releases/latest/download/install.sh
#   sh install.sh                        # asks which clients, shows the plan, asks to go on
#
#   sh install.sh --tui --gui -y         # daemon, TUI and desktop app; no questions
#   sh install.sh -y                     # the daemon alone; no questions
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
# Everything is downloaded and checked against the release's SHA256SUMS before anything is
# replaced, and a daemon or TUI running from what is replaced is stopped first.
#
# In a terminal it shows what it is about to do and asks first, and with neither --tui nor
# --gui it asks which clients to install. -y asks nothing: it installs what the flags name,
# and the daemon alone if they name neither. Without a terminal it asks nothing either, and
# naming neither then needs -y.
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
STATE_DIR="${TROUPE_STATE_HOME:-${XDG_STATE_HOME:-$HOME/.local/state}/troupe}"
CONFIG_DIR="${TROUPE_CONFIG_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/troupe}"
OS=$(uname -s)
# Where the TUI's Burrito wrapper unpacks itself on first run, once per version.
if [ "$OS" = Darwin ]; then BURRITO_DIR="$HOME/Library/Application Support/.burrito"; else BURRITO_DIR="$DATA_DIR/.burrito"; fi
MARK='# added by troupe installer'
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
  rm -rf "$LIB_DIR" "$LIB_DIR.previous" "$LIB_DIR.new"
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
  if [ -z "$(installed_summary)" ] && [ "$purge" = 0 ]; then
    say "  nothing of Troupe's is installed here"
    remove_path_line
    return 0
  fi
  daemon_pids=$(pids_of "$DAEMON_MATCH")
  tui_pids=$(pids_of "$TUI_MATCH")
  if [ -n "$daemon_pids" ]; then item "stop troupe-daemon (pid $daemon_pids); the sessions it runs end"; fi
  if [ -n "$tui_pids" ]; then item "stop troupe (pid $tui_pids)"; fi
  plan_removal "$purge"
  item "take the PATH line out of your shell profile, if this installer added one"
  if [ "$purge" = 1 ]; then go_ahead n; else go_ahead y; fi

  stop_pids troupe-daemon "$(pids_of "$DAEMON_MATCH")"
  stop_pids troupe "$(pids_of "$TUI_MATCH")"
  remove_installed
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
# by the daemon (Troupe reads them anyway while it has none of its own); `troupe config`
# sets up the rest: a plane's settings, or a provider of the person's own.
model_settings() {
  heading "Model settings"
  config_file="$CONFIG_DIR/config.yaml"
  opencode_file="${TROUPE_OPENCODE_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/opencode/opencode.jsonc}"
  if [ -f "$config_file" ]; then
    say "  $config_file"
    if [ "$with_tui" = 1 ]; then say "  troupe config shows what Troupe will use."; fi
    return 0
  fi
  say "  No $config_file yet, so no model is set up."
  if [ -f "$opencode_file" ]; then
    say "  opencode is set up here ($opencode_file), and Troupe uses its providers"
    say "  while it has none of its own."
    if [ "$tty" = 0 ]; then
      say "  troupe-daemon config import-opencode copies them into $config_file."
      return 0
    fi
    if ! ask "  Copy them into $config_file, keys as opencode has them written?" y; then
      say "  Left as it is: Troupe keeps reading opencode's config."
      return 0
    fi
    # A daemon from before the command answers "unknown arguments"; say so, not its usage.
    if copied=$("$BIN" config import-opencode 2>&1); then
      printf '%s\n' "$copied" | sed 's/^/  /'
      return 0
    fi
    say "  could not copy them: $(printf '%s\n' "$copied" | head -n 1)"
  fi
  if [ "$with_tui" = 1 ] && [ "$tty" = 1 ]; then
    if ask "  Set it up now, with troupe config?" y; then
      "$TUI" config </dev/tty || true
      return 0
    fi
  fi
  say "  When you are ready, either:"
  say "    * take your organisation's settings: troupe login <plane-url>, then troupe config pull"
  say "    * write $config_file with a provider (provider, base_url, api_key, models)"
  say "    * or set it in the desktop app's Models settings"
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

  was=$(installed_summary)
  heading "Troupe installer"
  say "  release    $VERSION ($version_from)"
  say "  platform   $target"
  say "  installed  ${was:-nothing yet}"

  if [ "$with_tui" = 0 ] && [ "$with_gui" = 0 ]; then
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
    elif [ "$yes" = 0 ]; then
      die "neither --tui nor --gui given, and no terminal to ask on; pass -y to install the daemon alone"
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

  heading "Done: Troupe $VERSION"
  if ! on_path; then
    if [ "$path_added" != 0 ]; then
      item "open a new terminal for the PATH change, or in this one: export PATH=\"$BIN_DIR:\$PATH\""
    else
      item "$BIN_DIR is not on your PATH; add it, or run the programs by their full path"
    fi
  fi
  if [ "$with_tui" = 1 ]; then
    item "troupe            the TUI, in a project directory"
    item "troupe config     the model settings it will use"
  fi
  if [ "$with_gui" = 1 ]; then
    if [ "$OS" = Darwin ]; then item "Troupe            the desktop app, in ~/Applications"; else item "Troupe            the desktop app, in your applications menu"; fi
  fi
  item "the desktop app starts the daemon when it needs one; so does troupe"
  item "sh install.sh --uninstall removes it again (--purge: config and state too)"
}

purge=0; mode=install; with_tui=0; with_gui=0; yes=0; clean=0; no_modify_path=0
for arg in "$@"; do
  case "$arg" in
    --tui) with_tui=1 ;;
    --gui) with_gui=1 ;;
    -y | --yes) yes=1 ;;
    --no-tui) yes=1 ;; # the daemon alone, as before --tui and --gui
    --clean-install) clean=1 ;;
    --uninstall) mode=uninstall ;;
    --purge) purge=1 ;;
    --no-modify-path) no_modify_path=1 ;;
    --help | -h)
      say "usage: install.sh [--tui] [--gui] [-y] [--clean-install [--purge]] [--no-modify-path]"
      say "       install.sh --uninstall [--purge] [-y]"
      exit 0
      ;;
    *) die "unknown argument $arg (--help lists them)" ;;
  esac
done

tty=0
if [ "$yes" = 0 ] && (: </dev/tty) 2>/dev/null; then tty=1; fi

if [ "$mode" = uninstall ]; then uninstall; else install; fi
