#!/bin/sh
# OpenBao's own entrypoint, with a helper started beside it that makes the server usable
# by the plane and the worker. It runs as root before the image hands the server to the
# `openbao` user, so it can keep the keys where root alone reads them.
#
# The first start initialises the server with one unseal key, and keeps that key and the
# root token in /openbao/keys/init (0600, root). Every start unseals with it, and then
# makes sure, idempotently, of what Troupe needs: the transit engine and the session-token
# key, the KV v2 mount, the plane's policies as docs/admin/openbao.md lists them and the
# worker's, and one token for each, written to /openbao/tokens for the plane and the
# worker to read (0400, uid 1000). The tokens are made by root with no lifetime, so they
# are good until the file is deleted and this runs again.
#
# What this is honest about: the unseal key is on the same disk as the data it unseals.
# A cluster keeps the share outside; a box in a corner keeps it in the corner, and a
# backup of the OpenBao volumes is a backup of both.
set -e

KEYS=/openbao/keys/init
TOKENS=/openbao/tokens
export BAO_ADDR=http://127.0.0.1:8200

helper() {
  # `bao status` exits 0 unsealed, 2 sealed or uninitialised, 1 when the server does
  # not answer yet: anything but 1 is a server to talk to.
  while bao status >/dev/null 2>&1; [ $? -eq 1 ]; do
    sleep 1
  done

  if [ ! -s "$KEYS" ]; then
    echo "openbao: initialising, the unseal key and the root token go to $KEYS"
    umask 077
    bao operator init -key-shares=1 -key-threshold=1 > "$KEYS"
    chmod 600 "$KEYS"
  fi

  unseal="$(awk '/^Unseal Key 1:/ {print $4}' "$KEYS")"
  export BAO_TOKEN
  BAO_TOKEN="$(awk '/^Initial Root Token:/ {print $4}' "$KEYS")"

  bao operator unseal "$unseal" >/dev/null
  echo "openbao: unsealed"

  bao secrets list -format=json | grep -q '"transit/"' || bao secrets enable -path=transit transit
  bao secrets list -format=json | grep -q '"secret/"' || bao secrets enable -path=secret -version=2 kv
  bao read transit/keys/troupe-session-tokens >/dev/null 2>&1 \
    || bao write -f transit/keys/troupe-session-tokens type=ecdsa-p256 >/dev/null

  # The plane's grants, as `mix troupe.openbao.policy` writes them for the docs and the
  # kind cluster; every one, so the Overview reports nothing missing.
  bao policy write troupe-plane-session-tokens - <<'POLICY'
path "transit/sign/troupe-session-tokens" {
  capabilities = ["create", "update"]
}
path "transit/keys/troupe-session-tokens" {
  capabilities = ["read"]
}
POLICY
  bao policy write troupe-plane-signing - <<'POLICY'
path "transit/keys/troupe-plane-signing" {
  capabilities = ["create", "read", "update"]
}
path "transit/keys/troupe-plane-signing/rotate" {
  capabilities = ["update"]
}
path "transit/sign/troupe-plane-signing" {
  capabilities = ["create", "update"]
}
POLICY
  bao policy write troupe-plane - <<'POLICY'
path "secret/metadata/troupe/teams/+/sessions/*" {
  capabilities = ["delete", "list", "read"]
}
path "secret/metadata/troupe/people/+/sessions/*" {
  capabilities = ["delete", "list", "read"]
}
path "secret/metadata/troupe/people/+/mcp/*" {
  capabilities = ["list", "read"]
}
POLICY
  bao policy write troupe-plane-invites - <<'POLICY'
path "secret/metadata/troupe/people/+/invited/*" {
  capabilities = ["delete"]
}
POLICY
  bao policy write troupe-plane-github - <<'POLICY'
path "transit/wrapping_key" {
  capabilities = ["read"]
}
path "transit/keys/troupe-github-app" {
  capabilities = ["read", "delete"]
}
path "transit/keys/troupe-github-app/config" {
  capabilities = ["update"]
}
path "transit/keys/troupe-github-app/import" {
  capabilities = ["create", "update"]
}
path "transit/keys/troupe-github-app/import_version" {
  capabilities = ["create", "update"]
}
path "transit/sign/troupe-github-app" {
  capabilities = ["create", "update"]
}
path "transit/keys/troupe-github-webhook" {
  capabilities = ["read", "delete"]
}
path "transit/keys/troupe-github-webhook/config" {
  capabilities = ["update"]
}
path "transit/keys/troupe-github-webhook/import" {
  capabilities = ["create", "update"]
}
path "transit/keys/troupe-github-webhook/import_version" {
  capabilities = ["create", "update"]
}
path "transit/hmac/troupe-github-webhook/sha2-256" {
  capabilities = ["create", "update"]
}
POLICY

  # The worker's: every team's session keys, as the shared role on a cluster has, and
  # no delete anywhere, so a worker cannot make a session unreadable.
  bao policy write troupe-shared-worker - <<'POLICY'
path "secret/data/troupe/teams/+/sessions/*" {
  capabilities = ["create", "read", "update"]
}
path "secret/metadata/troupe/teams/+/sessions/*" {
  capabilities = ["read", "list"]
}
POLICY

  mkdir -p "$TOKENS"
  if [ ! -s "$TOKENS/plane" ]; then
    bao token create -orphan -field=token -display-name=troupe-plane \
      -policy=troupe-plane-session-tokens -policy=troupe-plane-signing -policy=troupe-plane \
      -policy=troupe-plane-invites -policy=troupe-plane-github > "$TOKENS/plane"
    echo "openbao: the plane's token is written"
  fi
  if [ ! -s "$TOKENS/worker" ]; then
    bao token create -orphan -field=token -display-name=troupe-worker \
      -policy=troupe-shared-worker > "$TOKENS/worker"
    echo "openbao: the worker's token is written"
  fi
  chown 1000:1000 "$TOKENS/plane" "$TOKENS/worker"
  chmod 400 "$TOKENS/plane" "$TOKENS/worker"
  # What the health check reads: the server is unsealed and the tokens are there.
  date > "$TOKENS/ready"
  echo "openbao: ready"
}

# Not ready until this start's helper says so: a restart must unseal before the plane
# is told the key manager is up.
rm -f "$TOKENS/ready"

( helper 2>&1 | sed 's/^/[helper] /' ) &

exec /bin/sh /usr/local/bin/docker-entrypoint.sh "$@"
