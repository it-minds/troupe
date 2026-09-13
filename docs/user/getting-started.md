> Audited against troupe-remote commit 4083b1f (branch main), 2026-09-13. See [AUDIT.md](../AUDIT.md).

# Getting started

Four steps: install the binary, sign in to your team's plane, run a first session on
the team's pods, and (optionally) run one on your own machine with your own model key.
If your team only uses the GUI, you still need the binary for the command line, `troupe
admin`, `troupe verify` and the MCP bridge; the GUI itself needs nothing installed.

## 1. Install the `troupe` binary

`troupe` is one executable per platform (Linux x86_64 and aarch64, macOS x86_64 and
aarch64, Windows x86_64). There is nothing to install alongside it.

> **Caveat.** No published release has been confirmed from this repository: the
> release workflow exists but the audit found no evidence it has run, and the default
> download location in the installers is a GitHub project that may not carry
> artifacts. Ask your administrator where your organisation publishes the binary and
> set `TROUPE_RELEASE_URL` (or `-ReleaseUrl`) to it. See [AUDIT.md](../AUDIT.md) §4,
> open question 2.

Linux and macOS:

```bash
curl -fsSL "$TROUPE_RELEASE_URL/install.sh" -o install.sh && sh install.sh
```

Windows (PowerShell):

```powershell
irm "$env:TROUPE_RELEASE_URL/install.ps1" -OutFile install.ps1; .\install.ps1
```

What the installers do:

| Behaviour | install.sh | install.ps1 |
|---|---|---|
| Download base | `TROUPE_RELEASE_URL` (default: GitHub latest release) | `-ReleaseUrl` or `TROUPE_RELEASE_URL` |
| Install directory | `TROUPE_INSTALL_DIR` (default `~/.local/bin`) | `-InstallDir` or `TROUPE_INSTALL_DIR` (default `%LOCALAPPDATA%\Programs\troupe`) |
| Specific version | `--version X` | `-Version X` |
| Verifies the download | SHA-256 against the published `SHA256SUMS`; a mismatch aborts | same |
| Keeps the previous binary | `troupe.previous` next to the new one | same |
| Adds to PATH | one line in your shell profile; open a new shell afterwards | user PATH |
| Remove | `install.sh --uninstall`; add `--purge` to also delete configuration and session history | `install.ps1 -Uninstall`; add `-Purge` |

**Unsigned binaries.** The binaries are not code-signed.

* macOS: a binary downloaded through a browser carries the quarantine attribute and
  Gatekeeper refuses to run it. The installer downloads with `curl`, which does not set
  it. If you downloaded by hand:

  ```bash
  xattr -d com.apple.quarantine troupe
  ```

* Windows: SmartScreen shows "Windows protected your PC". Choose **More info → Run
  anyway**. The installer downloads with `Invoke-WebRequest`, which does not attach the
  mark-of-the-web. Some antivirus products flag self-extracting binaries generically.

Check it:

```bash
troupe --version
```

Sources:
- install.sh:7-9, 17-18, 26-48, 70, 136-152, 182-194, 207-209
- install.ps1:7-31, 38-44, 68, 85-89, 130-131
- README.md:41-77
- mix.exs release targets (see docs/AUDIT.md §1.1)
- docs/AUDIT.md §4 question 2

## 2. Sign in to the plane

You need the plane's URL from your administrator, for example
`https://troupe.example.com`.

```bash
troupe login https://troupe.example.com
```

What happens, in order:

1. `troupe` asks the plane where its identity provider is and which client id to use.
2. It starts a device-code login with the provider and prints:

   ```
   Open https://login.example.com/device
   and enter the code ABCD-EFGH
   ```

   Nothing opens a browser for you. Open the URL yourself, on any device, and enter the
   code. The provider may show you the full verification URL with the code already
   filled in.
3. `troupe` polls the provider at the interval the provider asks for. If the provider
   says "slow down", it does. If you take longer than the provider allows (usually ten
   minutes) you get `the login code expired before it was used`; run the command
   again.
