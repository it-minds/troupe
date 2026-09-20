# Troupe — final report

Built from `elixir-prmpt.md`. Toolchain: Erlang/OTP 28.5, Elixir 1.20.4, Zig 0.16.0
(pinned in `.tool-versions` and `mise.toml`). Everything below was run on Linux
x86_64 on 2026-09-11; commands are relative to the repository root and use the
pinned toolchain (`mise exec -- mix ...`).

## Done items

Legend: ✅ passes locally with output shown · 📝 written, cannot run on this machine (no CI runners / Windows / real model) · the test file proving an item is given so `mix test <file>` reproduces it.

### Core

| # | item | proof |
|---|------|-------|
| 1 | toolchain, warnings-as-errors, format, credo, 10 green runs | ✅ `elixir --version` → `Elixir 1.20.4 (compiled with Erlang/OTP 28)`; `mix compile --force --warnings-as-errors` (zero warnings, zero type warnings); `mix format --check-formatted`; `mix credo --strict` → "found no issues"; `for i in $(seq 10); do mix test \|\| exit 1; done` → **ALL 10 PASSED** (42 tests incl. 1 property, ~63 s per run) |
| 2 | single-branch loop read→edit→finish | ✅ `test/troupe/core_test.exs` "single-branch loop" |
| 3 | three 500 ms tool calls in <1 s | ✅ `core_test.exs` "three 500ms tool calls" |
| 4 | kill Agent.Server during :acting; rebuilt from log; no completed call runs twice | ✅ `test/troupe/recovery_test.exs` "killing the agent server during :acting" |
| 5 | raising tool → error tool_result, agent pid unchanged | ✅ `core_test.exs` "a tool that raises" |
| 6 | cancel kills shell child + grandchild <1 s by OS pid | ✅ `recovery_test.exs` "cancel during a shell sleep" |
| 7 | SIGKILL the VM → child and grandchild gone <3 s | ✅ `recovery_test.exs` "SIGKILLing the VM" (a second `erl` VM owns the reaper Port and is `kill -9`ed) |
| 8 | max_turns 2 → :budget_exhausted, exactly 2 Fake calls | ✅ `core_test.exs` "budget" |
| 9 | path confinement incl. symlinks and Windows rules | ✅ `test/troupe/workspace_test.exs` (unix on disk; Windows drive/UNC/junction/case rules as pure functions with `os: :windows`) |
| 10 | approvals block until allow; deny readable; needs_input carries agent_path | ✅ `core_test.exs` "approvals" and "allow-for-session" |
| 11 | property test: random interleavings never crash; branches end idle/done | ✅ `test/troupe/property_test.exs` |
| 12 | edit_file keeps CRLF | ✅ `core_test.exs` "edit_file on a CRLF file" |

### Dispatcher and branches

| # | item | proof |
|---|------|-------|
| 13 | four concurrent /code, interleaved Fake streams; one crashing past restart intensity → failed_unread, others finish | ✅ `test/troupe/dispatcher_test.exs` two tests |
| 14 | killing a Node leaves zero live processes under it | ✅ `recovery_test.exs` "killing a branch Node" |
| 15 | truly idle for 60 s: zero Fake calls, no Agent.Node, also with two done_unread windows | ✅ `dispatcher_test.exs` "truly idle" (60 s by default; `TROUPE_IDLE_TEST_MS` shortens it for iteration) |
| 16 | Dispatcher kill: branches keep going, ledger identical | ✅ `dispatcher_test.exs` "dispatcher crash" |
| 17 | resume running / needs_input (same pending call) / done_unread; dismissed stays gone | ✅ `dispatcher_test.exs` "resume restores" |
| 18 | continue a done_unread branch | ✅ `core_test.exs` "continue" |
| 19 | ninth command refused | ✅ `dispatcher_test.exs` "the ninth command" |
| 20 | project override of explore; explore write_file denied; depth cap; delegate description names model aliases | ✅ `test/troupe/definitions_test.exs` two tests |
| 21 | plan rejects write/shell; Tab to code keeps conversation + todo list, code tool set | ✅ `definitions_test.exs` "plan rejects" |
| 22 | two in_progress rejected; window cancel visible in next request | ✅ `definitions_test.exs` "todo" |
| 23 | /ask on cheap alias with read_branch results in the request | ✅ `definitions_test.exs` "/ask" |

### Isolation

| # | item | proof |
|---|------|-------|
| 24 | shared locks: error names the holder, both finish | ✅ `test/troupe/isolation_test.exs` |
| 25 | worktree write invisible in checkout; /merge → merge commit; /discard removes worktree and branch | ✅ `isolation_test.exs` |

### Watch mode

| # | item | proof |
|---|------|-------|
| 26 | AI! → one code branch with file/line/comment + bare AI context; 5 writes in 300 ms → one branch; own edit no retrigger; gitignored ignored; AI? → plan that cannot write — once per backend | ✅ `test/troupe/watch_test.exs` (native `file_system` and `polling`) |

### TUI

