# A profile's options

The parts of a [worker profile](profiles-and-policy.md) beyond its image, size and endpoint:
a profile that extends another and says only what differs, an identity of its own at an
MCP server, a repository's agents and skills against the bundle's, a person's own tools on
its pods, and per-tool rules every session there obeys. The fields themselves are in
[profiles and policy §1](profiles-and-policy.md#1-what-an-administrator-sets).

## A profile that extends another

An organisation can keep one **standard** profile (the model, the egress, the MCP servers
and the limits everybody gets) and give a team that needs more a profile that **extends**
it and says only what differs (Decision 908). The plane resolves the two into the profile
in effect, and that is all the cluster sees: the operator, admission and the workers get a
flat `WorkerProfile`.

```json
{"name": "data-team", "extends": "standard", "max_sessions": 10,
 "spec": {"egress": {"fqdns": ["warehouse.example.com"]},
          "llm": {"secretRef": {"name": "data-team-llm"}}}}
```

| Field | What the child gets |
|---|---|
| `egress.fqdns`, `egress.gitHosts` | the parent's, and its own **added**; each still checked against the policy |
| `mcpServers` | the parent's, and its own **added** by name. One with a parent's name replaces the parent's only with `"override": true`; otherwise the parent's is kept and the clash is reported |
| agents, skills, MCP servers and ACP agents in the bundle its pods load | the parent's channel's, and its own channel's **added** by name (Bundles, below) |
| `max_sessions` | the **lower** of the two: a child can narrow a ceiling, never raise it |
| `budget_micros` | the **lower** of the two; one set above the parent's is **refused** with a sentence |
| `personalTools`, `repositoryOverridesBundle` | a parent's `forbid` or `false` **holds** whatever the child says; otherwise the child's, or the parent's |
| `image`, `size_class`, `provisioner`, the `llm` fields, `storage.storageClassName`, `configBundleChannel`, `github`, `orgMount` and any other field | the child's where it sets one, the parent's where it does not (for `github`'s caps and denied paths, see [github.md §9](github.md#9-how-far-a-run-may-go)) |
| `llm.secretRef`, `mcpIdentities`, grants, `warm_workers` | **never inherited**: a key and an identity are each profile's own, in its own namespace, and a grant of the standard does not make a team a user of its extensions |

An empty field is one the child does not set, so a child cannot take away what its parent
has: if a team should have less, the standard is too wide. A chain is at most four profiles
long, counting the one that extends nothing; a missing parent, a cycle and a longer chain
are refused with a sentence.

- **Reading one.** `admin.profile.get` answers `spec` and `written` as the profile wrote
  them (what to change and send back) and `extended_by`, the profiles that extend it. With
  `"effective": true` it adds `effective`: the chain, the profile in effect, and `fields`,
  every path and value with the profile it came from. Its `problems` says when the child
  has its model endpoint from a parent whose key it lacks, and `identity_problems` names an
  inherited client-credentials server the child has no identity for. The console's profile
  page shows "Extends" and where each field comes from; its editor leaves to the parent
  whatever is left empty.
- **Changing the parent.** `admin.profile.preview` of the parent lists every profile below
  it in `extended_by`, each with its diff and the policy's verdict. `admin.profile.put`
  refuses a change that would leave a child the plane or the policy refuses, naming it;
  otherwise it rewrites each child's resource, and its pods roll as for any change. The
  audit has one `profile.put`, the parent's, with `extended_by` naming each child and what
  changed in it.
- **Bundles** are composed (Decision 910). A child on its parent's channel, or naming none,
  loads that bundle as it is. A child on a channel of its own loads one the plane
  composes: the parent's channel's agents, skills, MCP servers and ACP agents, with its own
  channel's added by name. An entry named like one the parent's bundle has replaces it only
  where the child's channel's document says `"override": true` on it (an agent may say it
  in its frontmatter); otherwise the parent's is kept, and `effective.bundle.problems` says
  so. The MCP servers each profile in the chain wrote itself are a layer after its
  channel's, by the same rule, so a profile that extends nothing but wrote servers of its
  own has a composed bundle too. The plane publishes a composed bundle, when it differs, as
  a version of the child's own channel `profile:<name>`: its pods fetch and check it by
  hash and a session pins its version, as on any channel, and a publish or retire anywhere
  in the chain composes it again. The resource's `mcpServers` are the composed bundle's, so
  the reach and identity checks read what the pods load. `profile:` channels are the
  plane's: publishing or retiring one by hand, or naming one as a profile's channel, is
  refused. `admin.profile.get` with `effective` lists it in `effective.bundle` (channel,
  hash, the channels it is made from, each entry with the profile whose channel gave it);
  the console shows it as "The bundle its pods load".
- **Deleting the parent** is refused (`conflict`, `extended_by`) while a profile extends it.
  Make each extend another profile, or none: a put without `extends` keeps the profile as
  it was in effect, following nothing from then on.
- **In gitops mode** a manifest names its parent in `spec.extends` and says only what
  differs; the plane writes the profile in effect into the resource's status
  ([gitops.md](gitops.md#a-manifest-that-extends-another)). `admin.profiles.export` writes a
  child's manifest that way.

## Calling an MCP server as the profile

Some MCP servers take machine callers only through OAuth client credentials, want the
client to prove itself with a signed assertion (a private key JWT, RFC 7523) rather than a
shared secret, and grant tools per client. For those each profile gets its **own system
identity**: its own client at the identity provider, with its own certificate and granted
tools, so two profiles never share permissions (Decision 747). The bundle marks the server
`"credential_mode": "client_credentials"` ([bundles](bundles-and-triggers.md#1-config-bundles));
the profile says who it is there.

```yaml
spec:
  mcpIdentities:
    - server: jira                         # the bundle's name for the server
      clientId: 00000000-0000-0000-0000-000000000000
      scope: api://example-jira/.default   # optional
      tokenUrl: https://login.example.com/tenant/oauth2/v2.0/token   # optional
      transitKey: troupe-w-dev.jira        # <worker namespace>.<anything>
      keyVersion: 1                        # optional; absent is the key's latest
      certificateThumbprint: qIAESDPaFvTg7nQnau6q6AzzzpMg6PElJvINleJ0N2s
      algorithm: RS256                     # or PS256
```

A worker asks the token endpoint for a token with `grant_type=client_credentials`, the
client id, the scope and an assertion: `iss` and `sub` the client, `aud` the token
endpoint, five minutes' life, a unique `jti`, and the certificate named in the header's
`x5t#S256`. **OpenBao transit** signs it: the worker sends the signing input and gets the
signature back, so the private key never leaves OpenBao, not even into the worker's memory.
The worker keeps one token per server, renews it a minute before it runs out (or at three
quarters of its life, if that is sooner), asks again once after a `401`, and sends it as
`Authorization: Bearer`; it is never in a log, an error or the event log. Without
`tokenUrl` the token endpoint is the one the server's authorization server publishes (named
in its protected-resource metadata). `tokenUrl`'s host is egress the policy must allow, and
one found in metadata must be in `egress.fqdns`.

**Setting one up.**

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

**Rotating.** Make the new key and certificate as in step 1, register the new certificate
beside the old one, and import the key as the next version of the same transit key:

```sh
bao transit import-version transit/keys/troupe-w-dev.jira @jira-2.key.b64
```

Then change `keyVersion` and `certificateThumbprint` on the profile in one change. A worker
signs with the pinned version until it reads the new pair, then gets its next token with
the new key; there is no gap, because the identity provider holds both certificates.
Remove the old certificate once the old tokens have run out, an hour later. With no
`keyVersion` a worker signs with the latest version, so an import before the profile names
the new thumbprint fails token requests in between.

**What is reported.** A `client_credentials` server with no identity on the profile, or an
identity without `clientId` or `transitKey`, with a thumbprint that is not one, another
algorithm, a `keyVersion` that is not a positive number, or a `tokenUrl` that is not
`https` (or `http` to loopback), is reported rather than refused, as a missing Secret is: by
the operator's `MCPIdentityMissing` condition and in `admin.profile.get`'s and
`admin.profile.put`'s `identity_problems`. The pods start regardless and offer that server's
tools once both halves are there. A worker that cannot get a token says which server and
why: the token endpoint refused the client (with the provider's error), the transit key is
not in OpenBao, the pod may not sign with it, or the server refused a tool the identity
lacks.

## A repository's agents and skills on a pod

A session's working copy may carry agents and skills of its own (`.troupe/agents/*.md`,
`.troupe/skills/<name>/`, `.agents/skills/<name>/`), which arrive with a clone. On a pod the
**bundle's agents and skills, and the agents Troupe ships, beat them** where the names are
the same (Decision 826): a working copy's `build.md` replaces neither the bundle's `build`
nor, where the bundle has none, Troupe's own, and its `review-checklist` skill does not
stand in for the bundle's. The same holds for the pod's own config directory, and on a pod
whose channel has nothing published. Other names are read as on a laptop.

A file that loses is not read. The session lists it, with the reason, in a `files_skipped`
event, written at each activation whose list differs from the last one recorded:

```json
{"files": [{"kind": "agent", "name": "build", "path": "/var/lib/troupe/workspaces/<id>/.troupe/agents/build.md",
            "reason": "the session's bundle has an agent named build, and on a pod the bundle's beats a repository's unless the profile allows the repository's"}]}
```

An agent named like a built-in gets the reason `build is an agent Troupe ships, and on a
pod Troupe's own beats a repository's unless the profile allows the repository's`. The
terminal and the desktop app show the event in the transcript as a note: how many of each
kind, each file, and why.

A profile that wants the repository's files to win, over the bundle's and the built-ins
alike, sets the switch:

```yaml
spec:
  repositoryOverridesBundle: true
```

Only `true` turns it on, and `admin.profile.put` refuses a value that is not a boolean. The
console's profile editor has it as a toggle. It rides the activation, not the pod: the plane
reads it at every activation and sends it with the bundle pin, so a change reaches a session
the next time it wakes and restarts no pod, and an `ssh` profile has it too.

Onboarding (`troupe onboard`, the question a session's start asks, and the `onboard_write`
tool) refuses on a pod and says to onboard on your own machine and commit the result: the
working copy is a clone the bundle beats, and the config directory is the pod's, read by
every session it runs.

Commands have nothing to lose to yet: a bundle carries no commands, so a working copy's
`.troupe/commands/` are read on a pod as on a laptop, and a command named like an agent
stays the agent's, which on a pod is the bundle's (Decision 763).

## A person's own tools on a pod

A person signed in to an MCP server on their own machine can offer its tools to a session
on a pod from the desktop app or the TUI: the session registers them as tools the client
hosts (`tools.register`), and each call runs on the person's machine with their sign-in
([security.md §8](security.md#8-a-persons-own-tools-on-a-teams-pods)). A team whose pods
should work only with what the profile names forbids it (Decision 862):

```yaml
spec:
  personalTools: forbid
```

A session on those pods then refuses the offer before it asks the person anything,
answering `forbidden` with `setting: personalTools`, the profile's name, and the sentence
`the worker profile <name> does not take a person's own tools on its pods (personalTools:
forbid); only the profile's MCP servers are available`. The pod logs one warning per
refusal, with the session, the person and the tools; nothing is registered, and the
session's own log records nothing. The desktop app shows the sentence where it would have
said what is offered, the TUI shows it once as a note, and neither offers the person's
servers to that session again while it stays open.

`admin.profile.put` and the resource's schema refuse any value but `allow` and `forbid`,
and anything but `forbid` leaves the offer as it is. The console's profile editor has it as
a toggle. Like `repositoryOverridesBundle` it rides the activation, so a change reaches a
session the next time it wakes, restarts no pod, and applies to `ssh` profiles too; a
session awake when it changes keeps what it had until then. The platform's
`managed_mcp_servers_only` refuses the same offer on every profile at once.

## Per-tool rules on a profile

A profile may carry the per-tool rules a person's config carries
([permissions](../user/configuration/permissions.md)), and every session on its pods obeys
them (Decision 913, #724):

```yaml
spec:
  permissions:
    deny: ["shell(curl)", "read_file(secrets/**)"]
    ask: ["mcp(issues.delete)"]
    allow: ["shell(mix test)"]
```

They are an enforced layer, the `profile` scope: of every rule that matches a call the
strictest holds, `deny` over `ask` over `allow`, so nothing in a repository's
`.troupe/config.yaml` loosens them, and a profile's `allow` stands under
`managed_permission_rules_only` as the organisation's does. A refused call names the rule
and the profile ("refused by the rule deny shell(curl), from the worker profile fixing"),
and an asked one says so on its approval in the TUI and the desktop app. A `deny` for
`shell` also refuses a command a person types with `!` in a session on these pods
(`forbidden`, `setting: permissions`); an `ask` does not, since the person typing it is who
it would ask. A person sees these, and the rest of what is in force in a session (the
profile's provider and models, the platform's switches, the session's terms), with
`troupe config --explain --session <id>`, `/settings` in the terminal UI, or the desktop
app's **Settings** pane.

`admin.profile.put` and the resource's reading refuse a rule the pods could not read, with
the reader's sentence. The rules ride the activation like `personalTools`. A profile that
extends another has its parent's rules as well as its own, each a scope of its own on the
pods, so a child adds rules and cannot loosen or drop its parent's. The console's profile
editor edits a profile's own rules, and its page lists every rule in effect with the
profile it came from.