4. Once you have signed in, `troupe` sends the provider's token to the plane, which
   answers with who you are and what you may use, and prints:

   ```
   Logged in to https://troupe.example.com as Ada Lovelace.

   Teams:    platform, research
   Profiles: dev, review
   ```

   If you see `You are not in any team this plane has enabled. Ask a platform admin.`
   or `No profiles are granted to them yet`, the login worked but there is nothing you
   can start on; that is an administrator's job. See
   [troubleshooting.md](troubleshooting.md#no-profiles-after-login).

**Where the credential goes.** One file, readable only by you:

| Platform | Path |
|---|---|
| Linux, macOS | `$TROUPE_CONFIG_HOME/troupe/credentials.json`, else `$XDG_CONFIG_HOME/troupe/credentials.json`, else `~/.config/troupe/credentials.json` |
| Windows | the same rule; with neither variable set it is `<home>\.config\troupe\credentials.json` |

It holds the provider's **refresh token** and what the plane told you (teams,
profiles), keyed by plane URL. It never holds a plane token: those are short-lived and
are minted from the refresh token each time a command needs one. You can be logged in
to several planes; a bare command uses the one you logged in to most recently, and
`--plane URL` picks another.

To forget a plane:

```bash
troupe logout https://troupe.example.com
```

`troupe logout` without a URL forgets the most recently used plane. It only deletes
the local file entry; it does not sign you out of the identity provider.

Sources:
- apps/troupe_ctl/lib/troupe/ctl/login.ex:34-44, 48-54, 56-73, 75-85, 90-132, 137-169
- apps/troupe_ctl/lib/troupe/ctl/credentials.ex:17-26, 46-52, 85-123, 127-136
- apps/troupe_ctl/lib/troupe/cli.ex:134-168, 338-354

## 3. Your first remote session

```bash
troupe --remote
```

`troupe` renews your plane token, asks the plane which profiles you may use, creates a
session on that profile, and opens the terminal UI connected to the pod the plane
chose. You see one line before the UI takes over:

```
20260913T101502-Ab3dEf on https://troupe.example.com (dev)
```

**If you have more than one profile** the command stops with:

```
troupe: several profiles are available (dev, review); name one with --agent
```

Name one:

```bash
troupe --remote --agent review
```

On a remote session `--agent` names the **profile**, not the starting agent. (Locally
the same flag names the starting agent.) The session starts with the profile's default
primary agent, `build`.

