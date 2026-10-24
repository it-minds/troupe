#!/bin/sh
# Notarise signed macOS programs with Apple's notary service, and wait for its answer.
#
#   sh scripts/signing/notarize-macos.sh PATH...
#
# Each PATH, a file or a directory, goes into one zip, which `notarytool submit --wait`
# sends. Apple records every signed Mach-O in it, and Gatekeeper then finds the ticket
# online: a standalone binary such as `troupe` or a release tree such as troupe-daemon's
# cannot have one stapled to it (the desktop app's is stapled by Tauri).
#
# Reads the release environment's App Store Connect team key: APPLE_API_ISSUER, APPLE_API_KEY
# (the key's ID) and APPLE_API_PRIVATE_KEY (the text of the .p8), which goes into a file
# only this job can read and is removed afterwards. On any answer but Accepted it prints
# Apple's log of the submission and fails, and the release stays a draft.
set -eu

: "${APPLE_API_ISSUER:?not set}" "${APPLE_API_KEY:?not set}" "${APPLE_API_PRIVATE_KEY:?not set}"
if [ $# -eq 0 ]; then
  echo "usage: notarize-macos.sh PATH..." >&2
  exit 2
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
umask 077
key="$work/AuthKey_${APPLE_API_KEY}.p8"
printf '%s\n' "$APPLE_API_PRIVATE_KEY" >"$key"

mkdir "$work/stage"
for path in "$@"; do
  ditto "$path" "$work/stage/$(basename "$path")"
done
ditto -c -k --keepParent "$work/stage" "$work/notarise.zip"

auth() { "$@" --key "$key" --key-id "$APPLE_API_KEY" --issuer "$APPLE_API_ISSUER"; }

answer=$(auth xcrun notarytool submit "$work/notarise.zip" --wait --timeout 30m --output-format json) || true
status=$(printf '%s' "$answer" | sed -n 's/.*"status" *: *"\([^"]*\)".*/\1/p')
id=$(printf '%s' "$answer" | sed -n 's/.*"id" *: *"\([^"]*\)".*/\1/p')
echo "notarisation of $*: ${status:-no answer} (submission ${id:-none})"

if [ "$status" != Accepted ]; then
  echo "$answer" >&2
  if [ -n "$id" ]; then auth xcrun notarytool log "$id" >&2 || true; fi
  echo "error: the notary service did not accept $*; docs/developer/code-signing.md says what to do" >&2
  exit 1
fi
if [ -n "${GITHUB_STEP_SUMMARY-}" ] && [ -n "${TROUPE_SIGN_LABEL-}" ]; then
  echo "- ${TROUPE_SIGN_LABEL}: notarised (submission $id)" >>"$GITHUB_STEP_SUMMARY"
fi
