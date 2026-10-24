#!/bin/sh
# A keychain of the job's own, holding the identity codesign signs with, for a macOS
# native build. Nothing of the runner's own login keychain is used or changed.
#
#   sh scripts/signing/macos-keychain.sh release
#       The Developer ID Application certificate from APPLE_CERTIFICATE (the base64 of
#       the .p12), APPLE_CERTIFICATE_PASSWORD and APPLE_SIGNING_IDENTITY, the release
#       environment's secrets.
#   sh scripts/signing/macos-keychain.sh self-signed
#       A certificate made here, for the signing test, and never for a release: CN
#       "Troupe signing test", two days long. If this runner's codesign will not sign with
#       it, as it is not trusted, it is trusted for code signing on this runner; if even
#       that is refused, the identity is `-` (ad hoc) and the summary says so.
#   sh scripts/signing/macos-keychain.sh delete
#
# Writes identity=, authority= (what `sign-macos.sh --verify` expects) and keychain= to
# $GITHUB_OUTPUT.
set -eu

out=${GITHUB_OUTPUT:-/dev/stdout}
summary=${GITHUB_STEP_SUMMARY:-/dev/null}
keychain="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/troupe-signing.keychain-db"
# LibreSSL, which macOS ships, writes a .p12 `security import` reads; a newer OpenSSL on
# the PATH writes one it does not.
openssl=/usr/bin/openssl
test_name="Troupe signing test"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

new_keychain() {
  password=$($openssl rand -hex 24)
  security delete-keychain "$keychain" >/dev/null 2>&1 || true
  security create-keychain -p "$password" "$keychain"
  security set-keychain-settings -lut 21600 "$keychain"
  security unlock-keychain -p "$password" "$keychain"
  # Searched first, and beside the user's others, so codesign and Tauri find it by name.
  # shellcheck disable=SC2046
  security list-keychains -d user -s "$keychain" $(security list-keychains -d user | tr -d '"')
}

import_p12() {
  security import "$1" -k "$keychain" -P "$2" -f pkcs12 -T /usr/bin/codesign -T /usr/bin/security >/dev/null
  # codesign may use the key without asking anybody.
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$password" "$keychain" >/dev/null
}

# probe IDENTITY: whether codesign signs with it here.
probe() {
  cp /usr/bin/true "$work/probe"
  codesign --force --sign "$1" --keychain "$keychain" --timestamp=none "$work/probe" >/dev/null 2>&1
}

case "${1-}" in
  release)
    : "${APPLE_CERTIFICATE:?not set}" "${APPLE_CERTIFICATE_PASSWORD:?not set}" "${APPLE_SIGNING_IDENTITY:?not set}"
    new_keychain
    printf '%s' "$APPLE_CERTIFICATE" | base64 --decode >"$work/identity.p12"
    import_p12 "$work/identity.p12" "$APPLE_CERTIFICATE_PASSWORD"
    # The identity by its certificate's SHA-1, which is no secret, so the step's output
    # that carries it is passed on like any other.
    sha1=$(security find-identity -v -p codesigning "$keychain" | grep -F "\"$APPLE_SIGNING_IDENTITY\"" | awk '{print $2}' | head -1)
    if [ -z "$sha1" ]; then
      echo "error: APPLE_SIGNING_IDENTITY is not an identity of APPLE_CERTIFICATE; the certificate holds:" >&2
      security find-identity -v -p codesigning "$keychain" >&2
      exit 1
    fi
    printf 'identity=%s\nauthority=Developer ID Application:\nkeychain=%s\n' "$sha1" "$keychain" >>"$out"
    ;;
  self-signed)
    new_keychain
    cat >"$work/cert.cnf" <<EOF
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext
[dn]
CN = $test_name
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
    $openssl req -x509 -newkey rsa:2048 -nodes -days 2 -config "$work/cert.cnf" \
      -keyout "$work/key.pem" -out "$work/cert.pem" 2>/dev/null
    p12_password=$($openssl rand -hex 16)
    $openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" -name "$test_name" \
      -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -out "$work/identity.p12" -passout "pass:$p12_password"
    import_p12 "$work/identity.p12" "$p12_password"
    sha1=$($openssl x509 -noout -fingerprint -sha1 -in "$work/cert.pem" | sed 's/.*=//; s/://g')
    if probe "$sha1"; then
      how="the self-signed certificate"
    elif sudo security add-trusted-cert -d -r trustRoot -p codeSign -k /Library/Keychains/System.keychain "$work/cert.pem" &&
      probe "$sha1"; then
      how="the self-signed certificate, trusted for code signing on this runner"
    else
      sha1=""
    fi
    if [ -n "$sha1" ]; then
      printf 'identity=%s\nauthority=%s\nkeychain=%s\n' "$sha1" "$test_name" "$keychain" >>"$out"
      echo "signing with $how ($sha1)"
    else
      printf 'identity=-\nauthority=adhoc\nkeychain=%s\n' "$keychain" >>"$out"
      echo "::notice::codesign refused the self-signed certificate on this runner; signing ad hoc"
      echo "- macOS: codesign refused the self-signed certificate on this runner, so the test signs ad hoc" >>"$summary"
    fi
    ;;
  delete)
    security delete-keychain "$keychain" >/dev/null 2>&1 || true
    ;;
  *)
    echo "usage: macos-keychain.sh release | self-signed | delete" >&2
    exit 2
    ;;
esac
