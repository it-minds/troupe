#!/bin/sh
# Troupe installer for Linux and macOS (POSIX sh): the daemon, and the clients asked for.
#   curl -fsSL https://raw.githubusercontent.com/it-minds/troupe/main/install.sh | sh -s -- --tui --gui
#   sh install.sh --tui --gui                       # daemon, TUI and desktop app
#   sh install.sh --tui                             # daemon and TUI
#   sh install.sh --gui                             # daemon and desktop app
#   sh install.sh                                   # the daemon alone; asks first (-y skips that)
#   TROUPE_VERSION=0.3.0 sh install.sh --tui        # a particular release
#   sh install.sh --uninstall [--purge]
#
# The release counterpart of scripts/install-local, with the same flags. Installs, from one
# release of this repository:
#   * `troupe-daemon`, the local harness, always -- a release directory under
#     ~/.local/lib/troupe-daemon and a link in ~/.local/bin. The desktop app finds it there
#     (or on the PATH, or through TROUPE_DAEMON_COMMAND) and starts it when a session needs
#     one. A daemon running from that directory is stopped first, so the next session gets
#     the new one.
#   * with --tui, `troupe`, the terminal client -- one binary, in ~/.local/bin. It uses a
#     running daemon if there is one and otherwise runs the same harness in its own process.
#   * with --gui, the desktop app: on Linux the release's AppImage, as
#     ~/.local/bin/troupe-desktop with a menu entry; on macOS Troupe.app in ~/Applications.
# Everything is checked against the release's SHA256SUMS before anything is replaced.
#
# With no TROUPE_VERSION it installs the latest release, which GitHub names at
# /releases/latest. A private repository answers that only to somebody signed in: set
# TROUPE_VERSION, and TROUPE_RELEASE_URL to wherever your organisation mirrors releases.
set -eu

REPO="${TROUPE_REPO:-it-minds/troupe}"
VERSION="${TROUPE_VERSION:-}"
BIN_DIR="${TROUPE_INSTALL_DIR:-$HOME/.local/bin}"
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

say() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

detect_target() {
  os=$(uname -s); arch=$(uname -m)
  case "$os" in
    Linux) os=linux ;;
    Darwin) os=macos ;;
    *) die "unsupported OS: $os" ;;
  esac
  case "$arch" in
    x86_64|amd64) arch=x86_64 ;;
    aarch64|arm64) arch=aarch64 ;;
    *) die "unsupported architecture: $arch" ;;
  esac
  printf '%s_%s' "$os" "$arch"
}

# A daemon serving from the directory about to be replaced. Only that one: another BEAM
# on this machine is somebody else's work.
stop_running_daemon() {
  pids=$(pgrep -f "$LIB_DIR/" 2>/dev/null || true)
  [ -n "$pids" ] || return 0
  for pid in $pids; do
    [ "$pid" = "$$" ] && continue
    say "stopping the running daemon (pid $pid)"
    kill "$pid" 2>/dev/null || true
  done
  sleep 1
}

remove_path_line() {
  for rc in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.profile"; do
    [ -f "$rc" ] || continue
    if grep -q '# added by troupe installer' "$rc" 2>/dev/null; then
      tmp=$(mktemp); grep -v '# added by troupe installer' "$rc" > "$tmp" || true; cat "$tmp" > "$rc"; rm -f "$tmp"
    fi
  done
}

uninstall() {
  purge=$1
  stop_running_daemon
  say "removing $TUI, $BIN, $LIB_DIR and the desktop app, where installed"
  rm -f "$BIN" "$TUI" "$TUI.previous" "$GUI" "$GUI.previous" "$DESKTOP_FILE" "$ICON"
  rm -rf "$LIB_DIR" "$LIB_DIR.previous"
  [ "$(uname -s)" = Darwin ] && rm -rf "$MAC_APP"
  # Where the TUI's Burrito wrapper unpacked itself on first run.
  for base in "$DATA_DIR/.burrito" "$HOME/Library/Application Support/.burrito"; do
    [ -d "$base" ] || continue
    for dir in "$base"/troupe_*; do
      if [ -d "$dir" ]; then rm -rf "$dir"; fi
    done
  done
  remove_path_line
  if [ "$purge" = 1 ]; then
    say "purging config $CONFIG_DIR and state $STATE_DIR"
    rm -rf "$CONFIG_DIR" "$STATE_DIR"
  else
    say "kept config ($CONFIG_DIR) and state ($STATE_DIR); pass --purge to remove them"
  fi
  say "troupe uninstalled"
}

