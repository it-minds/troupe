#!/bin/sh
# troupe-daemon installer for Linux and macOS (POSIX sh).
#   curl -fsSL https://raw.githubusercontent.com/it-minds/troupe/main/install.sh | sh
#   TROUPE_RELEASE_URL=https://github.com/it-minds/troupe/releases/download/v0.1.0 sh install.sh
#   sh install.sh --uninstall [--purge]
#
# Installs the local daemon the Troupe clients stand on: a release directory under
# ~/.local/lib/troupe-daemon and a `troupe-daemon` link in ~/.local/bin. The TUI and the
# desktop app find it on the PATH (or through TROUPE_DAEMON_COMMAND) and start it when a
# session needs one.
set -eu

VERSION="${TROUPE_VERSION:-0.1.0}"
BASE_URL="${TROUPE_RELEASE_URL:-https://github.com/it-minds/troupe/releases/download/v${VERSION}}"
BIN_DIR="${TROUPE_INSTALL_DIR:-$HOME/.local/bin}"
LIB_DIR="${TROUPE_LIB_DIR:-$HOME/.local/lib/troupe-daemon}"
BIN="$BIN_DIR/troupe-daemon"
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
  if [ -e "$BIN" ] || [ -d "$LIB_DIR" ]; then
    say "removing $BIN and $LIB_DIR"
  fi
  rm -f "$BIN"
  rm -rf "$LIB_DIR"
  remove_path_line
  if [ "$purge" = 1 ]; then
    say "purging config $CONFIG_DIR and state $STATE_DIR"
    rm -rf "$CONFIG_DIR" "$STATE_DIR"
  else
    say "kept config ($CONFIG_DIR) and state ($STATE_DIR); pass --purge to remove them"
  fi
  say "troupe-daemon uninstalled"
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

install() {
  target=$(detect_target)
  artifact="troupe-daemon-${VERSION}-${target}.tar.gz"
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  say "downloading $BASE_URL/$artifact"
  curl -fsSL --retry 3 -o "$tmp/$artifact" "$BASE_URL/$artifact" || die "download failed"
  curl -fsSL --retry 3 -o "$tmp/SHA256SUMS" "$BASE_URL/SHA256SUMS" || die "checksum download failed"
  expected=$(grep " $artifact\$" "$tmp/SHA256SUMS" | awk '{print $1}')
  [ -n "$expected" ] || die "no checksum for $artifact in SHA256SUMS"
  if command -v sha256sum >/dev/null 2>&1; then actual=$(sha256sum "$tmp/$artifact" | awk '{print $1}')
  else actual=$(shasum -a 256 "$tmp/$artifact" | awk '{print $1}'); fi
  [ "$expected" = "$actual" ] || die "checksum mismatch for $artifact (expected $expected, got $actual); nothing installed"

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
  add_to_path
  say "installed troupe-daemon $VERSION to $LIB_DIR ($BIN)"
  "$BIN" version || true
  if [ "$(uname -s)" = Darwin ]; then
    say "note: the release is unsigned. If Gatekeeper blocks it, run: xattr -dr com.apple.quarantine $LIB_DIR (curl downloads normally carry no quarantine attribute)"
  fi
}

purge=0; mode=install
for arg in "$@"; do
  case "$arg" in
    --uninstall) mode=uninstall ;;
    --purge) purge=1 ;;
    --help|-h) say "usage: install.sh [--uninstall [--purge]]"; exit 0 ;;
    *) die "unknown argument $arg" ;;
  esac
done

if [ "$mode" = uninstall ]; then uninstall "$purge"; else install; fi