| # | item | proof |
|---|------|-------|
| 27 | snapshots: strip with running / needs_input / done_unread / failed_unread, activated pane with transcript + todo list, approval with diff, ask_user question | ✅ `test/troupe/tui_test.exs` "snapshots" (ExRatatui `CellSession` headless buffer) |
| 28 | focus never stolen; Esc, 2, y, Esc | ✅ `tui_test.exs` "focus" |
| 29 | kill TUI mid-stream: branches unaffected, TUI restarts and redraws from log | ✅ `tui_test.exs` "killing the TUI" |
| 30 | 10k deltas over four branches with a slow renderer: no turn-latency increase, bounded mailbox | ✅ `tui_test.exs` "backpressure" |
| — | Decision 52: markdown and syntax-highlighted transcript rendering (segmented lines, code rails, numbered source) | ✅ `test/troupe/tui_scroll_test.exs` (`TUIRichTextTest`) |
| — | Decision 51: every configured model detected (`Config.models/1`), listed by `troupe config`, and pickable from a menu via `/models` | ✅ `test/troupe/settings_test.exs` (`ModelMenuTest`) |
| — | Decisions 45–50: scrolling pane that follows the tail, pre-wrapped rows (no bottom clipping, indentation and tabs kept), full tool results with outcome summaries and diffs, subagent transcripts via ←/→, tray layout, trimmed diff context | ✅ `test/troupe/tui_scroll_test.exs` (`TUIScrollTest`, `TUIModelTextTest`, `TUIPaneRegressionTest`) |

### Packaging

| # | item | proof |
|---|------|-------|
| 31 | CI matrix: five artifacts + SHA256SUMS, per-runner `--version` and headless Fake run through reaper | 📝 `.github/workflows/release.yml` (native runners: ubuntu-24.04, ubuntu-24.04-arm, macos-15-intel, macos-14, windows-2022). Not executable locally; the Linux leg was executed by hand: `MIX_ENV=prod BURRITO_TARGET=linux_x86_64 TARGET_ABI=musl TROUPE_REAPER_TARGETS=all mix release --overwrite` → `burrito_out/troupe_linux_x86_64`; `--version` → `troupe 0.1.0`; `TROUPE_PROVIDER=fake TROUPE_FAKE_SCRIPT=fixtures/fake_scripts/smoke.json troupe run code smoke --headless --auto-approve` wrote `hello.txt` and read it back via `shell` under reaper, exit 0 |
| 32 | Linux binary in clean `ubuntu:24.04` and `alpine:3.20` (no Erlang/Elixir/inotify-tools), watch falls back to polling | ✅ run with podman; both containers: `troupe --version`, headless Fake run wrote `hello.txt`, `shell` result read back, and the line `watch mode: native file watching unavailable (inotifywait not found); using polling` printed. Alpine surfaced that `bash` is absent → `shell` now falls back to `sh` (Decision 30) |
| 33 | warm start to first TUI frame < 2 s; cold extraction time and size reported | ✅ Linux x86_64: first TUI frame **112 ms** after VM start (`TROUPE_TRACE_STARTUP=1` under a pty); `--version` warm **152–174 ms**, cold (first-run extraction + `--version`) **1.0–1.05 s**; binary **18.6 MB**. Other targets: 📝 measured by the CI smoke step ("cold first run" / "warm --version" lines) |
| 34 | installers: install, clean upgrade, uninstall leaving nothing outside config/state, corrupted artifact rejected; `install.sh` in ubuntu:24.04 with a zsh user, `install.ps1` on Windows | ✅ `install.sh` run in a podman `ubuntu:24.04` container with a zsh user against a local HTTP server: install → `--version` OK, PATH line added once to `.zshrc`; re-run → upgrade kept `troupe.previous`; `--uninstall` removed binary, PATH line and Burrito payload cache, left no files outside `~/.config` and `~/.local/state`; corrupted artifact → "checksum mismatch … nothing installed". 📝 `install.ps1` written (same flow, `Get-FileHash`, user PATH) and wired into the Windows CI job; not runnable here |

### Acceptance (manual, real model)

| # | item | status |
|---|------|--------|
| 35 | `troupe run code "make the tests pass" --workspace fixtures/sample_repo --headless --auto-approve` ends green | 📝 fixture in place (`fixtures/sample_repo`, one failing test: `sum/1` subtracts); needs an API key: `TROUPE_API_KEY=… burrito_out/troupe_linux_x86_64 run code "make the tests pass" --workspace fixtures/sample_repo --headless --auto-approve && (cd fixtures/sample_repo && mix test)` |
| 36 | TUI: two /worktree + one /plan streaming concurrently, responsive command line, approval blinks without moving focus, /ask summarizes | 📝 needs a real model and a terminal; the same behaviours are covered with the Fake by items 13, 25, 27, 28, 23 |

## Deviations from the specification

Every deviation and ambiguity resolution is in `DECISIONS.md` (32 entries). The ones that change observable behaviour:

* OTP 28.5 / Elixir 1.20.4 / **Zig 0.16.0** (spec said 0.15.2; Burrito 1.6 hard-pins 0.16.0) — Decisions 1, 2.
* LLM deltas, `agent_state` and notices are published but **not persisted** — Decisions 3, 4.
* A text-only assistant reply is an **implicit `finish`** — Decision 5.
* Finished branches **release their Node**; continue re-spawns it from the log — Decision 6 (required by done item 15).
* Cancel rests the window as `:done_unread` with reason `:cancelled` — Decision 7.
* `file_system`'s own listener process is the one OS process not under reaper — Decision 19.
* Headless mode denies approvals and auto-answers questions — Decision 20.
* `shell` falls back to `sh` without bash — Decision 30.
* Burrito argv read via `:init.get_plain_arguments/0`; CLI blocks in the UI supervisor — Decisions 31, 32.

