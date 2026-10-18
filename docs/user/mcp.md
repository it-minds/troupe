# MCP servers and skills

An MCP server gives an agent more tools; a skill gives it instructions for one kind of
job. Both are files you keep beside `config.yaml`, in the shapes other agent tools use,
so what you have for Claude Code, Claude Desktop, Cursor, VS Code, opencode or Codex comes
over as it is. The [recipes](configuration/mcp-agents-skills.md) are complete files; this
page says how Troupe reads them.

## The files

```
<config>/mcp.json                 your MCP servers, on every workspace
<config>/skills/<name>/SKILL.md   your skills
<workspace>/.troupe/mcp.json      the workspace's servers, for whoever opens the repository
<workspace>/.troupe/skills/       the workspace's skills
```

`<config>` is on [Where your files are](configuration/files.md).

Skills are also read in place from `.agents/skills`, the directory other tools share:
`~/.agents/skills/<name>/SKILL.md` (`%USERPROFILE%\.agents\skills` on Windows), and
`.agents/skills/` in the directory a session starts in and in each directory above it up
to the repository root. Troupe never writes there. Of two skills with one name the nearer
`.agents/skills` wins, and one in `<config>/skills` or `.troupe/skills` beats any of them
([which one wins](configuration.md#which-one-wins)). An `.agents/skills`, or a skill in
it, that is a link outside the repository (outside `~/.agents`, for yours) is not read.
Nothing else under `.agents/` is read but `.agents/AGENTS.md`
([instruction files](instructions.md)).

## mcp.json

`mcp.json` is `{"mcpServers": {name: {"command", "args", "env"}}}`, or `{"url",
"headers"}` for a server over HTTP, with one key of Troupe's own: `"include":
["~/.claude/.mcp.json"]` reads another file in place. A `skills.json` beside a `skills/`
directory does the same for directories of skills: `{"include": ["~/.claude/skills"]}`.
`config.yaml`'s `mcp:` takes the same entries ([its keys](configuration.md#tools)).

- A `command` that is a program's name is looked for on the `PATH` alone, never in the
  directory Troupe was started in; a relative path (`bin/server`) is taken from the
  server's `cd`, else the workspace.
- `${VAR}` in an imported file becomes `{env:VAR}`, read as the rest of the configuration
  reads it.
- opencode's servers are under `mcp` in its `opencode.json`, and Codex's are
  `[mcp_servers.<name>]` tables in a project's `.codex/config.toml` or your own
  `~/.codex/config.toml`; both import or link from there. Codex's `bearer_token_env_var`
  becomes an `Authorization` header read from that variable and `env_http_headers`
  headers read from theirs; what has no place in Troupe's entry (`enabled_tools`,
  `http_headers_helper`, a tool's approval mode) is named in what the import says. Your
  own `~/.codex/config.toml` goes into your `mcp.json` only, never a workspace's.

A server's tools are named `mcp.<server>.<tool>`, so they never collide with the built-in
ones, and each call asks first, as `shell` does, unless the server's `permission` is
`auto`. A `url` server is spoken to over the MCP specification's streamable HTTP
transport: `initialize` before the first call, and the session the server hands back, if
it keeps one, carried on every call after, opened again once if the server has forgotten
it, and ended when the Troupe session ends.

### The layers, and the /mcp page

The layers stack as the config files do: the workspace's file over yours over
`config.yaml`'s `mcp:`, an entry of one name merged key by key, so a workspace can say
`{"fs": {"disabled": true}}` and no more.

The TUI's `/mcp` page and the desktop app's **Servers and skills** panel show every server
and skill with the layer and file it came from, and each server's state (✓ ready,
… connecting, ✗ error) and tools. A server that fails to start is marked, and the rest
still work. Both import a file (`/mcp import <path>` copies one into your `mcp.json`,
`/skills import <dir>` a directory of skills; `link` in place of `import` reads it where
it is; `--workspace` writes the workspace's `.troupe/mcp.json` or `.troupe/skills/`
instead), remove one, and try a server before it is kept. On the TUI's page the layers
read `[user]`, `[workspace]` and `[config]`; `c` checks a server (and starts one written
after the session began), `d` disables or enables it and `x` removes it.

`skills.list`, which both ask, also lists each skill that is not offered and why:
`skipped`, naming the one of that name that is used, or `outside`. A skill from an
`.agents/skills` shows its layer, `agents` or `user_agents`, and is removed where it is,
not from Troupe; removing one there says so. Your own skills are offered to every agent;
a bundle's as its profiles list them.

## A workspace's servers wait for you

A workspace's servers are commands a cloned repository would run, so a session starts
them only after asking you: `deny`, `once` or `allow`. `allow` holds for the workspace, is
kept in Troupe's state directory and never in the repository, and is asked again when a
server's command changes. A workspace on `trusted_workspaces` is not asked
([trusted workspaces](configuration.md#trusted-workspaces)).

The answer starts them and no more. Until the workspace is trusted:

- a server its `.troupe/mcp.json`, or a file that links, sets to `"permission": "auto"`
  asks before each call; the question says so, and `mcp.list` gives the server a note
  naming the command. A server of your own `mcp.json` keeps its `auto`;
- its `.troupe/mcp.json` reads nothing from outside the repository: a file it includes
  from elsewhere (your `~/.claude.json`, say), or a `.troupe/mcp.json` that is itself a
  link out, gives no servers, and the `/mcp` page's warnings say so and name the command.
  Your own `mcp.json` may include any file;
- what its `.troupe/skills.json` includes from outside the repository (`"include":
  ["~"]`) is not offered, and its files are not readable with `read_file`, as a
  `read_roots` in its `config.yaml` is not; `skills.list` names it, why, and the command.
  An include inside the repository is read either way.

## Where the daemon connects

A `url` server, and everything a sign-in to it calls (the server's metadata, the
authorization server's, and the token and revocation endpoints), is called from your
machine, and only at an address that passes one check. The name is resolved, every
address it answers is checked, and the request goes to the address that passed, so a name
that answers one address to the check and another a moment later is not followed there. A
redirect is checked the same way before it is followed; the token endpoint follows none.
TLS still checks the server's certificate against its name.

| | Addresses |
|---|---|
| Refused | link-local (`169.254.0.0/16`, `fe80::/10`); a cloud's metadata service (`169.254.169.254`, `fd00:ec2::254`, `100.100.100.200`), however the address is written, an IPv4 address written as IPv6 included; the unspecified address (`0.0.0.0`, `::`) |
| Allowed | loopback, for a server you run on this machine; the private ranges (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `fc00::/7`), where an intranet's servers are; everything else |

One refused address among a name's answers refuses the name, and so does a name that does
not resolve (`does not resolve (nxdomain)`). The server's line on the `/mcp` page says
what it resolved to (`wiki.example.com resolves to 169.254.169.254, a link-local address,
and is not called`), and a sign-in whose metadata names such an address is refused before
your browser opens. The authorization endpoint is opened by your browser, not the daemon:
its name is refused at the same addresses when it resolves on this machine, and left to
the browser when it does not. A sign-in's URLs are `https`, or `http` on `127.0.0.1`,
`[::1]` or `localhost`.

## A server that wants a key

A server over HTTP that takes a key, a token or a team's name in a header gets it from the
entry's `headers`, sent with every request to it, the first one too:

```json
{
  "mcpServers": {
    "tracker": {
      "url": "https://mcp.example.com/mcp",
      "headers": {"Authorization": "Bearer {env:TRACKER_TOKEN}", "X-Team": "core"}
    }
  }
}
```

A value is written as it is, or as `{env:VAR}`, read from the environment each time the
server starts and never written back. An unset variable keeps the server from starting,
its line on the `/mcp` page says which, and nothing is sent in its place. Keep a key out
of the file: `mcp.json` is a file people link, copy and commit. Troupe keeps no keychain
for these; a server that signs you in keeps its tokens as the next section says.

What the daemon says about a server names its headers and never shows a value, and
`troupe config --explain` masks one in `config.yaml`'s `mcp:` as it masks a key. A header
Troupe sends itself (`Accept`, `Content-Type`, `Mcp-Session-Id`, `Mcp-Protocol-Version`)
cannot be set, and on a server with `oauth` the sign-in's token is the `Authorization`
that goes out, whatever the headers say. A workspace's server that sends headers is asked
about with their names, and asked again when they change.

Importing another tool's file carries its headers and its servers' `env`. A value that
reads the environment comes over as `{env:VAR}`; one written out in the file is not
copied into yours. A header becomes `{env:<SERVER>_<HEADER>}`, after its `Bearer` when it
has one (`Bearer {env:TRACKER_AUTHORIZATION}`), a variable `{env:<SERVER>_<NAME>}`
(`GITHUB_TOKEN` of `github` as `{env:GITHUB_GITHUB_TOKEN}`), and the import says which
variable to set to what the other file has. That holds for a `LOG_LEVEL` as for a token,
since an import cannot tell one from the other; a value that is no secret is one edit to
write back. A linked file is read where it is, values and all. Claude Code's
`headersHelper`, a command that prints headers, is not run, and the import says so.

## A server that wants you to sign in

Some servers act as *you*: they answer a call without a sign-in with `401`, name an
authorization server (often your organisation's identity provider), and then call what is
behind them as you, or show you only what is yours. A key in `env` will not do for those.
Give the entry an `oauth` with the id of a client registered for it with that
authorization server; whoever runs the server says what it is, since a provider with no
dynamic registration has no other way to know Troupe:

```json
{
  "mcpServers": {
    "wiki": {
      "url": "https://mcp.example.com/mcp",
      "oauth": {"client_id": "00000000-0000-0000-0000-000000000000"}
    }
  }
}
```

The rest is found from the server: where to sign in (its protected-resource metadata and
the authorization server's) and which scopes it wants.

- `oauth.scopes` overrides the scopes; `offline_access` is added when the authorization
  server offers it, so the sign-in lasts beyond the hour.
- `oauth.redirect_uri` fixes where the browser comes back, for a client registered with
  one port (`http://localhost:33418/callback`). Left out, it is `http://127.0.0.1/callback`
  on any free port, which a client registered with a loopback redirect accepts.
- `oauth.resource: false` leaves out the resource indicator for an authorization server
  that refuses it (Microsoft Entra ID's v2.0 endpoint is one; the scopes say which API
  the token is for there).
- `oauth.issuer` names the authorization server for a server that publishes no metadata
  of its own.

Then sign in: `/mcp sign-in wiki` in the TUI, `s` on the server's line of the `/mcp` page,
or **Sign in** on the desktop app's **Servers and skills** panel. Your browser opens on
the provider's page and comes back to the daemon, which listens for it on this machine,
so open the URL on the machine the daemon runs on. The page says "Signed in to … as …",
and a session waiting for the server gets its tools at once. The sign-in is kept in
Troupe's state directory (`mcp-oauth.json`, readable by you alone), never in `mcp.json`,
and refreshed when it runs out. When the provider stops taking it, the server's line says
to sign in again, and a tool the model calls answers `sign_in_required` instead of
failing. A workspace's server is signed in to only after the workspace's servers are
allowed, since its `oauth` came with the repository.

Some tools want more than you granted: writing where you signed in to read, say. The
server answers such a call `403` naming the scope it wants, and the model is told
`sign_in_required` with that scope, to tell you. Nothing signs in for you: the server's
line on the `/mcp` page says what it wants (`wants notes.write — s`), and when you choose
to grant it, `s` (or `/mcp sign-in wiki`, or **Sign in**) asks the same provider for what
you granted before and the new scope. Until that sign-in lands the old one is used, and if
you say no at the provider you keep it.

`/mcp sign-out wiki`, `o`, or **Sign out** forgets the sign-in on this machine and asks
the provider to revoke it, so a copy of Troupe's state directory can no longer renew it.
The TUI says whether the provider was told: one that refuses or does not answer within a
few seconds is not, and one that offers no way to revoke is named as such; either way the
sign-in is forgotten here, and the provider takes it until it runs out. `troupe logout`,
without a plane named, does the same for every server you are signed in to and says so
for each; if the daemon is not running, it says your sign-ins were kept.

## Your servers on a team's pod

A session on your team's pod gets your signed-in servers' tools from your client. Open it
in the desktop app and it asks whether to offer them, naming them; **Offer them**
registers each as `client.<server>.<tool>`, and a line at the top says what is offered.
In the TUI, for a pod session opened from HQ, the question waits in its window as an
approval naming the tools, `y` offers them and `n` does not, and a line in the transcript
says what was offered.

When the agent calls one, the call comes back to your client and the daemon on this
machine makes it with your sign-in: the pod sees the arguments and the answer, never the
sign-in, and everyone in the session can see that it uses tools on your machine. A call
goes through the session's approvals like any other tool's. Closing the session, or the
client, takes the tools away; a connection that drops and comes back offers them again
without asking twice. A team may keep people's own tools off its pods (`personalTools:
forbid` on the profile): such a session asks nothing, both clients say that your servers
are not offered there and why, and neither offers them again while the session is open.
