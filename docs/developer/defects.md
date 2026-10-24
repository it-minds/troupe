# Known defects

Defects found in passing, while working on something else, and not fixed yet. Each has a
place in the code, what goes wrong and who saw it. This page lists every one still open;
the entries themselves are on the pages under `defects/`, by number, a few hundred lines
each. Every entry but D8 (the flaky tests, which have their own pass) was checked against
the code of 0.15.0 on 2026-10-12 (#422): what was fixed went to the
[closed defects](../history/defects-closed.md), and what was said twice is said once.

Fixers following [fixing-issues.md](fixing-issues.md) add their `noticed` defects: a new
entry goes at the end of the [last page](defects/d130.md), under the next number, with a
row in the table below. Stale docs and style nits are not defects and do not belong here.

**How an entry is written, and how it leaves.** An entry is a heading,
`### D<n> - <what> (<severity>)`, then one item for each thing still wrong, a line that
starts `- `, then who found it. A fixer who fixes an item, or whose issue or pull request
takes it, deletes the item, and the entry's last line says which one took it. An entry with
no item left is closed: it leaves its page and this table, and a line for it goes to the
[closed defects](../history/defects-closed.md), under **Taken**, **Won't fix** or
**Checked and not a defect**, with the reason. `elixir scripts/doc-size.exs`, which CI
runs, fails on an entry with no item, on a row here with no entry or an entry with no
row, and on a page past 400 lines; a full page is closed and the next one,
`defects/d<its first number>.md`, started.

| Severity | Meaning |
| --- | --- |
| **high** | data exposure, data loss, or a user-facing failure with no workaround |
| **medium** | wrong behaviour with a workaround, or a failure only some setups hit |
| **low** | noise, hygiene, or a trap for the next developer |
| **unconfirmed** | read in the code, not reproduced; the entry says what would confirm it |

## Open
| Defect | What | Severity |
| --- | --- | --- |
| [D8](defects/d008.md#d8---test-hygiene-low) | Test hygiene | low |
| [D23](defects/d008.md#d23---small-leftovers-low) | Small leftovers | low |
| [D26](defects/d008.md#d26---small-state-leftovers-in-the-gui-a2a-and-headless-runs-low) | Small state leftovers in the GUI, A2A and headless runs | low |
| [D30](defects/d008.md#d30---two-sources-for-the-brands-assets-low) | Two sources for the brand's assets | low |
| [D32](defects/d008.md#d32---small-leftovers-from-the-060-work-low) | Small leftovers from the 0.6.0 work | low |
| [D36](defects/d008.md#d36---tui-leftovers-after-the-attention-fix-low) | TUI leftovers after the attention fix | low |
| [D37](defects/d008.md#d37---small-leftovers-from-the-061-work-low) | Small leftovers from the 0.6.1 work | low |
| [D40](defects/d008.md#d40---the-planes-drains-medium) | The plane's drains | medium |
| [D41](defects/d008.md#d41---a-click-in-windows-notification-centre-unconfirmed) | A click in Windows' notification centre | unconfirmed |
| [D43](defects/d008.md#d43---small-leftovers-from-the-063-work-low) | Small leftovers from the 0.6.3 work | low |
| [D45](defects/d008.md#d45---small-leftovers-from-the-070-work-low) | Small leftovers from the 0.7.0 work | low |
| [D48](defects/d008.md#d48---a-dormant-session-whose-log-its-root-cant-replay-can-never-be-woken-medium) | A dormant session whose log its root can't replay can never be woken | medium |
| [D49](defects/d008.md#d49---small-leftovers-from-the-071-work-low) | Small leftovers from the 0.7.1 work | low |
| [D50](defects/d008.md#d50---a-persons-servers-offered-to-a-pod-session-the-rough-edges-medium) | A person's servers offered to a pod session: the rough edges | medium |
| [D51](defects/d008.md#d51---mcp-sessions-a-caller-leaves-open-low) | MCP sessions a caller leaves open | low |
| [D53](defects/d008.md#d53---small-leftovers-from-the-072-work-low) | Small leftovers from the 0.7.2 work | low |
| [D54](defects/d008.md#d54---what-a-worker-may-reach-the-edges-left-after-268-medium) | What a worker may reach: the edges left after #268 | medium |
| [D56](defects/d008.md#d56---scim-and-the-subject-claim-small-leftovers-low) | SCIM and the subject claim: small leftovers | low |
| [D57](defects/d008.md#d57---scim-what-is-left-after-356-low) | SCIM: what is left after #356 | low |
| [D58](defects/d008.md#d58---the-desktop-app-and-a-failed-turn-what-354-left-low) | The desktop app and a failed turn: what #354 left | low |
| [D59](defects/d008.md#d59---private-sessions-and-mcp-sessions-small-leftovers-of-074-low) | Private sessions and MCP sessions: small leftovers of 0.7.4 | low |
| [D62](defects/d008.md#d62---start-at-login-small-leftovers-low) | Start at login: small leftovers | low |
| [D63](defects/d063.md#d63---shared-settings-and-user-commands-small-leftovers-low) | Shared settings and user commands: small leftovers | low |
| [D64](defects/d063.md#d64---small-leftovers-from-the-081-work-low) | Small leftovers from the 0.8.1 work | low |
| [D65](defects/d063.md#d65---what-a-turn-costs-what-389-left-medium) | What a turn costs: what #389 left | medium |
| [D67](defects/d063.md#d67---model-discovery-what-410-left-low) | Model discovery: what #410 left | low |
| [D68](defects/d063.md#d68---small-leftovers-from-the-082-work-low) | Small leftovers from the 0.8.2 work | low |
| [D69](defects/d063.md#d69---anthropic-thinking-what-396-left-low) | Anthropic thinking: what #396 left | low |
| [D70](defects/d063.md#d70---the-live-bench-and-the-model-list-small-leftovers-low) | The live bench and the model list: small leftovers | low |
| [D71](defects/d063.md#d71---private-sessions-after-084-what-is-left-medium) | Private sessions after 0.8.4: what is left | medium |
| [D72](defects/d063.md#d72---model-calls-naming-troupe-and-what-a-stopped-call-leaves-small-leftovers-low) | Model calls, naming Troupe, and what a stopped call leaves: small leftovers | low |
| [D73](defects/d063.md#d73---test-hygiene-from-the-084-work-low) | Test hygiene from the 0.8.4 work | low |
| [D74](defects/d063.md#d74---model-calls-what-the-085-work-left-low) | Model calls: what the 0.8.5 work left | low |
| [D75](defects/d063.md#d75---decision-files-small-leftovers-low) | Decision files: small leftovers | low |
| [D78](defects/d063.md#d78---instruction-files-and-the-brief-what-123s-slice-left-low) | Instruction files and the brief: what #123's slice left | low |
| [D80](defects/d063.md#d80---small-leftovers-from-the-086-work-low) | Small leftovers from the 0.8.6 work | low |
| [D81](defects/d063.md#d81---ci-after-the-move-to-ubuntu-26-low) | CI after the move to Ubuntu 26 | low |
| [D82](defects/d063.md#d82---thinking-on-anthropics-newest-models-what-427-left-low) | Thinking on Anthropic's newest models: what #427 left | low |
| [D83](defects/d063.md#d83---the-plane-hosts-policy-what-460-left-low) | The plane host's policy: what #460 left | low |
| [D84](defects/d063.md#d84---erasures-and-the-daemons-start-small-leftovers-of-087-low) | Erasures and the daemon's start: small leftovers of 0.8.7 | low |
| [D85](defects/d063.md#d85---instruction-files-and-cursor-rules-what-the-090-slices-of-123-left-low) | Instruction files and Cursor rules: what the 0.9.0 slices of #123 left | low |
| [D86](defects/d063.md#d86---the-tuis-themes-and-mark-small-leftovers-low) | The TUI's themes and mark: small leftovers | low |
| [D87](defects/d063.md#d87---the-vs-code-extension-after-378s-commands-low) | The VS Code extension after #378's commands | low |
| [D88](defects/d063.md#d88---erasure-after-470-small-leftovers-low) | Erasure after #470: small leftovers | low |
| [D89](defects/d063.md#d89---shell-mode-and-tool-output-after-486-and-493-low) | Shell mode and tool output after #486 and #493 | low |
| [D90](defects/d090.md#d90---sessions-after-new-and-troupe-resume-484-low) | Sessions after `/new` and `troupe resume` (#484) | low |
| [D91](defects/d090.md#d91---repository-commands-after-371-low) | Repository commands after #371 | low |
| [D92](defects/d090.md#d92---thinking-blocks-and-the-prompt-prefix-what-465s-measurement-found-medium) | Thinking blocks and the prompt prefix, what #465's measurement found | medium |
| [D94](defects/d090.md#d94---the-installers-after-the-start-at-login-step-504-low) | The installers after the start-at-login step (#504) | low |
| [D95](defects/d090.md#d95---setup-after-troupe-setup-513-low) | Setup after `troupe setup` (#513) | low |
| [D96](defects/d090.md#d96---troupe-doctor---bench-and-the-offline-bench-505-low) | `troupe doctor --bench` and the offline bench (#505) | low |
| [D97](defects/d090.md#d97---mcp-servers-after-headers-507-low) | MCP servers after `headers` (#507) | low |
| [D98](defects/d090.md#d98---onboarding-after-516s-first-slices-low) | Onboarding after #516's first slices | low |
| [D100](defects/d090.md#d100---mcp-import-after-520-low) | MCP import after #520 | low |
| [D101](defects/d090.md#d101---pods-and-worktrees-after-523-low) | Pods and worktrees after #523 | low |
| [D102](defects/d090.md#d102---onboarding-after-516s-second-half-low) | Onboarding after #516's second half | low |
| [D103](defects/d090.md#d103---trust-confinement-and-mcp-after-531-and-532-low) | Trust, confinement and MCP after #531 and #532 | low |
| [D104](defects/d090.md#d104---processes-the-sandbox-and-git-after-535-537-and-540-low) | Processes, the sandbox and git after #535, #537 and #540 | low |
| [D107](defects/d090.md#d107---commands-from-an-activated-window-and-the-palettes-rows-low) | Commands from an activated window, and the palette's rows | low |
| [D110](defects/d090.md#d110---the-start-up-flow-after-546-544-and-550-low) | The start-up flow after #546, #544 and #550 | low |
| [D111](defects/d090.md#d111---repository-memory-after-553-and-557-low) | Repository memory after #553 and #557 | low |
| [D112](defects/d090.md#d112---agents-after-549-551-and-563-low) | Agents after #549, #551 and #563 | low |
| [D113](defects/d090.md#d113---command-mode-and-branches-after-556-and-560-low) | Command mode and branches after #556 and #560 | low |
| [D114](defects/d090.md#d114---watch-after-558-low) | Watch after #558 | low |
| [D115](defects/d090.md#d115---windows-processes-and-connections-after-552-and-562-low) | Windows processes and connections after #552 and #562 | low |
| [D116](defects/d090.md#d116---a-shell-calls-outcome-after-545-low) | A shell call's outcome after #545 | low |
| [D118](defects/d090.md#d118---delegation-after-567-572-and-575-low) | Delegation after #567, #572 and #575 | low |
| [D119](defects/d090.md#d119---sessions-and-state-directories-after-568-and-576-low) | Sessions and state directories after #568 and #576 | low |
| [D120](defects/d090.md#d120---command-mode-agents-and-watch-after-570-and-571-low) | Command mode, agents and watch after #570 and #571 | low |
| [D121](defects/d121.md#d121---keys-mcp-servers-and-limits-after-chunk-28s-fixes-low) | Keys, MCP servers and limits after chunk 28's fixes | low |
| [D122](defects/d121.md#d122---updates-the-prompt-prefix-and-the-planes-checks-after-chunk-29-low) | Updates, the prompt prefix and the plane's checks after chunk 29 | low |
| [D123](defects/d121.md#d123---tools-the-scratchpad-sign-in-and-installs-after-chunk-30-low) | Tools, the scratchpad, sign-in and installs after chunk 30 | low |
| [D124](defects/d121.md#d124---updates-frames-addresses-and-the-turns-tools-after-chunk-31-low) | Updates, frames, addresses and the turn's tools after chunk 31 | low |
| [D125](defects/d121.md#d125---docs-policy-ceilings-and-workspaces-after-chunk-32-low) | Docs, policy, ceilings and workspaces after chunk 32 | low |
| [D126](defects/d121.md#d126---workers-the-github-app-the-console-and-providers-after-chunk-33-low) | Workers, the GitHub App, the console and providers after chunk 33 | low |
| [D127](defects/d121.md#d127---the-github-fix-loop-control-tls-the-scratchpad-and-providers-after-chunk-34-low) | The GitHub fix loop, control TLS, the scratchpad and providers after chunk 34 | low |
| [D128](defects/d121.md#d128---apparmor-identity-control-tls-and-the-console-after-chunk-35-low) | AppArmor, identity, control TLS and the console after chunk 35 | low |
| [D129](defects/d121.md#d129---the-complete-console-github-webhooks-rules-and-extends-after-chunk-36-low) | The complete console, GitHub webhooks, rules and extends after chunk 36 | low |
| [D130](defects/d130.md#d130---extends-the-push-policy-rules-on-profiles-and-the-test-guards-after-chunk-37-low) | Extends, the push policy, rules on profiles and the test guards after chunk 37 | low |
| [D131](defects/d130.md#d131---first-run-github-sweeps-the-signed-plane-and-the-agent-picker-after-chunk-38-low) | First run, GitHub sweeps, the signed plane and the agent picker after chunk 38 | low |
| [D132](defects/d130.md#d132---steering-company-memory-mcp-sign-in-and-the-docs-after-chunk-39-low) | Steering, company memory, MCP sign-in and the docs after chunk 39 | low |
| [D133](defects/d130.md#d133---offers-memory-refresh-the-signed-policy-and-the-picker-after-chunk-40-low) | Offers, memory refresh, the signed policy and the picker after chunk 40 | low |
| [D134](defects/d130.md#d134---the-gates-desk-walk-the-charts-hand-steps-the-upgrade-test-and-the-seam-after-chunk-41-low) | The gate's desk walk, the chart's hand steps, the upgrade test and the seam after chunk 41 | low |

The pages: [D8 to D62](defects/d008.md), [D63 to D89](defects/d063.md),
[D90 to D120](defects/d090.md), [D121 to D129](defects/d121.md) and
[from D130](defects/d130.md).

## Closed

Defects that an issue or a pull request took, that will not be fixed, or that turned out
not to be defects are in [docs/history/defects-closed.md](../history/defects-closed.md),
kept as they were written so that a `D` number cited elsewhere still says where it went.
