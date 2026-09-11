#!/bin/sh
# Exercise install.sh end to end in a clean container: install, re-run as an upgrade,
# reject a corrupted artifact, then uninstall and check nothing is left behind
# outside config and state.
#
# Run by CI against ubuntu:24.04 with /src mounted; the artifacts it serves live in
# /src/release.
set -eu

log() { printf '\n=== %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

log "preparing a clean environment"
apt-get update -qq >/dev/null
# curl is not strictly needed here (the release is served over file://), but a
# real install is fetched with it, so a realistic container has it.
apt-get install -y -qq zsh coreutils curl >/dev/null

useradd -m -s /bin/zsh tester
HOME_DIR=/home/tester

# Serve the release from the filesystem: the installer takes any base URL, and a
# file:// base keeps this test off the network.
export TROUPE_RELEASE_URL="file:///src/release"

run_as_tester() {
  su tester -s /bin/sh -c "TROUPE_RELEASE_URL='$TROUPE_RELEASE_URL' SHELL=/bin/zsh HOME=$HOME_DIR $*"
}

log "install"
run_as_tester "sh /src/install.sh" || fail "install failed"
[ -x "$HOME_DIR/.local/bin/troupe" ] || fail "binary not installed"
run_as_tester "$HOME_DIR/.local/bin/troupe --version" || fail "installed binary does not run"

log "PATH entry added to .zshrc (the tester's shell), exactly once"
grep -q 'added by the troupe installer' "$HOME_DIR/.zshrc" || fail "no PATH entry in .zshrc"
[ "$(grep -c 'added by the troupe installer' "$HOME_DIR/.zshrc")" = "1" ] || fail "PATH entry duplicated"

log "re-run is a clean upgrade, and does not duplicate the PATH entry"
run_as_tester "sh /src/install.sh" || fail "upgrade failed"
[ "$(grep -c 'added by the troupe installer' "$HOME_DIR/.zshrc")" = "1" ] || fail "PATH entry duplicated on upgrade"
[ -f "$HOME_DIR/.local/bin/troupe.previous" ] || fail "no rollback copy kept"
run_as_tester "$HOME_DIR/.local/bin/troupe --version" || fail "upgraded binary does not run"

log "a corrupted artifact fails the checksum and installs nothing"
rm -rf /tmp/bad && mkdir -p /tmp/bad
cp /src/release/SHA256SUMS /tmp/bad/
artifact=$(awk '{print $2}' /src/release/SHA256SUMS | head -n1)
printf 'this is not a binary' > "/tmp/bad/$artifact"
rm -f "$HOME_DIR/.local/bin/troupe"

if su tester -s /bin/sh -c "TROUPE_RELEASE_URL='file:///tmp/bad' HOME=$HOME_DIR sh /src/install.sh" 2>/tmp/bad.log; then
  fail "a corrupted artifact was accepted"
fi
grep -q 'checksum mismatch' /tmp/bad.log || fail "no checksum mismatch reported"
[ ! -f "$HOME_DIR/.local/bin/troupe" ] || fail "a corrupted artifact was installed anyway"

log "reinstall, then run once so the payload cache exists"
run_as_tester "sh /src/install.sh" || fail "reinstall failed"
run_as_tester "$HOME_DIR/.local/bin/troupe --version" >/dev/null
[ -d "$HOME_DIR/.local/share/.burrito" ] || fail "no payload cache after a run"

log "uninstall leaves nothing outside config and state"
run_as_tester "sh /src/install.sh --uninstall" || fail "uninstall failed"
[ ! -f "$HOME_DIR/.local/bin/troupe" ] || fail "binary still present"
[ ! -f "$HOME_DIR/.local/bin/troupe.previous" ] || fail "rollback copy still present"
grep -q 'added by the troupe installer' "$HOME_DIR/.zshrc" && fail "PATH entry still present"
find "$HOME_DIR/.local/share/.burrito" -maxdepth 1 -name 'troupe_erts-*' 2>/dev/null | grep -q . \
  && fail "payload cache still present"

log "purge removes config and state too"
run_as_tester "mkdir -p $HOME_DIR/.config/troupe $HOME_DIR/.local/state/troupe"
run_as_tester "sh /src/install.sh --uninstall --purge" || fail "purge failed"
[ ! -d "$HOME_DIR/.config/troupe" ] || fail "config survived a purge"
[ ! -d "$HOME_DIR/.local/state/troupe" ] || fail "state survived a purge"

printf '\nAll installer checks passed.\n'