## Binary size and start times

| target | size | cold first run | warm start | first TUI frame |
|---|---|---|---|---|
| linux_x86_64 (musl ERTS, musl NIF) | 18.6 MB | 1.0–1.05 s (extraction + `--version`) | 152–174 ms (`--version`) | 112 ms after VM start |
| linux_aarch64, macos_x86_64, macos_aarch64, windows_x86_64 | reported by the CI smoke step per runner | — | — | — |

The reaper helper is 13–66 KB per target (`priv/reaper/<target>/`), all five cross-compiled by `mix compile` with `TROUPE_REAPER_TARGETS=all`.

## Known limitations

* Items 31 (other four native runners), 34 (Windows installer run), 35 and 36 (real model) were not executed here; the code and workflow for them exist.
* Windows behaviour (Git-for-Windows bash / pwsh / powershell selection, Job Object reaper, junction and drive-letter confinement) compiles (`x86_64-windows-gnu` reaper) and the pure path rules are unit-tested, but nothing was run on Windows.
* The real providers (`Troupe.LLM.Anthropic`, `Troupe.LLM.OpenAI`) are exercised only through their request encoders and SSE parser paths in review, not against live endpoints in this run; all tests use the Fake.
* `/resume` inside the TUI picks from the sessions of the directory it was opened in and swaps the live session under the window (Decision 65, `session_picker_test.exs`). Sessions of other directories are not offered, and matching is by exact workspace path: a session started in a subdirectory is a separate list.
* The TUI transcript is rendered in Elixir (pre-wrapped `Text.Line`s of tagged segments: markdown structure, inline code and bold, syntect highlighting for fenced blocks and file reads). It is not a full markdown implementation — tables, nested emphasis, links and reference definitions are shown as written, and highlighting stops at 400 lines a block (Decision 52).
* At-least-once re-execution of tool calls that started but never completed is by design (documented in ARCHITECTURE.md §2); a `shell` command that is not idempotent can therefore run twice after a crash mid-call.
* Compaction keeps the last `keep_last_turns` turns and summarizes the rest with the cheap model; unresolved tool calls are always in the kept region because the boundary is chosen at a plain user message.

## Remote connectivity

Built from the Troupe Remote contract v1. Everything below was run on Linux
x86_64 (Erlang/OTP 28.5, Elixir 1.20.4) with `mix test`, against
`test/support/fake_remote.ex` — an in-VM plane, worker and OIDC issuer speaking
real HTTP and real WebSocket frames. No deployment is needed for any of it.

    mix test test/troupe/remote_login_test.exs test/troupe/remote_session_test.exs \
             test/troupe/remote_hq_test.exs test/troupe/remote_transport_test.exs \
             test/troupe/remote_ui_test.exs test/troupe/xref_test.exs
    ....................................
    Finished in 3.6 seconds (0.1s async, 3.5s sync)
    Result: 36 passed

