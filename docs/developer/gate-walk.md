# Walking the Stage 1 gate

The runbook for walking Stage 1's release gate on a fresh laptop, with a fresh Anthropic
account, against the live plane: what to have before the walk, how its record is kept and
what runs locally. For each of the eight rows, [the rows' page](gate-walk-rows.md) has what
proves it, the steps, a pass and a fail, and the issues and decisions behind it. Stage 1 is
tagged when all eight pass on one release.

| | the row | where it is walked |
| --- | --- | --- |
| 1 | [A cloned repository can make Troupe do nothing unasked](gate-walk-rows.md#1-a-cloned-repository-does-nothing-unasked) | the laptop; mostly scripted |
| 2 | [A worker is isolated from neighbours and the cloud](gate-walk-rows.md#2-a-worker-is-isolated) | the live plane |
| 3 | [A fresh Anthropic account finishes a session](gate-walk-rows.md#3-a-fresh-anthropic-account-finishes-a-session) | the laptop |
| 4 | [The seam is proven once, on camera](gate-walk-rows.md#4-the-seam-on-camera) | the laptop and the live plane |
| 5 | [An organisation rolls out once and stays current](gate-walk-rows.md#5-rolled-out-once-and-current) | the laptop and the console |
| 6 | [An organisation sets config once for everyone](gate-walk-rows.md#6-config-set-once-for-everyone) | the laptop and the console |
| 7 | [The docs describe the product that ships](gate-walk-rows.md#7-the-docs-describe-what-ships) | anywhere; partly scripted |
| 8 | [The board tells the truth](gate-walk-rows.md#8-the-board-tells-the-truth) | anywhere; scripted queries |

## Before the walk

- **The release.** One published release, the one Stage 1 tags, installed with its
  installers from its release page, never from a checkout. Below it is `<version>`, such as
  `0.16.0-beta`.
- **The fresh laptop.** A machine, or a new user account on one, that has never had Troupe,
  Erlang or another coding agent's config: no `~/.config/troupe`, `%APPDATA%\troupe`,
  `~/.claude` or `.burrito` directory. Record its operating system and version. A second
  laptop on the other operating system is worth a second walk of rows 1, 3 and 5.
- **The fresh Anthropic account.** A new organisation in the Claude Console, with a card or
  prepaid credit and one API key, used for nothing else. A new organisation may start in an
  evaluation tier below the standard limits
  ([Anthropic: rate limits](https://platform.claude.com/docs/en/api/rate-limits), read
  2026-10-12); that is the point of the row.
- **The live plane.** Platform admin in its console, a team with a worker profile granted to
  it, and `kubectl` with the cluster's credentials. The plane runs `<version>` before rows
  2, 4, 5 and 6 (`curl -sS https://<plane>/.well-known/troupe | jq .plane.build`).
- **A clone of the repository** at the release's tag, `git clone --branch v<version>
  https://github.com/it-minds/troupe`, for `scripts/gate-check` and the docs. Cloning
  installs nothing.
- **The record.** One issue for the release, `Stage 1 gate: v<version>`, kept as
  [below](#the-record).

The order that wastes least: `gate-check` and rows 7 and 8 at a desk, rows 1 and 3 on the
laptop, rows 5 and 6 with the console open, row 2, then row 4, which needs everything else
working.

## The record

Each release has one issue, `Stage 1 gate: v<version>`, whose body is the table above with
a result column for that release (Decision 933):

- **A comment per row walked:** **PASS** or **FAIL**, the date, the machine and its
  operating system, what was run and what it printed (`gate-check`'s whole output for the
  rows it covers), and the issue filed for each failure. A failure is fixed or filed before
  the record moves on, never left as known.
- **A row is walked again only where a change touched it.** On a new release, a row that
  passed on an earlier one is walked again when a pull request merged since then changes
  what its steps run or what the decisions under its "Behind it" govern
  (`mix troupe.decisions --for` on the files the pull requests changed), or fixes a failure
  filed from it. Otherwise its comment says the result is carried and links the comment it
  was walked in. `gate-check` runs on every release whatever is carried.
- **A failure fixed is a new release, and that row walked again on it.** A row passes on a
  release somebody installed, never on a fix that is only merged.
- **Private evidence stays out.** The repository is public: live-plane output goes in with
  host, cluster, account and identity-provider names replaced by `example.com`, and the
  comment says the raw output and any recording are kept in the live deployment's private
  records, without naming where. Nothing from a person's own home, keychain or settings
  goes in.

Stage 1 is tagged when every row's result for one release is a **PASS**, walked on it or
carried to it.

## What runs locally: `scripts/gate-check`

`scripts/gate-check` (Linux and macOS) and `scripts/gate-check.ps1` (Windows) run the parts
of rows 1, 3, 5, 6, 7 and 8 that need no person and no live plane, against the installed
`troupe`. Each run points `HOME`, the config, state and runtime directories (on Windows also
`USERPROFILE`, `HOMEDRIVE`, `HOMEPATH` and `LOCALAPPDATA`) into a new temporary directory;
every model is the scripted `fake` one, no provider key reaches it, and whatever it starts
is stopped before it ends. Run it from the clone:

```sh
sh scripts/gate-check                     # Linux, macOS
sh scripts/gate-check --board             # and row 8's queries (gh, signed in)
```

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\gate-check.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\gate-check.ps1 -Board
```

`--offline` (`-Offline`) leaves out what asks GitHub; `--keep` (`-Keep`) keeps the scratch
directory for row 1's steps. It prints one line per check, `PASS`, `FAIL` or `SKIP` with
the row number (a `SKIP` says why the check would prove nothing here), and exits 1 when any
failed. It takes under a minute. Paste its whole output into the comments of the rows it
covers.

| row | what it checks | what still needs a person |
| --- | --- | --- |
| 1 | a repository whose `.troupe/config.yaml` turns approvals off and points the model elsewhere, whose `.troupe/mcp.json` starts a program, whose git config and hooks run programs, which carries programs named `git` and `rg` and another tool's `CLAUDE.md`: none of it holds or runs, until `troupe config trust` (which it also shows deciding), and a headless session there writes and runs nothing unasked | the questions and refusals as a person sees them, in both clients |
| 3 | `troupe doctor --bench`: a turn of tool calls, a cut output, a compaction, a cancel, a replay and the onboarding scenarios, offline | a real account and a real session |
| 5 | `troupe update --check` finds the latest release and its manifest signed by the release key; a release signed by another key is refused with nothing installed | an update, on a plane's recommendation, of a real install |
| 6 | an organisation's document with `max_turns` and `approvals` enforced: `troupe config --explain` holds a user file's higher value to it and names the organisation | the plane's console, `troupe config pull`, the managed file |
| 7 | the installed `troupe --help` prints exactly the command table in the [command reference](../user/cli-reference.md), and the clone's `VERSION` is the installed version | reading the pages |
| 8 | with `--board`: every open issue is on the board and not **Done**, every issue closed as completed is **Done** | judging what shipped |

## 1. A cloned repository does nothing unasked

Its proof, steps, pass and fail are on
[the rows' page](gate-walk-rows.md#1-a-cloned-repository-does-nothing-unasked).

## 2. A worker is isolated

Its proof, steps, pass and fail are on
[the rows' page](gate-walk-rows.md#2-a-worker-is-isolated).

## 3. A fresh Anthropic account finishes a session

Its proof, steps, pass and fail are on
[the rows' page](gate-walk-rows.md#3-a-fresh-anthropic-account-finishes-a-session).

## 4. The seam on camera

Its proof, steps, pass and fail are on
[the rows' page](gate-walk-rows.md#4-the-seam-on-camera).

## 5. Rolled out once, and current

Its proof, steps, pass and fail are on
[the rows' page](gate-walk-rows.md#5-rolled-out-once-and-current).

## 6. Config set once for everyone

Its proof, steps, pass and fail are on
[the rows' page](gate-walk-rows.md#6-config-set-once-for-everyone).

## 7. The docs describe what ships

Its proof, steps, pass and fail are on
[the rows' page](gate-walk-rows.md#7-the-docs-describe-what-ships).

## 8. The board tells the truth

Its proof, steps, pass and fail are on
[the rows' page](gate-walk-rows.md#8-the-board-tells-the-truth).
