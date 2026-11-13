# An MCP identity's key

How to make, register and rotate the key a profile signs its client assertions with, when it
calls an MCP server as itself ([a profile's options](profile-options.md#calling-an-mcp-server-as-the-profile)
says what the identity is and what the assertion carries). The examples use the server
`jira` and the worker namespace `troupe-w-dev`.

## Setting one up

1. Make a key and a certificate for the profile's client (or have your PKI issue one), and
   work out the thumbprint: base64url, without padding, of the SHA-256 of the certificate
   in DER. The 64 hex digits `openssl x509 -fingerprint -sha256` prints are taken too.

   ```sh
   openssl req -x509 -newkey rsa:2048 -nodes -keyout jira.key -out jira.crt \
     -days 365 -subj "/CN=troupe-w-dev jira"
   openssl x509 -in jira.crt -outform DER | openssl dgst -sha256 -binary \
     | basenc --base64url | tr -d '='
   ```

2. Import the key into transit under a name that starts with the profile's worker
   namespace and a dot, then delete every copy of `jira.key`. `bao transit import` wraps the
   key for you; it is not exportable from then on.

   ```sh
   openssl pkcs8 -topk8 -nocrypt -in jira.key -outform DER | base64 -w0 > jira.key.b64
   bao transit import transit/keys/troupe-w-dev.jira @jira.key.b64 type=rsa-2048
   shred -u jira.key jira.key.b64
   ```

3. Register `jira.crt` with the identity provider as the client's credential, and grant the
   client the server's roles or scopes.

4. Write the identity on the profile, with `keyVersion: 1` and the thumbprint. The pods
   read it from a file ([§2](profiles-and-policy.md#2-what-the-operator-creates)) and use it from their next
   token, with no restart.

The pods need leave to sign with the key: attach the policy `Troupe.KMS.Policy.mcp_identity/2`
renders, which lets a pod sign with the keys named after its own namespace and nothing
else, to the Kubernetes-auth role they log in with
([roles and permissions §8](roles-and-permissions.md#8-openbao-policies)).

## Rotating

Make the new key and certificate as in step 1, register the new certificate beside the old
one, and import the key as the next version of the same transit key:

```sh
bao transit import-version transit/keys/troupe-w-dev.jira @jira-2.key.b64
```

Then change `keyVersion` and `certificateThumbprint` on the profile in one change. A worker
signs with the pinned version until it reads the new pair, then gets its next token with
the new key; there is no gap, because the identity provider holds both certificates.
Remove the old certificate once the old tokens have run out, an hour later. With no
`keyVersion` a worker signs with the latest version, so an import before the profile names
the new thumbprint fails token requests in between.
