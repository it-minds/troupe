#!/bin/sh
# Troupe installer for Linux and macOS (POSIX sh): the TUI and the daemon it stands on.
#   curl -fsSL https://raw.githubusercontent.com/it-minds/troupe/main/install.sh | sh
#   TROUPE_VERSION=0.3.0 sh install.sh              # a particular release
#   sh install.sh --no-tui                          # the daemon alone, for the desktop app
#   sh install.sh --uninstall [--purge]
#
# Installs, from one release of this repository:
#   * `troupe`, the terminal client — one binary, in ~/.local/bin;
#   * `troupe-daemon`, the local harness every client stands on — a release directory
#     under ~/.local/lib/troupe-daemon and a link in ~/.local/bin. The TUI and the desktop
#     app find it on the PATH (or through TROUPE_DAEMON_COMMAND) and start it when a
#     session needs one.
# Both are checked against the release's SHA256SUMS before anything is replaced.
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
  if [ -e "$BIN" ] || [ -d "$LIB_DIR" ] || [ -e "$TUI" ]; then
    say "removing $TUI, $BIN and $LIB_DIR"
  fi
  rm -f "$BIN" "$TUI" "$TUI.previous"
  rm -rf "$LIB_DIR" "$LIB_DIR.previous"
  remove_path_line
  if [ "$purge" = 1 ]; then
    say "purging config $CONFIG_DIR and state $STATE_DIR"
    rm -rf "$CONFIG_DIR" "$STATE_DIR"
  else
    say "kept config ($CONFIG_DIR) and state ($STATE_DIR); pass --purge to remove them"
  fi
  say "troupe and troupe-daemon uninstalled"
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

install() {
  with_tui=$1
  if [ -z "$VERSION" ]; then
    VERSION=$(latest_version) || die "could not find the latest release of $REPO (a private repository needs TROUPE_VERSION, and TROUPE_RELEASE_URL if releases are mirrored)"
  fi
  BASE_URL="${TROUPE_RELEASE_URL:-https://github.com/$REPO/releases/download/v${VERSION}}"
  target=$(detect_target)
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  curl -fsSL --retry 3 -o "$tmp/SHA256SUMS" "$BASE_URL/SHA256SUMS" || die "checksum download failed"

  # Everything is downloaded and checked before anything is replaced.
  artifact="troupe-daemon-${VERSION}-${target}.tar.gz"
  fetch "$artifact"
  daemon_artifact=$artifact
  if [ "$with_tui" = 1 ]; then
    fetch "troupe-${VERSION}-${target}"
    tui_artifact=$artifact
  fi
  artifact=$daemon_artifact

  # Unpack beside the current install, then swap: a half-extracted tree is never what
  # `troupe-daemon` on the PATH points at, and the previous release stays for rollback.
  staging="$LIB_DIR.new"
  rm -rf "$staging"; mkdir -p "$staging"
  tar -xzf "$tmp/$artifact" -C "$staging" || die "could not unpack $artifact"
  [ -x "$staging/bin/troupe-daemon" ] || die "$artifact does not contain bin/troupe-daemon"
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

  add_to_path
  "$BIN" version || true
  if [ "$with_tui" = 1 ]; then "$TUI" --version || true; fi
  if [ "$(uname -s)" = Darwin ]; then
    say "note: the release is unsigned. If Gatekeeper blocks it, run: xattr -dr com.apple.quarantine $LIB_DIR $TUI (curl downloads normally carry no quarantine attribute)"
  fi
}

purge=0; mode=install; with_tui=1
for arg in "$@"; do
  case "$arg" in
    --uninstall) mode=uninstall ;;
    --purge) purge=1 ;;
    --no-tui) with_tui=0 ;;
    --help|-h) say "usage: install.sh [--no-tui] | --uninstall [--purge]"; exit 0 ;;
    *) die "unknown argument $arg" ;;
  esac
done

if [ "$mode" = uninstall ]; then uninstall "$purge"; else install "$with_tui"; fi
