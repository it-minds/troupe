# troupe-daemon

The local harness, as one release per platform. It is `troupe_core`, `troupe_gateway` and
`troupe_protocol` — the same three applications a worker pod runs, its siblings in this
umbrella — packaged as the `troupe_daemon` Mix release with the platform's own Erlang
runtime inside. The TUI (`clients/tui`) and the desktop app (`clients/gui`) are clients of
it.

<a id="install"></a><a id="start-at-login"></a><a id="how-long-it-stays-up"></a>
Its commands, installing it, starting it at login, the web app, its variables and how long
it stays up are on [the daemon](../../docs/user/daemon.md).

## Building

From this directory, so that only the harness is compiled:

```sh
cd apps/troupe_daemon
mix test
MIX_ENV=prod mix release troupe_daemon
tar -xzf ../../_build/prod/troupe_daemon-*.tar.gz -C /some/dir
/some/dir/bin/troupe-daemon version
/some/dir/bin/troupe_daemon eval 'IO.puts(Troupe.Version.version())'
```

`zig` must be on the `PATH`: the release step builds the `reaper` helper for the host
triple into the release, and a daemon without it fails every `shell` call. The release is
defined in this directory's `mix.exs`; its runtime configuration is
[`config/runtime.exs`](config/runtime.exs) here, not the platform's, and `rel/` holds its
`env.sh.eex` and `env.bat.eex`. The version is the umbrella's `VERSION`, and so is the
harness's: they are one commit. The Windows release builds the harness's zstd NIF
(`ezstd`) from an it-minds fork that compiles it with Zig
([the daemon's Decision 5](../../docs/decisions/daemon/0005-windows-is-back-in-the-matrix-on-a-fork-of-ezstd.md)).

`.github/workflows/native.yml` builds the Linux, macOS and Windows targets on native
runners — nightly, for every pre-release and release, and on a pull request that touches
the daemon, Linux and Windows only — and smokes each (unpack, `version`, `status`, `run`, `status`, `eval`; on
Windows `version`, `status` and a zstd round trip in `eval`). A release attaches the
tarballs to the GitHub release with everything else it ships.

[The daemon's decisions](../../docs/decisions/daemon/README.md) say why a release and not a
Burrito binary, and the rest.
