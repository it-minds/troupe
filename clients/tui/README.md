# troupe, the terminal client

`troupe` is the terminal client of the Troupe harness: an Elixir TUI, one self-contained
executable per platform built with [Burrito](https://github.com/burrito-elixir/burrito),
that speaks [`PROTOCOL.md`](../../PROTOCOL.md) to the troupe daemon on this machine (or the
same daemon started inside itself) and to a plane's worker pods.

<a id="use"></a>
Installing it, using it, its exit codes and its remote sessions are on
[the terminal client](../../docs/user/terminal-client.md); its screen on
[the terminal client's screen](../../docs/user/terminal-screen.md), and every command line
and command on [the command reference](../../docs/user/cli-reference.md).

## Development

The toolchain is pinned in `.tool-versions` / `mise.toml`: Erlang 28.5, Elixir 1.20.4, Zig
0.16.0 (Burrito 1.6 requires exactly that Zig).

```sh
mix deps.get              # the harness apps are path dependencies on ../../apps
mix check                 # compile --warnings-as-errors, format, credo --strict, xref, the generated files' checks, test
scripts/dev [args]        # run the CLI/TUI from source without a build (dev loop)
scripts/build-local       # Burrito binary for this host, installed as ~/.local/bin/troupe
TROUPE_PROVIDER=fake TROUPE_FAKE_SCRIPT="$PWD/fixtures/fake_scripts/smoke.json" \
  troupe run build smoke --headless --auto-approve
```

The harness (`troupe_core`, `troupe_gateway`, `troupe_protocol`) is a path dependency on
`../../apps/`, the umbrella this project sits in, at the same commit: there is no pin to
bump, and a change to the harness is made there, with `PROTOCOL.md` and a decision in
`docs/decisions/`, in the same pull request as the TUI change that needs it. A package
both this project and the umbrella lock must be at one version in both `mix.lock` files;
`elixir scripts/locks-agree.exs` at the repository root checks the ones they share, and CI
runs it. The version is the root `VERSION`. `troupe_core`'s compile cross-compiles the
`reaper` helper for the host, and `TROUPE_REAPER_TARGETS=all` builds every target (the
release does this). Every OS process a session starts runs under reaper, which kills the
whole process tree when its owner dies. `TROUPE_PROVIDER=fake` and `TROUPE_FAKE_SCRIPT`
give a deterministic model; so do `provider: fake` and `fake_script:` in a workspace's
`.troupe/config.yaml`, once the workspace is trusted, which is how the test suite does it.
`mix troupe.remote.smoke` runs login, list, attach and one input against a real
deployment when `TROUPE_REMOTE_URL` is set, and skips itself otherwise.

The harness is [the harness and its clients](../../docs/developer/architecture.md); this
client's supervision tree and its remote client are
[§7 there](../../docs/developer/architecture.md#7-the-tui-clientstui); and
[its decisions](../../docs/decisions/tui/README.md) are every deviation from the original
specification.

## Out of scope (for now)

Offering this machine's built-in tools (its files, its shell) to a remote session (a
person's own signed-in MCP servers are offered), a GUI for the remote side (that is
`clients/gui`, beside this directory), a Web UI, multi-node distribution, a resident
assistant or free-text routing at the dispatcher, auto-commit or undo in the user's
checkout, updating itself unasked, the operating systems' own code signing and notarisation (every
release is signed with the release key, which `troupe update` checks;
[code-signing.md](../../docs/developer/code-signing.md)), and native Windows ARM builds.