**If you are in more than one team that may use that profile**, the plane refuses with
`choose a team` and lists them. The command line has no flag for this today; use the
GUI or a script that passes `team` to `session.create`. See
[troubleshooting.md](troubleshooting.md#several-profiles-or-teams).

Type a task and press Enter. The agent works; approvals pop up when a tool needs one
(`y` allow, `a` allow for this session, `n` deny). Quit with **Ctrl-C twice**; the
session keeps running on the pod. Come back to it with:

```bash
troupe --remote sessions
```

```bash
troupe --remote resume 20260913T101502-Ab3dEf
```

To run one task without the UI and exit when it is done:

```bash
troupe --remote run "make the tests pass" --headless
```

Sources:
- apps/troupe_ctl/lib/troupe/cli.ex:183-186, 249-331
- apps/troupe_ctl/lib/troupe/ctl/remote.ex:38-51, 149-192, 216-225
- apps/troupe_plane/lib/troupe/plane/harness.ex:147-166, 432-456
- apps/troupe_tui/lib/troupe/ui/tui/server.ex:77-108

## 4. Your first local session

A local session runs in a daemon on your machine, works on the files in the directory
you start it in, and calls a model with a key you supply. It needs no plane and no
login.

### The minimum configuration

Create the global config file:

| Platform | Path |
|---|---|
| Linux, macOS | `$XDG_CONFIG_HOME/troupe/config.yaml` (default `~/.config/troupe/config.yaml`) |
| Windows | `%APPDATA%\troupe\config.yaml` |

`TROUPE_CONFIG_HOME` overrides the directory on every platform.

```yaml
provider: anthropic          # anthropic | openai | fake
model: claude-sonnet-5
api_key: "{env:ANTHROPIC_API_KEY}"
```

`{env:VAR}` is replaced by the environment variable when the file is read, so the key
stays out of the file. An unset variable becomes an empty string, and the provider
then refuses the request as a missing key rather than sending the placeholder.

Provider notes:

* `anthropic` talks to the Anthropic Messages API. With no `api_key`, `ANTHROPIC_API_KEY`
  from the environment is used.
* `openai` talks to any OpenAI-compatible chat-completions endpoint; set `base_url`
  for a gateway. With no `api_key`, `OPENAI_API_KEY` is used.
* `fake` is a scripted model for dry runs; see below.

A project can override keys in `<workspace>/.troupe/config.yaml`, and the environment
variables `TROUPE_PROVIDER`, `TROUPE_MODEL`, `TROUPE_BASE_URL`, `TROUPE_API_KEY` and
`TROUPE_FAKE_SCRIPT` override both files. Merging is key by key, so a project file that
sets only `model` keeps the global provider.

### Run it

```bash
cd ~/src/my-project
```

```bash
troupe
```

The first client starts the daemon for you; ten terminals starting at once produce one
daemon. The terminal UI opens on a new session in that directory. Type a task, press
Enter. Quit with Ctrl-C twice; the session stays in the daemon until it has been idle
for 30 minutes, and `troupe resume` reattaches to it. The daemon itself shuts down
after ten minutes with nothing running and nobody attached.

### A dry run with no model

The `fake` provider plays a script. Put this in `script.json`:

```json
{"steps": [
  {"tools": [{"name": "write_file", "input": {"path": "hello.txt", "content": "hi\n"}}]},
  {"text": "Done."}
]}
```

```bash
TROUPE_PROVIDER=fake TROUPE_FAKE_SCRIPT=script.json troupe run "smoke" --headless --auto-approve
```

You should see the tool call, a tick, `Done.`, and exit code 0. This is how the
packaged binary is smoke-tested and a quick way to confirm the install before spending
money.

### Where local state goes

| What | Path |
|---|---|
| Session logs and blobs | `$XDG_STATE_HOME/troupe/sessions/<workspace-hash>/<session-id>/` (Linux, macOS; default `~/.local/state/troupe`), `%LOCALAPPDATA%\troupe\sessions\...` (Windows). `TROUPE_STATE_HOME` overrides. |
| Your own agent definitions | `<config dir>/agents/*.md` (global) or `<workspace>/.troupe/agents/*.md` (project) |
| Daemon socket (Linux, macOS) | `$XDG_RUNTIME_DIR/troupe/daemon.sock`, else `~/.troupe/run/troupe/daemon.sock` |
| Daemon discovery file (Windows, or where a Unix socket is unavailable) | `%LOCALAPPDATA%\troupe\daemon.json` (else `$XDG_RUNTIME_DIR` or `~/.troupe/run`) |

Nothing is written into your repository.

Sources:
- apps/troupe_core/lib/troupe/config.ex:5-16, 19-65, 75-81, 113-124, 139-154
- apps/troupe_core/lib/troupe/paths.ex:5-7, 13-16, 34, 42-46, 69-71, 83-91
- apps/troupe_core/lib/troupe/agent/definition.ex:11-12
- apps/troupe_core/lib/troupe/sessions/index.ex:91-92
- apps/troupe_ctl/lib/troupe/cli.ex:533-534, 623-624, 686-687
- apps/troupe_protocol/lib/troupe/protocol/endpoint.ex:112-130
- apps/troupe_protocol/lib/troupe/protocol/daemon.ex:11-28
- README.md:83-95, 250-258
- docs/AUDIT.md §1.7 (fake provider, ANTHROPIC_API_KEY / OPENAI_API_KEY fallbacks)
