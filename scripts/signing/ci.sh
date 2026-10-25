#!/bin/sh
# The parts of native.yml's OS signing that are the same in every job, so that they are
# written once and can be read and checked outside a workflow file.
#
#   sh scripts/signing/ci.sh plan SIGN
#       The `signing` job. SIGN is native.yml's `sign` input: empty, `release` or
#       `self-signed`. For `release` the job hands over SET_<NAME>=true for each signing
#       secret of the `release` environment that is set, never a value. Writes macos= and
#       windows= (none, unsigned, release or self-signed) and macos_reason= and
#       windows_reason= to $GITHUB_OUTPUT.
#
#   sh scripts/signing/ci.sh job LABEL
#       Each build job's first signing step. MACOS, WINDOWS, MACOS_REASON and
#       WINDOWS_REASON are the plan's outputs and SIGN the input. Writes mode= for this
#       runner and signs=true when this build signs, and a line in the job's summary for a
#       build that was asked to be signed and is not.
#
#   sh scripts/signing/ci.sh env MODE
#       What the signing scripts read, for the job's later steps, through $GITHUB_ENV: the
#       script (TROUPE_SIGN, which Troupe.Release.OSSigning runs), and the tool, identity,
#       entitlements and timestamp it signs with. IDENTITY, AUTHORITY and KEYCHAIN are the
#       macOS keychain step's outputs. None of it is a secret.
#
#   sh scripts/signing/ci.sh record FILE...
#       The sha256 of each FILE, once its signatures have been checked, into
#       $RUNNER_TEMP/os-signed/records.txt: what the signing test's manifest check holds
#       the release's manifest to.
#
# A platform whose first secret is absent builds unsigned and says so: that is every
# release until the certificates exist. One whose first secret is set and another is not
# fails, naming what is missing: half a set of secrets is a mistake to fix, not a release
# to ship unsigned.
set -eu

out=${GITHUB_OUTPUT:-/dev/stdout}
summary=${GITHUB_STEP_SUMMARY:-/dev/null}
root=$(cd "$(dirname "$0")/../.." && pwd)

# The first of each list turns that platform's signing on; docs/developer/code-signing.md
# says where each comes from.
apple="APPLE_CERTIFICATE APPLE_CERTIFICATE_PASSWORD APPLE_SIGNING_IDENTITY APPLE_API_ISSUER APPLE_API_KEY APPLE_API_PRIVATE_KEY"
azure="AZURE_ENDPOINT AZURE_CODE_SIGNING_NAME AZURE_CERT_PROFILE_NAME AZURE_TENANT_ID AZURE_CLIENT_ID AZURE_CLIENT_SECRET"

is_set() { eval "[ \"\${SET_$1:-false}\" = true ]"; }

# decide OS NAME... : the release's mode for one platform.
decide() {
  os=$1
  shift
  first=$1
  if ! is_set "$first"; then
    printf '%s=unsigned\n%s_reason=%s not set\n' "$os" "$os" "$first"
    return 0
  fi
  missing=""
  for name in "$@"; do
    is_set "$name" || missing="$missing $name"
  done
  if [ -n "$missing" ]; then
    echo "error: $first is set in the release environment but not:$missing" >&2
    echo "error: set them too (docs/developer/code-signing.md), or remove $first to release unsigned" >&2
    return 1
  fi
  printf '%s=release\n%s_reason=\n' "$os" "$os"
}

os_name() {
  case "${RUNNER_OS:-$(uname -s)}" in
    macOS | Darwin) echo macOS ;;
    Windows | MINGW* | MSYS*) echo Windows ;;
    *) echo Linux ;;
  esac
}

case "${1-}" in
  plan)
    sign=${2-}
    case "$sign" in
      "") printf 'macos=none\nwindows=none\nmacos_reason=\nwindows_reason=\n' >>"$out" ;;
      self-signed)
        printf 'macos=self-signed\nwindows=self-signed\nmacos_reason=\nwindows_reason=\n' >>"$out"
        ;;
      release)
        # shellcheck disable=SC2086
        decide macos $apple >>"$out"
        # shellcheck disable=SC2086
        decide windows $azure >>"$out"
        ;;
      *)
        echo "error: sign is '$sign'; it is empty, release or self-signed" >&2
        exit 2
        ;;
    esac
    ;;

  job)
    label=${2:?usage: ci.sh job LABEL}
    case "$(os_name)" in
      macOS) mode=${MACOS:-none} reason=${MACOS_REASON-} ;;
      Windows) mode=${WINDOWS:-none} reason=${WINDOWS_REASON-} ;;
      *) mode=none reason="Linux has no OS signature to add" ;;
    esac
    case "$mode" in
      release | self-signed) signs=true ;;
      *) signs=false ;;
    esac
    printf 'mode=%s\nsigns=%s\n' "$mode" "$signs" >>"$out"
    if [ -n "${SIGN-}" ]; then
      case "$mode" in
        unsigned) echo "- $label: unsigned: $reason" >>"$summary" ;;
        none) echo "- $label: not signed: $reason" >>"$summary" ;;
      esac
    fi
    echo "$label: $mode"
    ;;

  env)
    mode=${2:?usage: ci.sh env MODE}
    workspace=${GITHUB_WORKSPACE:-$root}
    env_file=${GITHUB_ENV:-/dev/stdout}
    case "$(os_name)" in
      macOS)
        {
          printf '%s\n' "TROUPE_SIGN=$workspace/scripts/signing/sign-macos.sh"
          printf '%s\n' "TROUPE_SIGN_IDENTITY=${IDENTITY:?the keychain step names the identity}"
          printf '%s\n' "TROUPE_SIGN_AUTHORITY=${AUTHORITY-}"
          printf '%s\n' "TROUPE_SIGN_KEYCHAIN=${KEYCHAIN-}"
          if [ "$mode" = release ]; then
            printf '%s\n' "TROUPE_SIGN_ENTITLEMENTS=$workspace/scripts/signing/beam.entitlements"
          else
            printf '%s\n' "TROUPE_SIGN_ENTITLEMENTS=$workspace/scripts/signing/beam-test.entitlements"
            printf '%s\n' "TROUPE_SIGN_TIMESTAMP=none"
          fi
        } >>"$env_file"
        ;;
      Windows)
        # D:/a/... rather than D:\a\...: PowerShell, Elixir and Git's shell all read it.
        workspace=$(printf '%s' "$workspace" | tr '\\' '/')
        {
          printf '%s\n' "TROUPE_SIGN=$workspace/scripts/signing/sign-windows.ps1"
          if [ "$mode" = release ]; then
            printf '%s\n' "TROUPE_SIGN_TOOL=artifact-signing"
          else
            printf '%s\n' "TROUPE_SIGN_TOOL=signtool"
          fi
        } >>"$env_file"
        ;;
      *)
        echo "error: nothing signs on $(os_name)" >&2
        exit 1
        ;;
    esac
    ;;

  record)
    shift
    dir="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/os-signed"
    mkdir -p "$dir"
    for f in "$@"; do
      if command -v sha256sum >/dev/null 2>&1; then
        sum=$(sha256sum "$f" | cut -d' ' -f1)
      else
        sum=$(shasum -a 256 "$f" | cut -d' ' -f1)
      fi
      printf '%s  %s\n' "$sum" "$(basename "$f")" | tee -a "$dir/records.txt"
    done
    ;;

  *)
    echo "usage: ci.sh plan SIGN | job LABEL | env MODE | record FILE..." >&2
    exit 2
    ;;
esac