add_to_path() {
  case ":$PATH:" in *":$BIN_DIR:"*) return 0 ;; esac
  line="export PATH=\"$BIN_DIR:\$PATH\" # added by troupe installer"
  for rc in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.profile"; do
    if [ -f "$rc" ]; then
      grep -q '# added by troupe installer' "$rc" 2>/dev/null || printf '\n%s\n' "$line" >> "$rc"
      say "added $BIN_DIR to PATH in $rc (restart your shell)"
      return 0
    fi
  done
  printf '\n%s\n' "$line" >> "$HOME/.profile"
  say "added $BIN_DIR to PATH in ~/.profile (restart your shell)"
}

# The newest release that is not a release candidate: GitHub redirects /releases/latest to
# its tag.
latest_version() {
  url=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest") || return 1
  case "$url" in */tag/v*) printf '%s' "${url##*/tag/v}" ;; *) return 1 ;; esac
}

# Download one artifact of the release into $tmp and check it against SHA256SUMS.
fetch() {
  artifact=$1
  say "downloading $BASE_URL/$artifact"
  curl -fsSL --retry 3 -o "$tmp/$artifact" "$BASE_URL/$artifact" || die "download of $artifact failed"
  expected=$(grep " $artifact\$" "$tmp/SHA256SUMS" | awk '{print $1}')
  [ -n "$expected" ] || die "no checksum for $artifact in SHA256SUMS"
  if command -v sha256sum >/dev/null 2>&1; then actual=$(sha256sum "$tmp/$artifact" | awk '{print $1}')
  else actual=$(shasum -a 256 "$tmp/$artifact" | awk '{print $1}'); fi
  [ "$expected" = "$actual" ] || die "checksum mismatch for $artifact (expected $expected, got $actual); nothing installed"
}

install_gui_linux() {
  [ -e "$GUI" ] && mv -f "$GUI" "$GUI.previous"
  mv -f "$tmp/$gui_artifact" "$GUI"
  chmod +x "$GUI"
  mkdir -p "$(dirname "$DESKTOP_FILE")" "$(dirname "$ICON")"
  # The AppImage carries its own icon; unpacking it needs no FUSE. Without one the menu
  # entry falls back to the theme's generic icon.
  if (cd "$tmp" && "$GUI" --appimage-extract 'usr/share/icons/hicolor/128x128/*' >/dev/null 2>&1); then
    icon_src=$(find "$tmp/squashfs-root" -type f -name '*.png' 2>/dev/null | head -n 1)
    if [ -n "$icon_src" ]; then cp "$icon_src" "$ICON"; fi
  fi
  cat > "$DESKTOP_FILE" <<EOF
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
  command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$(dirname "$DESKTOP_FILE")" 2>/dev/null || true
  say "installed troupe-desktop $VERSION to $GUI (menu entry: Troupe)"
  if command -v ldconfig >/dev/null 2>&1 && ! ldconfig -p 2>/dev/null | grep -q 'libfuse\.so\.2'; then
    say "note: an AppImage needs FUSE 2 to start (Ubuntu: sudo apt install libfuse2t64; older: libfuse2)"
  fi
}

install_gui_macos() {
  mnt="$tmp/dmg"
  mkdir -p "$mnt"
  hdiutil attach -nobrowse -readonly -quiet -mountpoint "$mnt" "$tmp/$gui_artifact" || die "could not open $gui_artifact"
  app=$(find "$mnt" -maxdepth 1 -name '*.app' | head -n 1)
  if [ -z "$app" ]; then hdiutil detach -quiet "$mnt" || true; die "$gui_artifact contains no .app"; fi
  mkdir -p "$(dirname "$MAC_APP")"
  rm -rf "$MAC_APP.new"
  cp -R "$app" "$MAC_APP.new"
  hdiutil detach -quiet "$mnt" || true
  rm -rf "$MAC_APP"
  mv "$MAC_APP.new" "$MAC_APP"
  say "installed Troupe $VERSION to $MAC_APP"
}

