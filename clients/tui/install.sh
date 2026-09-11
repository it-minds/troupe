#!/bin/sh
# Troupe installer for Linux and macOS (POSIX sh).
#   curl -fsSL https://<host>/install.sh | sh
#   TROUPE_RELEASE_URL=https://forge.example.com/org/troupe/releases/download/v0.1.0 sh install.sh
#   sh install.sh --uninstall [--purge]
set -eu

VERSION="${TROUPE_VERSION:-0.1.0}"
BASE_URL="${TROUPE_RELEASE_URL:-https://github.com/it-minds/troupe/releases/download/v${VERSION}}"
INSTALL_DIR="${TROUPE_INSTALL_DIR:-$HOME/.local/bin}"
BIN="$INSTALL_DIR/troupe"
STATE_DIR="${TROUPE_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/troupe}"
CONFIG_DIR="${TROUPE_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/troupe}"

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

remove_payload_cache() {
  # Burrito extracts payloads to <data dir>/.burrito/<app>_erts-<vsn>_<app vsn>; other apps share .burrito.
  for base in "$HOME/.local/share/.burrito" "${XDG_DATA_HOME:-}/.burrito" "$HOME/Library/Application Support/.burrito"; do
    [ -n "$base" ] && [ -d "$base" ] || continue
    for d in "$base"/troupe_*; do
      [ -d "$d" ] || continue
      say "removing payload cache $d"
      rm -rf "$d"
    done
  done
  return 0
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
  say "removing $BIN"
  rm -f "$BIN" "$BIN.previous"
  remove_path_line
  remove_payload_cache
  if [ "$purge" = 1 ]; then
    say "purging config $CONFIG_DIR and state $STATE_DIR"
    rm -rf "$CONFIG_DIR" "$STATE_DIR"
  else
    say "kept config ($CONFIG_DIR) and state ($STATE_DIR); pass --purge to remove them"
  fi
  say "troupe uninstalled"
}

add_to_path() {
  case ":$PATH:" in *":$INSTALL_DIR:"*) return 0 ;; esac
  line="export PATH=\"$INSTALL_DIR:\$PATH\" # added by troupe installer"
  for rc in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.profile"; do
    if [ -f "$rc" ]; then
      grep -q '# added by troupe installer' "$rc" 2>/dev/null || printf '\n%s\n' "$line" >> "$rc"
      say "added $INSTALL_DIR to PATH in $rc (restart your shell)"
      return 0
    fi
  done
  printf '\n%s\n' "$line" >> "$HOME/.profile"
  say "added $INSTALL_DIR to PATH in ~/.profile (restart your shell)"
}

install() {
  target=$(detect_target)
  artifact="troupe-${VERSION}-${target}"
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
  mkdir -p "$INSTALL_DIR"
  if [ -f "$BIN" ]; then
    say "keeping previous binary as $BIN.previous (rollback: mv $BIN.previous $BIN)"
    mv -f "$BIN" "$BIN.previous"
  fi
  install_tmp="$INSTALL_DIR/.troupe.tmp.$$"
  cp "$tmp/$artifact" "$install_tmp"
  chmod 755 "$install_tmp"
  mv -f "$install_tmp" "$BIN"
  add_to_path
  say "installed troupe $VERSION to $BIN"
  if [ "$(uname -s)" = Darwin ]; then
    say "note: this binary is unsigned. If Gatekeeper blocks it, run: xattr -d com.apple.quarantine $BIN (curl downloads normally carry no quarantine attribute)"
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
