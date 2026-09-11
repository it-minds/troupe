#!/bin/sh
# Install, upgrade or uninstall troupe on Linux and macOS.
#
# POSIX sh, so it runs under dash as well as bash and zsh.
#
#   curl -fsSL <base>/install.sh | sh
#   curl -fsSL <base>/install.sh | sh -s -- --uninstall
#
# The download base is configurable with TROUPE_RELEASE_URL so artifacts can live on
# a Forgejo release, an S3-compatible bucket, or anywhere else — nothing here is
# hardwired to one host.
#
# Nothing unverified is ever executed: the checksum is compared before the binary is
# moved into place, and a mismatch aborts with the download discarded.
set -eu

RELEASE_URL="${TROUPE_RELEASE_URL:-https://github.com/objective-mj/troupe/releases/latest/download}"
INSTALL_DIR="${TROUPE_INSTALL_DIR:-$HOME/.local/bin}"
BINARY_NAME="troupe"
PURGE=0
ACTION="install"

log() { printf '%s\n' "$*" >&2; }
die() { printf 'troupe: %s\n' "$*" >&2; exit 1; }

usage() {
  cat >&2 <<'USAGE'
troupe installer

  install.sh                 install or upgrade
  install.sh --uninstall     remove the binary, the PATH entry and the payload cache
  install.sh --uninstall --purge
                             also remove configuration and session history
  install.sh --version X     install a specific version

Environment:
  TROUPE_RELEASE_URL   where to download from
  TROUPE_INSTALL_DIR   where to install (default ~/.local/bin)
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --uninstall) ACTION="uninstall" ;;
    --purge) PURGE=1 ;;
    --version) shift; [ $# -gt 0 ] || die "--version needs a value"; TROUPE_VERSION="$1" ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "unknown argument $1" ;;
  esac
  shift
done

detect_target() {
  os=$(uname -s)
  arch=$(uname -m)

  case "$arch" in
    x86_64|amd64) arch="x86_64" ;;
    aarch64|arm64) arch="aarch64" ;;
    *) die "unsupported architecture $arch" ;;
  esac

  case "$os" in
    Linux) echo "linux_${arch}" ;;
    Darwin) echo "macos_${arch}" ;;
    *) die "unsupported operating system $os" ;;
  esac
}

# curl and Invoke-WebRequest both avoid the macOS quarantine attribute that a
# browser download would attach, which is why they are the only fetchers used here.
fetch() {
  url="$1"
  out="$2"

  case "$url" in
    file://*)
      # A local release directory, which is how the installer is tested offline.
      cp "${url#file://}" "$out" 2>/dev/null || return 1
      ;;
    *)
      if command -v curl >/dev/null 2>&1; then
        curl -fsSL --proto '=https' --tlsv1.2 -o "$out" "$url" || return 1
      elif command -v wget >/dev/null 2>&1; then
        wget -qO "$out" "$url" || return 1
      else
        die "neither curl nor wget is available; install one and try again"
      fi
      ;;
  esac
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | cut -d' ' -f1
  else
    die "no sha256 tool available (need sha256sum or shasum)"
  fi
}

state_dir() {
  case "$(uname -s)" in
    Darwin) echo "${XDG_STATE_HOME:-$HOME/.local/state}/troupe" ;;
    *) echo "${XDG_STATE_HOME:-$HOME/.local/state}/troupe" ;;
  esac
}

config_dir() {
  echo "${XDG_CONFIG_HOME:-$HOME/.config}/troupe"
}

# Where Burrito extracts the payload on first run. Removing it on uninstall is the
# difference between "the binary is gone" and "troupe is gone".
payload_cache() {
  case "$(uname -s)" in
    Darwin) echo "$HOME/Library/Application Support/.burrito" ;;
    *) echo "${XDG_DATA_HOME:-$HOME/.local/share}/.burrito" ;;
  esac
}

shell_profile() {
  # Update the profile of the shell the user actually runs, and only that one.
  case "${SHELL:-}" in
    */zsh) echo "${ZDOTDIR:-$HOME}/.zshrc" ;;
    */bash) [ -f "$HOME/.bashrc" ] && echo "$HOME/.bashrc" || echo "$HOME/.profile" ;;
    *) echo "$HOME/.profile" ;;
  esac
}

