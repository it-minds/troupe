# Contributing to Troupe

Troupe is Apache-2.0 ([LICENSE](LICENSE)), and a contribution is accepted under the same
licence. Bug reports, fixes, documentation and clients written against
[PROTOCOL.md](PROTOCOL.md) are all welcome. Everyone here follows the
[code of conduct](CODE_OF_CONDUCT.md). A security problem goes to [SECURITY.md](SECURITY.md),
never to a public issue.

## Before you start

For anything larger than a small fix, open an issue first, or say on an existing one that
you are taking it, so nobody builds the same thing twice or something the design rules
out. Issues labelled `good first issue` are small and self-contained.
[ARCHITECTURE.md](ARCHITECTURE.md) is the design and [DECISIONS.md](DECISIONS.md) says why
things are the way they are: a change that undoes a numbered decision says so.

## Build and check

The toolchain is pinned in [`.tool-versions`](.tool-versions): Erlang/OTP, Elixir, Zig and
Node. `mise install` (or `asdf install`) installs it; on Windows,
`scripts/setup-windows-toolchain.ps1`. Then, per part of the repository:

```sh
mix deps.get && mix check                                        # the umbrella
(cd clients/tui && mix deps.get && mix check)                    # the TUI
(cd clients/gui && pnpm install && pnpm build && pnpm test)      # the GUI
```

`mix check` is the gate: it compiles with warnings as errors, checks the format, runs
`credo --strict`, the boundary check and the tests. `scripts/ci` runs CI's own job on your
machine, and some suites need the services from `scripts/dev-up`.
[docs/developer/](docs/developer/README.md) has the rest: [local setup](docs/developer/local-setup.md),
[testing](docs/developer/testing.md), [conventions](docs/developer/conventions.md).

## A first contribution

1. Fork the repository and branch from `main`.
2. Make one change: a fix with the test that shows it, or one feature. Keep unrelated
   clean-ups for another pull request.
3. Run the gate for the part you changed, and regenerate anything generated that your change
   touches ([build.md](docs/developer/build.md#3-generated-committed-files) lists them).
4. Commit with `git commit -s` (see below). The message states the behaviour that is now
   true, in plain prose - "A session's listing says what it has actually spent" - and its
   body says what was wrong and why this is the fix. No `fix:` prefixes.
5. Open a pull request into `main` and fill in the template. CI runs what your change can
   have broken; `ci-ok`, `dco` and `licences` have to pass. A maintainer reviews it and
   merges it.

The maintainers batch their own fixes on `development-<date>` branches
([fixing-issues.md](docs/developer/fixing-issues.md)); a pull request from outside goes
straight to `main`.

## Sign-off (DCO)

Every commit carries a `Signed-off-by:` line with your name and email. It certifies the
[Developer Certificate of Origin](https://developercertificate.org): that you wrote the
change, or have the right to submit it under the project's licence. `git commit -s` adds
it. For a branch that lacks it, `git rebase --signoff main` and push the branch again.
The `dco` check requires it of commits authored from 2026-09-27, when the rule started;
the history before that is unsigned.

## Coding agents

[AGENTS.md](AGENTS.md) holds the rules for agents working here, and they hold for what an
agent writes for you: no `Co-Authored-By:` trailers or "Generated with" lines, PowerShell
scripts in plain ASCII. The sign-off is yours whoever typed the change, and so is the
responsibility for it.

## Dependencies

A new dependency has to be under a licence the policy at the top of
[scripts/licences.exs](scripts/licences.exs) allows: permissive ones pass, copyleft ones
need a reviewed exception, which the script's header explains. The `licences` check says
which. After adding or removing a package, fetch everything (`mix deps.get` at the root
and in `clients/tui`, `pnpm install` in `clients/gui`, and Rust installed for `cargo`),
run `elixir scripts/licences.exs` and commit
[docs/third-party-licences.md](docs/third-party-licences.md) and
[THIRD-PARTY-NOTICES.txt](THIRD-PARTY-NOTICES.txt) with it. A package whose licence
texts change needs the same: the notices carry them into every download and image.
