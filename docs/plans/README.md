# Plans

What comes after the small release, written before it was built. The first three are
built as stage 5 — `ARCHITECTURE.md` §14 describes what landed and `REPORT.md` proves
it — and stay here as the record of what was intended and why. The fourth is the GUI
repository's `spec.md`. Each plan says what
it brings, what it takes, what is already in place, what the code is missing today
(with file and line), the design, the order of work, and the done items that prove it.
`spec.md` and `ARCHITECTURE.md` remain the authority on invariants; nothing here weakens
them, and where one asks to revise a decision it says so and why.

| Plan | One line | Depends on |
| --- | --- | --- |
| [Skills and MCP servers](skills-and-mcp.md) | A profile carries admin-published skills and MCP servers; every session has them from its first turn. | — |
| [Remote triggers](remote-triggers.md) | Sessions nobody starts by hand, run by Hatchet through the plane API as service principals, reviewed in HQ. | the bundle's `agent` list for what a trigger runs; nothing else |
| [The A2A facade](a2a-facade.md) | Other agents delegate tasks to a profile; a task is a session, an artifact is a published file. | service principals, `prompt` through activation and status columns from triggers; skills from the first plan for the agent card |
| [Local and private sessions](../../../troupe-gui/docs/plans/local-and-private-sessions.md) (in the GUI repository) | The GUI shows local sessions beside team sessions, and a person's private session is sealed to object storage under their own key and follows them to another device. | independent of the other three; shares the sealer with workers |

The order above is the order to build them. Skills first because the others describe a
profile by what its bundle carries. Triggers second because the facade is its second
caller. Private sessions can proceed in parallel with any of them; its first step, the
daemon's loopback WebSocket, is a day's work and unblocks the GUI for local use.

## Threads that run through all four

* **A caller is a caller.** Triggers, the facade and the GUI are clients of `/rpc` and
  the worker socket, with the scopes their principal has, and no private door.
* **Nothing new in the data path.** The plane keeps listing, placing and minting; pods
  keep the content; the one place a plan asks the plane for more (presigned object URLs
  for private sessions) is for ciphertext it has no key to.
* **Status is not content.** Four lifecycle facts — status, done reason, pending
  approvals, cost — move from "replay the log to find out" to columns the plane can
  list, which is what a review queue, an A2A `tasks/get`, and a synced session list all
  need.
* **The bundle is the description of a profile.** Agents, skills and MCP servers come
  from it; the agent card is rendered from it; a trigger names one of its agents.

## The small server changes that unlock the most

If only a week were available, these four are the ones to do, because each of the plans
needs them and each is small:

1. Carry `prompt` through `session.create` → activation → `:task`
   (`harness.ex`, `restore.ex`, `troupe.ex:179`).
2. Report `status`, `done_reason`, `pending_approvals`, `cost_micros` from workers to
   plane rows and list them.
3. Validate bundle content and load agents from it (`definitions.ex`).
4. Start `Troupe.Gateway.Web` on loopback in the daemon.