ensure_on_path() {
  dir="$1"
  profile=$(shell_profile)

  case ":${PATH}:" in
    *":${dir}:"*) return 0 ;;
  esac

  # Idempotent: the marker is what makes a re-run a no-op rather than a duplicate.
  if [ -f "$profile" ] && grep -q '# added by the troupe installer' "$profile" 2>/dev/null; then
    log "PATH entry already present in $profile"
    return 0
  fi

  mkdir -p "$(dirname "$profile")"
  {
    printf '\n# added by the troupe installer\n'
    printf 'export PATH="%s:$PATH"\n' "$dir"
  } >> "$profile"

  log "Added $dir to PATH in $profile — open a new shell, or run: export PATH=\"$dir:\$PATH\""
}

remove_from_path() {
  profile=$(shell_profile)
  [ -f "$profile" ] || return 0
  grep -q '# added by the troupe installer' "$profile" 2>/dev/null || return 0

  tmp=$(mktemp)
  # Drop the marker comment and the export line that follows it.
  awk '
    /^# added by the troupe installer$/ { skip = 2; next }
    skip > 0 { skip--; next }
    { print }
  ' "$profile" > "$tmp"

  mv "$tmp" "$profile"
  log "Removed the PATH entry from $profile"
}

do_install() {
  target=$(detect_target)
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT

  if [ -n "${TROUPE_VERSION:-}" ]; then
    artifact="troupe-${TROUPE_VERSION}-${target}"
  else
    # Without an explicit version, the checksums file names the artifact for us,
    # which keeps the installer working against a "latest" URL.
    fetch "${RELEASE_URL}/SHA256SUMS" "$tmp/SHA256SUMS" || die "could not download SHA256SUMS from $RELEASE_URL"
    artifact=$(awk -v t="$target" '$2 ~ t {print $2}' "$tmp/SHA256SUMS" | head -n1)
    [ -n "$artifact" ] || die "no artifact for $target in SHA256SUMS"
  fi

  log "Downloading $artifact"
  fetch "${RELEASE_URL}/${artifact}" "$tmp/$artifact" || die "could not download $artifact"

  [ -f "$tmp/SHA256SUMS" ] || fetch "${RELEASE_URL}/SHA256SUMS" "$tmp/SHA256SUMS" \
    || die "could not download SHA256SUMS"

  expected=$(awk -v a="$artifact" '$2 == a || $2 == "*"a {print $1}' "$tmp/SHA256SUMS" | head -n1)
  [ -n "$expected" ] || die "SHA256SUMS has no entry for $artifact"

  actual=$(sha256_of "$tmp/$artifact")
  if [ "$expected" != "$actual" ]; then
    rm -f "$tmp/$artifact"
    die "checksum mismatch for $artifact (expected $expected, got $actual) — nothing was installed"
  fi

  log "Checksum verified"

  mkdir -p "$INSTALL_DIR"
  destination="${INSTALL_DIR}/${BINARY_NAME}"

  # Keep the previous binary so a bad upgrade can be rolled back by hand.
  if [ -f "$destination" ]; then
    mv "$destination" "${destination}.previous"
    log "Kept the previous binary at ${destination}.previous"
  fi

  chmod +x "$tmp/$artifact"
  mv "$tmp/$artifact" "$destination"

  ensure_on_path "$INSTALL_DIR"

  log "Installed $("$destination" --version 2>/dev/null || echo troupe) to $destination"
}

do_uninstall() {
  destination="${INSTALL_DIR}/${BINARY_NAME}"

  [ -f "$destination" ] && rm -f "$destination" && log "Removed $destination"
  [ -f "${destination}.previous" ] && rm -f "${destination}.previous" && log "Removed the rollback copy"

  cache=$(payload_cache)
  if [ -d "$cache" ]; then
    # Only troupe's own extracted payloads; other Burrito apps share this directory.
    find "$cache" -maxdepth 1 -name 'troupe_erts-*' -exec rm -rf {} + 2>/dev/null || true
    rmdir "$cache" 2>/dev/null || true
    log "Removed the extracted payload cache"
  fi

  remove_from_path

  if [ "$PURGE" -eq 1 ]; then
    rm -rf "$(config_dir)" "$(state_dir)"
    log "Removed configuration and session history"
  else
    log "Kept configuration in $(config_dir) and session history in $(state_dir)"
    log "Pass --purge to remove those too."
  fi
}

case "$ACTION" in
  install) do_install ;;
  uninstall) do_uninstall ;;
esac
