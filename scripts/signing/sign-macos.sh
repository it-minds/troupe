#!/bin/sh
# Sign, or check, every Mach-O file under each PATH with codesign.
#
#   sh scripts/signing/sign-macos.sh PATH...
#   sh scripts/signing/sign-macos.sh --verify PATH...
#
# A PATH is a file or a directory. In a directory each Mach-O file is found by what `file`
# says it is, not by its name, so the ERTS executables, beam.smp and every NIF are signed,
# not only the program a person starts: Gatekeeper checks each one. It is what
# `Troupe.Release.OSSigning` runs on troupe-daemon's release before it is packed and on
# troupe's Burrito payload before Burrito wraps it, and what native.yml runs on the
# finished `troupe` binary.
#
# Signing reads
#   TROUPE_SIGN_IDENTITY      what codesign signs with: the Developer ID Application
#                             identity, a certificate's SHA-1, or `-` for an ad hoc
#                             signature
#   TROUPE_SIGN_KEYCHAIN      the keychain that holds it (optional)
#   TROUPE_SIGN_ENTITLEMENTS  the entitlements for the executables (optional;
#                             scripts/signing/beam.entitlements for the BEAM)
#   TROUPE_SIGN_TIMESTAMP     `none` for no secure timestamp, which only a test wants:
#                             notarisation refuses a signature without one
# and gives every file the hardened runtime.
#
# --verify signs nothing. Every Mach-O file under each PATH must carry a valid signature
# with the hardened runtime (which a linker's ad hoc signature does not have), by
# TROUPE_SIGN_AUTHORITY when that is set (`adhoc` for an ad hoc one). It prints the count,
# adds it to the job's summary under TROUPE_SIGN_LABEL, and fails naming any file that
# does not hold.
set -eu

verify=0
if [ "${1-}" = --verify ]; then
  verify=1
  shift
fi
if [ $# -eq 0 ]; then
  echo "usage: sign-macos.sh [--verify] PATH..." >&2
  exit 2
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Every candidate: executables, and libraries by their usual names, which a release does
# not always mark executable. `file` decides.
: >"$work/candidates"
for path in "$@"; do
  if [ -d "$path" ]; then
    find "$path" -type f \( -perm -u+x -o -name '*.so' -o -name '*.dylib' \) -print >>"$work/candidates"
  elif [ -f "$path" ]; then
    case "$(file -b "$path")" in
      Mach-O*) printf '%s\n' "$path" >>"$work/candidates" ;;
      *)
        echo "sign-macos: $path is not a Mach-O file" >&2
        exit 1
        ;;
    esac
  else
    echo "sign-macos: $path is not there" >&2
    exit 1
  fi
done

: >"$work/machos"
while IFS= read -r f; do
  case "$(file -b "$f")" in
    Mach-O*) printf '%s\n' "$f" >>"$work/machos" ;;
  esac
done <"$work/candidates"
count=$(wc -l <"$work/machos" | tr -d ' ')
if [ "$count" -eq 0 ]; then
  echo "sign-macos: no Mach-O file under $*" >&2
  exit 1
fi

sign_one() {
  f=$1
  identity=${TROUPE_SIGN_IDENTITY:?TROUPE_SIGN_IDENTITY names what codesign signs with}
  set -- --force --sign "$identity" --options runtime
  if [ "$identity" = - ] || [ "${TROUPE_SIGN_TIMESTAMP-}" = none ]; then
    set -- "$@" --timestamp=none
  else
    set -- "$@" --timestamp
  fi
  if [ -n "${TROUPE_SIGN_KEYCHAIN-}" ]; then
    set -- "$@" --keychain "$TROUPE_SIGN_KEYCHAIN"
  fi
  # Entitlements belong to a program, not to a library it loads.
  case "$(file -b "$f")" in
    *executable*)
      if [ -n "${TROUPE_SIGN_ENTITLEMENTS-}" ]; then
        set -- "$@" --entitlements "$TROUPE_SIGN_ENTITLEMENTS"
      fi
      ;;
  esac
  codesign "$@" "$f"
}

if [ "$verify" = 0 ]; then
  while IFS= read -r f; do
    sign_one "$f"
  done <"$work/machos"
  echo "signed $count Mach-O files under $* with ${TROUPE_SIGN_IDENTITY}"
  exit 0
fi

authority=${TROUPE_SIGN_AUTHORITY-}
: >"$work/bad"
while IFS= read -r f; do
  if ! codesign --verify --strict "$f" 2>"$work/err"; then
    printf '%s: %s\n' "$f" "$(tr '\n' ' ' <"$work/err")" >>"$work/bad"
    continue
  fi
  details=$(codesign -dv --verbose=2 "$f" 2>&1)
  case "$details" in
    *"(runtime"* | *",runtime"*) ;;
    *)
      printf '%s: no hardened runtime (an ad hoc signature from the linker, not ours)\n' "$f" >>"$work/bad"
      continue
      ;;
  esac
  case "$authority" in
    "") ;;
    adhoc)
      case "$details" in
        *Signature=adhoc*) ;;
        *) printf '%s: not signed ad hoc\n' "$f" >>"$work/bad" ;;
      esac
      ;;
    *)
      case "$details" in
        *"Authority=$authority"*) ;;
        *) printf '%s: not signed by %s\n' "$f" "$authority" >>"$work/bad" ;;
      esac
      ;;
  esac
done <"$work/machos"

if [ -s "$work/bad" ]; then
  echo "sign-macos: these Mach-O files do not carry the signature asked for:" >&2
  cat "$work/bad" >&2
  exit 1
fi
by=${authority:-any identity}
echo "verified: $count Mach-O files under $* carry a hardened-runtime signature ($by)"
if [ -n "${GITHUB_STEP_SUMMARY-}" ] && [ -n "${TROUPE_SIGN_LABEL-}" ]; then
  echo "- ${TROUPE_SIGN_LABEL}: $count Mach-O files signed ($by)" >>"$GITHUB_STEP_SUMMARY"
fi