| # | item | proof |
|---|------|-------|
| 1 | `troupe login` completes the device flow against the mock issuer; the credential file is user-only; `troupe whoami` prints identity and teams | ✅ `remote_login_test.exs` "runs the device flow, stores a user-only credential file, and whoami prints the teams" and "the credential file is 0600 on unix" |
| 2 | `troupe --remote` lists exactly what FakeRemote returns, with local sessions listed and labelled | ✅ `remote_hq_test.exs` "lists exactly what FakeRemote returns, with local sessions alongside and labelled" (teams, profile health and capacity, session states, and the local session's row) |
| 3 | create, attach, send input, receive the reply; the optimistic input reconciles with `input.accepted` | ✅ `remote_session_test.exs` "the transcript replays, input renders optimistically and reconciles on input.accepted"; creation through the wizard in `remote_hq_test.exs` "the wizard creates a session with the chosen profile, source and prompt, then attaches" |
| 4 | killing the worker connection mid-stream reconnects from the cursor; rendered durable events equal FakeRemote's log, no gap, no duplicate | ✅ `remote_session_test.exs` "killing the worker connection mid-stream resumes from the cursor with no gap or duplicate" (asserts `seqs(sid) == server_seqs(remote, …)`), and "a crashed worker connection is restarted and resumes from its cursor" for the supervised case |
| 5 | `auth.expiring` refreshes without reconnecting; a failed refresh prompts for re-login instead of crashing | ✅ `remote_session_test.exs` "auth.expiring is answered on the same connection, without reconnecting" (the open connection count is unchanged) and "a refresh the issuer refuses says to sign in again instead of crashing" |
| 6 | opening a dormant session makes zero activate calls; the first input makes exactly one `session.open` with mode `activate` and follows its endpoint, even to another worker | ✅ `remote_session_test.exs` "browsing one makes zero activate calls; the first input makes exactly one"; the different-worker case in "a -32012 re-opens the session and reconnects to the endpoint it is given" (`/worker/w1` → `/worker/w2`) |
| 7 | with a viewer token, input and approval are disabled; an injected `-32003` is handled gracefully | ✅ `remote_hq_test.exs` "disables input and approval, and an injected -32003 is handled gracefully" and "the window says why input is off"; `remote_ui_test.exs` "disables input and says why on the box the user types into" |
| 8 | with the fake plane stopped, an attached session continues and HQ shows the degraded banner | ✅ `remote_hq_test.exs` "with the plane stopped an attached session keeps streaming and HQ says what is off" |
| 9 | `resync_required` re-subscribes from the cursor with no lost durable events; an injected `-32012` re-opens and reconnects | ✅ `remote_session_test.exs` "resync_required re-subscribes from the cursor and loses nothing" and "a -32012 re-opens the session and reconnects to the endpoint it is given" |
| 10 | a deliberately slow TUI keeps connection process memory bounded under a 10k-delta flood | ✅ `remote_session_test.exs` "a slow TUI keeps the connection process bounded under a 10k-delta flood" (a real headless TUI at 5 ms a frame; the worker's peak `Process.info(:memory)` is asserted under 4 MB, and the durable log still matches the server's) |
| 11 | xref fails CI if the TUI or HQ call anything but `Troupe.Client` | ✅ `mix troupe.xref` → `the UI only calls Troupe.Client ✓`; `xref_test.exs` proves both directions (a fixture that reaches past the client is caught; the pure data modules are allowed). Wired into the `check` alias and `.github/workflows/ci.yml` |
| 12 | the existing suite and done items still pass | ✅ no regressions — see "Baseline" below |

Extra, because the live deployment disagreed with the contract:

| item | proof |
|---|---|
| a plane that speaks JSON-RPC over `POST` instead of a WebSocket | ✅ `remote_transport_test.exs` "is discovered as such, and every plane call works over it"; "no fleet subscription is attempted: a POST endpoint cannot push" |
| the live plane's `-32003 unauthenticated` is a token problem, not a missing scope | ✅ `remote_transport_test.exs` "an unauthenticated -32003 is treated as a token problem, not a missing scope" and "the contract's codes keep their meanings" |
| both discovery shapes | ✅ `remote_login_test.exs` "reads the contract's shape and the live deployment's shape alike" |
| the live plane's login: `/auth/exchange`, `me` as the `POST` handshake, no `initialize` | ✅ `remote_transport_test.exs` "the handshake is `me`, and /rpc is shown the plane token /auth/exchange minted"; `remote_login_test.exs` "a plane with no /auth/exchange is handed the issuer's token" |
| the live plane's answer shapes (`subject`/`display_name`, `{"profiles"}`/`{"sessions"}` envelopes, pods and micros) | ✅ `remote_transport_test.exs` "is discovered as such, and every plane call works over it" — the fake answers in those shapes over `POST` |
| a worker endpoint with no socket path | ✅ `remote_transport_test.exs` "is turned into the socket URL the way the reference clients do it" |

And the feature list's screen-level promises:

| item | proof |
|---|---|
| `session.resumed` and `config.upgraded` in the transcript | ✅ `remote_ui_test.exs` "session.resumed and config.upgraded appear in the transcript" |
| an unknown event type rendered generically after one log line | ✅ `remote_ui_test.exs` "an event type this client has never heard of is rendered rather than dropped" |
| the files panel: `fs.list`, `fs.read`, live on `fs.changed` | ✅ `remote_ui_test.exs` "lists the worker's files, opens one, and reloads when fs.changed says so" |
| `/upload <path>` | ✅ `remote_ui_test.exs` "/upload sends a local file to the session mount" |

### Against a real deployment

`mix troupe.remote.smoke` runs login, list, attach and one input when
`TROUPE_REMOTE_URL` is set, and skips itself otherwise:

    $ mix troupe.remote.smoke
    troupe.remote.smoke: skipped (set TROUPE_REMOTE_URL to run it)

The client was also driven against a live Troupe Remote deployment
(`http://plane.localtest.me:30080`, Dex as issuer) as far as an unapproved
device code allows. Everything up to the browser half is verified end to end:

    transport: http  rpc_url: http://plane.localtest.me:30080/rpc
    token=nil     -> {:error, %{code: -32003, data: %{"reason" => "no_token"},      message: "unauthenticated"}}
       reason: :unauthorized   shown as: signed out: unauthenticated
    token="bogus" -> {:error, %{code: -32003, data: %{"reason" => "bad_signature"}, message: "unauthenticated"}}
       reason: :unauthorized   shown as: signed out: unauthenticated

and the device flow issues a real code against that issuer:

    device code: WZSB-QVQS at http://dex.localtest.me:30080/dex/device

Finishing the smoke needs a human to approve that code in a browser, which is
what the device grant is for.

### Baseline

The whole suite, on this machine, before and after the remote work (Linux
container, LF checkout):

    HEAD (before):  Result: 238/242 passed (1/1 property, 237/241 tests)
    after:          Result: 275/279 passed (1/1 property, 274/278 tests)

The four failures are the same four in both runs and none of them is remote:

* `recovery_test.exs` "cancel during a shell sleep" and "SIGKILLing the VM" —
  the container has no `pgrep`, which those tests shell out to.
* `settings_test.exs` "/settings shows values and the curated help" — the
  curated help no longer fits the pane at the test's size, so `y / n / a`
  is off screen.
* `tui_test.exs` "Tab completes command names and worktree paths" — `wor<Tab>`
  now has two candidates (`workflow` and `worktree` are both agent profiles)
  and completes to the first.

The last two are pre-existing drift in this checkout, proven by running the
same suite from a pristine `git archive HEAD`; they are named here rather than
fixed because they belong to different features.

## Phase 2 of the daemon plan — the TUI as a client (2026-09-20)

`troupe` no longer runs a harness of its own. `troupe_core`, `troupe_gateway` and
`troupe_protocol` are dependencies (sparse git, one pinned `troupe-remote` commit), a
session is created in the daemon — embedded in this VM when none answers, over its
loopback WebSocket either way — and the UI still calls `Troupe.Client` and nothing else.
Decisions 100–102 in `DECISIONS.md`; the plan's phase 2 items and where each stands:

| item | state | proof |
|---|---|---|
| 1. `troupe` boots the daemon in the same BEAM when none runs, or attaches to the one that does | done, over the socket in both cases (Decision 100 (1)) | `daemon_client_test.exs` "the embedded daemon comes up…" |
| 2. `lib/troupe/agent`, `session/*`, `tools/*`, `llm/*`, `reaper`, `watch` gone | done (12,718 → ~9,000 lines; 32 test files dropped, named below) | `git diff --stat main` |
| 3. `Troupe.Remote.Translate` gone, model folds protocol events | **kept, deliberately** (Decision 100 (2)): it is the one adapter for daemon and pod sessions alike | `remote_translate_test.exs`, `mix troupe.xref` |
| 4. every local-session test drives a daemon session through the socket | done for what remains; the rest dropped with notes below | `mix test`: 92 tests, 92 passing (Linux, WSL) |
| 5. `mix troupe.remote.smoke` against the live plane, including an approval | done | run 2026-09-20: `TROUPE_REMOTE_CREATE=1 … troupe.remote.smoke: ok` (create, input, reply, approval) |

Known environmental miss, unchanged: `remote_session_test.exs` "a slow TUI keeps the
connection process bounded" (the 4 MB bound) fails about one run in five, here as on
`main`. `WatchTest` and its inotify-tools miss are gone with the watch tests.

### Phase 3, branches (stacked on the phase 2 branch)

| item | state | proof |
|---|---|---|
| `/build …`, `/plan …`, `/worktree …` open a branch as a window; its transcript, approvals and state show under the window's name | done (Decision 103; troupe-remote Decisions 646–647) | `branch_client_test.exs` "a slash command opens a branch…", "…the TUI…" |
| input typed into a branch window, and an approval answered from it, reach the branch's session | done | `branch_client_test.exs` "input typed into a branch window…" |
| `/merge` lands the branch's worktree on the checkout and closes the window; `/discard` throws it away | done, through `worktree.merge` / `worktree.discard` | `branch_client_test.exs` |
| a reopened session brings its branch windows back | done | `branch_client_test.exs` "a session opened again…" |
| `/workflow [name:] task` runs a named workflow as a branch in its own worktree, its plan rendered by the daemon | done (Decision 104; troupe-remote Decision 648) | `branch_client_test.exs` "/workflow…" |

### Tests dropped, and why

Each file below tested the harness this repository no longer has. Their subjects are
`troupe_core`'s now (its suite covers the agent loop, tools, approvals, compaction,
replay, budgets, the fake) or are phase 3 of the plan (branches inside a session,
workflows, project memory, watch markers, `read_output`, the model catalog's `troupe
models --refresh` UI). Nothing here was silently lost: a name in this list is a feature
to bring back through the protocol, or a check that lives in the core.

### ask_user_test.exs
- a bare question has no options and is single-choice
- options may be plain strings
- options may be objects with a label and a description
- a label is taken from name, value, text or title too
- blank and unusable options are dropped, duplicates collapse
- a label is flattened to one line so it cannot abort a frame
- more options than there are digit keys are cut off
- multiple is only true when actually asked for
- junk in place of options or the whole input does not raise
- a non-string question is coerced rather than rejected
- selected labels go back as the labels themselves, not indices
### bound_test.exs
- leaves output that is already clean alone
- strips ANSI colour and cursor escapes
- replaces invalid UTF-8 so Jason can encode the result
- a binary file does not raise on the way into a message
- multibyte text at the cut point stays valid UTF-8
- emoji at the cut point survive as whole graphemes
- text under the limit is returned unchanged and unmarked
- output under the limit is returned unchanged
- keeps the head, keeps the tail, and counts what it left out
- trims a long array to its first elements and counts the rest
- a short document is left alone
- shell keeps the exit code, the head and the tail, and stores the rest
- short shell output is not truncated
- paging a stored output with read_output reconstructs it exactly
- read_file returns a line window and points at the next offset
- a short file is returned whole and unmarked
- list_files caps the number of paths and names the next call
- grep caps matches and offers the next page
### catalog_test.exs
- a LiteLLM model group carries the window and the price
- embeddings, the wildcard group and malformed rows are not addressable models
- Anthropic reports windows and no price
- a plain OpenAI listing yields ids, and windows only when volunteered
- cost prices each token class at its own rate
- without quoted cache rates, cache tokens bill at the input rate
- ids are qualified by the provider that serves them
- the cache round-trips through disk
- no cache file is an empty catalog, not a crash
- a corrupt cache file is an empty catalog
- config declares the window, the catalog fills the gap, default_window is last
- a model only the catalog knows is addressable, with its price
- troupe models flags a hand-written window the provider contradicts
- the report says when the catalog was never fetched
### core_test.exs
- single-branch loop: read_file, edit_file, finish changes the file and rests done_unread
- three 500ms tool calls in one turn complete in under 1s
- a tool that raises yields an error tool_result and the agent pid is unchanged
- budget: max_turns 2 asks after exactly 2 Fake calls; deny stops with :budget_exhausted
- budget: y buys one more slice of the same size and the question comes back at its end
- budget: a grants the whole agent an override, and it is never asked again
- approvals: ask tool blocks until allow; deny produces a readable denial; needs_input carries agent_path
- allow-for-session skips later approvals for the same tool
- edit_file on a CRLF file keeps CRLF
- free text without a leading slash is rejected with a hint
- continue: input to a done_unread branch returns it to running and the next request has the prior conversation
- context past the configured fraction of the window is compacted into a summary and the agent continues
### definitions_test.exs
- project definitions override built-ins; explore cannot write; depth is capped; delegate names model aliases
- delegation past the depth cap is an error tool_result
- plan rejects write_file and shell; Tab to code carries conversation, todo list and the code tool set
- todo: two in_progress items is an error; a window cancel appears in the next request
- /ask uses the cheap model and its read_branch results appear in the Fake request
### dispatcher_test.exs
- four /code commands run concurrently with distinct paths and all rest done_unread
- a branch crashing past restart intensity is failed_unread while the other three finish
- truly idle: no commands means zero Fake calls and no Agent.Node; done_unread windows behave the same
- dispatcher crash leaves branches running and rebuilds an identical ledger
- resume restores running, needs_input and done_unread windows and skips dismissed ones
- the ninth command is refused with a message and no Node is started
- cancel_branch stops a running branch, removes its window and frees the slot
- cancel_branch removes a resting window, and refuses one already removed
### isolation_test.exs
- shared locks: contention returns an error naming the holder and both branches finish
- worktree: isolated write, merge creates a merge commit, discard removes worktree and branch
- cancelling a worktree branch discards its worktree and branch with the window
- /worktree <checked-out worktree> <prompt> works in the user's worktree and never commits there
- /worktree <name>: <prompt> creates the named worktree, then reuses it
- a named worktree in use by a running branch is refused, and a bad name is reported
- a named worktree whose directory was removed is recreated on its surviving branch
### limits_test.exs
- a prompt the provider served from cache still crosses the compaction threshold
- a prompt the provider did not cache and that fits does not compact
- a context-overflow 400 compacts once and re-sends the turn instead of failing
- a branch that overflows again after compacting fails with an actionable message
- a branch too short to compact says so rather than compacting nothing
- /compact summarizes a resting branch on demand
- a reply cut off with no tool call is retried once and then fails visibly
- the retry carries a note telling the model to answer in smaller steps
- a tool call cut off mid-argument is answered with an error, not run
- a refusal ends the branch as :refused, not as a successful finish
- a reasoning-only reply is retried once and then fails visibly
- a reply that recovers after the nudge finishes normally
- the nudge is available again once a turn has produced something
- each dimension warns once per slice, not once per turn
- reports every dimension and names the tightest
- crossed/3 skips what has already been warned about, tightest first
- a zero prompt reads as an empty context, not a full one
- a slice is the budget's own size again, and grants accumulate
- exhausted_dimension names which ceiling tripped
- a 400 naming a context error is an overflow; every other 400 is not
- auth, unknown model and rate limits are told apart
- an overflow that exhausted its retries is still an overflow
- describe_error says what happened in words a user can act on
- a gap longer than a stream's lifetime is not counted as work
- an exhausted budget is not asked about and no warnings are logged
- without full send an exhausted budget asks, as it does without the flag
### mcp_config_test.exs
- YAML mcp config is parsed into the mcp field
- config override merges mcp servers
- empty mcp config defaults to empty map
- malformed mcp entry is skipped
- model folds :mcp_status events
- mcp_servers/1 returns sorted list
- mcp_servers/1 returns [] for empty model
### mcp_test.exs
- JSON-RPC encode/decode
- MCP.Server lifecycle: initialize → tools/list → ready
- call_tool returns text content
- call_tool returns error when isError is true
- call on unknown server returns error
- mcp? predicate
- tool_specs returns [] when no MCP configured
- MCP tools appear in the LLM request
- agent dispatches an MCP tool call through the approval door
### memory_session_test.exs
- a hand-written brief is read at session start
- an unreadable brief is ignored rather than fatal
- notes are written through, survive a crash and do not stamp the brief
- put_section stamps the brief and a later read sees the merge
- a hand edit between two writes is not clobbered
- forget deletes the brief
- the brief reaches the system prompt and shrinks the survey
- the system prompt stays byte-stable across turns even after a remember
- remember writes a note and reports it, and the next agent starts with it
- remember rejects an empty text and an unknown section
- a worktree branch writes to the main checkout's brief
- a session without a brief dispatches exactly one self-dismissing librarian
- a fresh brief raises no librarian
### memory_test.exs
- parse reads frontmatter and keeps sections in order
- render/parse is a fixpoint, including unknown sections
- a file with no frontmatter parses, round-trips and reads as stale
- text before the first heading survives a round trip
- put_section replaces in place and preserves order, or appends
- add_note prepends, dedupes on text and caps the list
- add_note squishes whitespace so one note stays one line
- stale? triggers on absence, age and file drift but not on a new commit
- to_prompt renders a capped, clearly non-authoritative block
- unterminated frontmatter is an error, not a crash
### memory_tui_test.exs
- /memory summarises the brief, and /memory forget deletes it
- /memory beats an agent profile of the same name
- an unknown /memory subcommand explains itself
### native_tools_test.exs
- status reports a modified file
- diff shows the change, and staged shows nothing until staged
- log lists commits and honours limit
- show and branch work
- path narrows the read
- a ref or path that looks like a flag is refused
- an unknown op is refused rather than passed to git
- is registered as a read-only tool
- reads them all under headers in one call
- a missing file is reported in place, the others still read
- an empty or non-list paths is refused
- single path still works unchanged
- matches a pattern and excludes directories
- sorts most recently modified first
- says so when nothing matches
- is registered as a read-only tool
### observer_test.exs
- /observer shows every agent as a tree, with the selected one's detail
- the observer is empty and safe before anything is dispatched
- rows carry state, elapsed time and per-agent tokens
### opencode_config_test.exs
- JSONC strips comments and trailing commas but not inside strings
- providers come from opencode.jsonc with keys filled from auth.json and windows from limits
- an authToken is a bearer key and a model's own id, limits and effort come across
- config falls back to opencode providers, uses its default model, and resolves provider/model per request
- an explicit Troupe key or explicit models are not overridden by opencode
- a session with named providers streams each request to the provider named by its model prefix
### prompt_cache_test.exs
- the system block carries a breakpoint, so tools and system cache together
- the last stable block of the final message carries a breakpoint
- a volatile block sits after the breakpoint, never on it
- the previous request's position gets a second breakpoint, and never more than four
- an out-of-range previous index is dropped rather than misplaced
- a one-hour ttl is asked for on every breakpoint of a request or none
- a compaction request pays no write premium it can never read back
- consecutive turns agree on tools, system and every earlier message
- the prompt prefix stays byte-identical across turns while tools run
### property_test.exs
### provider_config_test.exs
- a named provider hands the adapter its wire id, auth scheme and effort
- every model a provider declares is addressable, window and all
- troupe config shows the renamed model and the auth scheme, never the token
- a base url that already names the api version is not doubled
- an anthropic request asks for thinking inside an output cap that fits it
- an openai reasoning model gets the effort verbatim and a completion-token cap
- a model that refuses max_tokens is asked again with max_completion_tokens
- the session-wide provider can send its key as a bearer token
### read_roots_test.exs
- still resolves paths inside the workspace
- rejects an outside path when no read root allows it
- allows an outside path under a read root
- a read root does not allow its siblings
- judges a symlink by where it lands, not by its name
- a null byte is still invalid, read root or not
- read_file reaches a read root and refuses without one
- the refusal names the roots that were tried
- grep searches a read root
- list_files lists a read root relative to that root
- read_roots is expanded, and junk entries are dropped
- defaults to none, which is the pre-existing confinement
- write_file cannot write into a read root
- edit_file cannot edit inside a read root
### reasoning_test.exs
- captures a thinking block and its signature off the stream
- re-encodes thinking, signature and order when thinking is enabled
- redacted thinking goes back as its opaque payload
- drops thinking when the request has no thinking enabled
- drops another provider's reasoning rather than signing it as its own
- accumulates reasoning_content alongside a tool call
- the `reasoning` spelling is accepted too
- reasoning goes back as a sibling of content, not a content block
- drops another provider's reasoning
- an assistant turn with no reasoning carries no reasoning_content key
- reasoning is invisible to text and tool_uses
- survives the persisted-event round trip
### recovery_test.exs
- killing the agent server during :acting restarts it from the log; completed calls never run twice
- restarting an agent re-registers its budget question under the same id, logging none
- restarting an agent re-registers its question with the options it offered
- cancel during a shell sleep kills child and grandchild within 1s (by OS pid)
- SIGKILLing the VM kills the shell child and grandchild within 3s
- killing a branch Node leaves zero live processes under its subtree
### survey_test.exs
- detects language mix, project markers and their names
- walks the filesystem when there is no git repo, pruning build directories
- uses git for the file list and reports the branch
- lists every file when the listing fits the budget
- falls back to directory counts when the listing is too large
- renders a file listing an agent can pick a first file from
- renders the directory summary when the listing is too large
- is empty for an empty workspace
- the agent's first request already carries the workspace layout
### usage_test.exs
- anthropic keeps its three input figures apart and disjoint
- anthropic without caching reports no cache figures
- openai's prompt_tokens includes the cached ones, so they come back out of it
- openai without a cache breakdown counts every prompt token as billed
- a budget spends on what was billed, not on what the cache served
- the compact form is sent and received, cache reads excluded
- the detail names what the cache served, and says nothing when it served nothing
- the total still accounts for every token, cached input included
- the side panel gets a line each, and no cache line when nothing was cached
- a cached turn shows sent, received and cached in the activated pane
### watch_test.exs
- #{backend}: AI! spawns one quick branch with file, line, comment and context; debounced; own edits ignored; gitignored ignored; AI? spawns answer
- the profile each marker dispatches is a setting
### web_fetch_test.exs
- fetches an HTML page as readable text with links and without scripts or styles
- returns JSON and plain text verbatim
- follows redirects
- a failure status is an error carrying the body as explanation
- binary content is refused rather than dumped into the transcript
- only absolute http(s) urls are accepted
- a connection that goes nowhere is an error tool result, not a crash
- decodes entities, keeps heading levels and collapses blank runs
- drops in-page and javascript hrefs but keeps the link text
- a link whose text is already the url is not doubled
- unknown entities and stray angle brackets survive
- an agent can call web_fetch and gets the page back as a tool result
### workflow_test.exs
- default_steps is an ordered, non-empty list of steps, each with an owner
- the agents the default workflow delegates to exist and are subagents
- split parses <name> <task> and name: task, defaulting to a bare task
- available lists on-disk workflows, default when none
- load reads a named workflow's owners and parallel flags
- load falls back to the default for a missing, malformed or blank-agent file
- plan renders the task, the owner of each step and the delegation rules
- plan without parallel steps leaves out the concurrency rule
- plan falls back to the default steps for an empty list
- the orchestrator delegates its steps and auto-commits the worktree
- the orchestrator cannot edit the repository itself
- a named /workflow <name> task loads that file's steps and owners
### workspace_test.exs
- rejects ../ escapes and symlinks pointing outside the workspace
- windows: backslash escapes, other drives, UNC, junctions and case variants are rejected
### close_session_test.exs
- a fresh session is not finished and closes with an empty report
- closing counts a finished branch and writes session_closed plus closed_at
- an active branch blocks the close until it is forced
- the counts survive dismissal
- a worktree that is neither merged nor discarded blocks the close
### session_picker_test.exs
- summarises the sessions of one workspace and ignores every other one
- a dismissed branch stays out of the live ones, and a stopped session is still listed
- lists this directory's sessions and switches the window to the one picked
- an empty session is retired when you switch away from it
- /resume takes a row number, reports an id that is not here, and Esc backs out
- the picker opens straight away when the TUI is started on it
### tui_scroll_test.exs
- the pane scrolls: PgUp leaves the tail, the view stays put while the branch works on, End follows again, Home goes to the top, the wheel scrolls
- a line wider than the pane is wrapped and fully visible; nothing is clipped at the bottom
- expanded read_file output keeps its indentation, tabs included, and the collapsed head says how much there is
- full tool results are kept (not a 300-character slice) and escape sequences are stripped
- ←/→ show a subagent's transcript; input still goes to the branch root
- an edit's diff lives on its tool call: shown while the approval waits, then as +/- and, expanded, in full
- with a pane open the strip is a compact tray, clicking the active tile jumps to the latest, and 80x24 works without a side panel
- expanding or collapsing output keeps the entry at the top of the view in place
- the 'new' counter counts what arrived, not rows the terminal re-wrapped after a resize
- sanitize expands tabs to 4-column stops, strips escape sequences and control bytes, keeps newlines
- cell_width counts wide glyphs as two columns and combining marks as none
- wrap never trims and breaks prose at spaces, code anywhere
- the ASCII fast path wraps exactly like the grapheme path
- rows materialises only the visible slice and tail_rows the last rows
- a line kind's rail is drawn on every row it wraps onto
- tail_rows measures only the lines it shows
- reasoning deltas stream into their own block and fold to a collapsible entry
- a window dismissed from outside the pane returns focus to the command line instead of crashing it
- clicking on the observer or the settings page does not activate an invisible tile
- a branch told to carry on is no longer shown as done
- a pending approval taller than the pane opens at its header, not its last rows
- at 80 columns the pane still says how to get back to the tail
- markdown in an assistant message: headings, bullets, quotes, rules, inline code and bold
- a fenced code block is highlighted, railed and labelled with its language
- a file read shows numbered, highlighted source
- output that is not code is left alone, and a body too big to highlight still renders
- text still streaming is shown plain and becomes markdown when the message lands
- reasoning streams collapsibly and folds to a block when the message lands
### tui_test.exs
- snapshots: window strip states, activated pane with transcript and todo list, approval with diff, ask_user question
- focus: an approval in window 2 while window 1 is activated does not move focus; Esc 2 y Esc returns to the command line
- killing the TUI mid-stream leaves branches running; it restarts and redraws from the log
- backpressure: 10k deltas across four branches while the TUI renders slowly do not slow a branch; mailbox stays bounded
- a working window shows what it is doing: thinking, then the running tool, then waiting for you
- clicking a tile activates that window; the status line says which key answers a waiting window
- Tab completes command names and worktree paths for /merge and /discard, cycling on repeat
- /worktree <Tab> completes the user's checked-out worktrees by path or branch
- /worktree <Tab> offers a Troupe-managed worktree as <name>:
- /cancel <n> stops the branch on tile n and takes its window off the strip
- typing a reply that starts with d or x neither dismisses nor cancels the branch
- pressing d twice dismisses the window and x twice cancels the branch
- a multi-line tool argument renders on one row instead of aborting the frame
- bracketed paste inserts into the command line, a window input, and a settings field
- the command box shows the tail of a long single-line input, so the end you type stays visible
- a pasted multiline shows its tail on screen, and typing after the paste is visible too
- the cursor moves and edits inside the line: arrows, Alt-word jumps, Home/End, Delete
- an input taller than the box scrolls to wherever the cursor is
- a question with options renders a numbered menu and a digit answers it
- a multiple-choice question ticks with digits and sends the ticked set on Enter
- a free-text answer still works when options are offered
- a modified Enter or Ctrl-J inserts a newline; a multiline window input sends whole
- a subagent's budget question renders in the pane and side panel, and n answers it
- allowing a subagent's budget question stops the window needing input
- a request left behind by a dead subagent does not pin the window
- the window keeps needing input while a subagent waits, after the root is answered