install() {
  with_tui=$1; with_gui=$2
  if [ -z "$VERSION" ]; then
    VERSION=$(latest_version) || die "could not find the latest release of $REPO (a private repository needs TROUPE_VERSION, and TROUPE_RELEASE_URL if releases are mirrored)"
  fi
  BASE_URL="${TROUPE_RELEASE_URL:-https://github.com/$REPO/releases/download/v${VERSION}}"
  target=$(detect_target)

  # The desktop app's version drops the pre-release part (WiX refuses one; see
  # scripts/version.exs), so its artifacts are named after 0.3.3 in release 0.3.3-rc.1.
  gui_artifact=
  if [ "$with_gui" = 1 ]; then
    case "$target" in
      linux_x86_64) gui_artifact="Troupe_${VERSION%%-*}_amd64.AppImage" ;;
      macos_*) gui_artifact="Troupe_${VERSION%%-*}_universal.dmg" ;;
      *) die "no desktop app is released for $target; leave out --gui" ;;
    esac
  fi

  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  curl -fsSL --retry 3 -o "$tmp/SHA256SUMS" "$BASE_URL/SHA256SUMS" || die "checksum download failed"

  # Everything is downloaded and checked before anything is replaced.
  daemon_artifact="troupe-daemon-${VERSION}-${target}.tar.gz"
  fetch "$daemon_artifact"
  tui_artifact="troupe-${VERSION}-${target}"
  [ "$with_tui" = 1 ] && fetch "$tui_artifact"
  [ -n "$gui_artifact" ] && fetch "$gui_artifact"

  stop_running_daemon

  # Unpack beside the current install, then swap: a half-extracted tree is never what
  # `troupe-daemon` on the PATH points at, and the previous release stays for rollback.
  staging="$LIB_DIR.new"
  rm -rf "$staging"; mkdir -p "$staging"
  tar -xzf "$tmp/$daemon_artifact" -C "$staging" || die "could not unpack $daemon_artifact"
  [ -x "$staging/bin/troupe-daemon" ] || die "$daemon_artifact does not contain bin/troupe-daemon"
  if [ -d "$LIB_DIR" ]; then
    rm -rf "$LIB_DIR.previous"
    mv "$LIB_DIR" "$LIB_DIR.previous"
    say "keeping the previous release as $LIB_DIR.previous (rollback: rm -rf $LIB_DIR && mv $LIB_DIR.previous $LIB_DIR)"
  fi
  mv "$staging" "$LIB_DIR"

  mkdir -p "$BIN_DIR"
  ln -sf "$LIB_DIR/bin/troupe-daemon" "$BIN"
  say "installed troupe-daemon $VERSION to $LIB_DIR ($BIN)"

  # One binary; the one it replaces is kept beside it for rollback.
  if [ "$with_tui" = 1 ]; then
    chmod +x "$tmp/$tui_artifact"
    [ -e "$TUI" ] && mv -f "$TUI" "$TUI.previous"
    mv -f "$tmp/$tui_artifact" "$TUI"
    say "installed troupe $VERSION to $TUI"
  fi

  if [ -n "$gui_artifact" ]; then
    case "$target" in
      linux_*) install_gui_linux ;;
      macos_*) install_gui_macos ;;
    esac
  fi

  add_to_path
  "$BIN" version || true
  if [ "$with_tui" = 1 ]; then "$TUI" --version || true; fi
  if [ "$(uname -s)" = Darwin ]; then
    say "note: the release is unsigned. If Gatekeeper blocks it, run: xattr -dr com.apple.quarantine $LIB_DIR $TUI $MAC_APP (curl downloads normally carry no quarantine attribute)"
  fi
  say "done. The desktop app starts the daemon when it needs one; troupe in a workspace starts the TUI."
}

purge=0; mode=install; with_tui=0; with_gui=0; yes=0
for arg in "$@"; do
  case "$arg" in
    --tui) with_tui=1 ;;
    --gui) with_gui=1 ;;
    -y|--yes) yes=1 ;;
    --no-tui) yes=1 ;;  # the daemon alone, as before --tui and --gui
    --uninstall) mode=uninstall ;;
    --purge) purge=1 ;;
    --help|-h) say "usage: install.sh [--tui] [--gui] [-y] | --uninstall [--purge]"; exit 0 ;;
    *) die "unknown argument $arg" ;;
  esac
done

if [ "$mode" = uninstall ]; then uninstall "$purge"; exit 0; fi

# The daemon is always installed, the clients only when named. Naming neither is more often
# a forgotten flag than a wish, so it is confirmed -- from the terminal, which `curl | sh`
# still has even though its stdin is the script.
if [ "$with_tui" = 0 ] && [ "$with_gui" = 0 ] && [ "$yes" = 0 ]; then
  say "warning: neither --tui nor --gui given; this installs the daemon only."
  say "         (curl ... | sh -s -- --tui --gui installs the clients too)"
  if (: < /dev/tty) 2>/dev/null; then
    printf 'continue? (y/n) '
    read -r answer < /dev/tty || answer=
    case "$answer" in y|Y|yes|YES) ;; *) say "nothing installed"; exit 1 ;; esac
  else
    die "no terminal to ask on; pass -y to install the daemon only"
  fi
fi

install "$with_tui" "$with_gui"
