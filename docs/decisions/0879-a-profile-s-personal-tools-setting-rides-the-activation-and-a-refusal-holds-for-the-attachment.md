---
number: 879
title: "A worker profile's personalTools travels to the pod with each activation, a forbidding pod refuses before any challenge and logs it, and a client takes a forbidden refusal as the answer for the whole attachment"
date: 2026-10-12
status: accepted
issue: 595
paths:
  - charts/troupe/crds/workerprofile.yaml
  - apps/troupe_plane/lib/troupe/plane/harness.ex
  - apps/troupe_plane/lib/troupe/plane/fleet/profile.ex
  - apps/troupe_worker/lib/troupe/worker/session/restore.ex
  - apps/troupe_core/lib/troupe/session/client_tools.ex
  - apps/troupe_gateway/lib/troupe/gateway/dispatch.ex
  - clients/tui/lib/troupe/remote/worker.ex
  - clients/gui/packages/client/src/offer.ts
symbols:
  - Troupe.Session.ClientTools.register/4
gist: "spec.personalTools (allow|forbid, absent allow) rides the activation, not the pod env; refused before the challenge, logged on the pod; clients stop offering for the attachment"
---

Decision 862 settled that a worker profile may forbid people offering their own signed-in
tools to its pods, with allowed as the default, and that a forbidding pod refuses
`tools.register` with a sentence, logs it and registers nothing. #595 builds it. This
records what 862 left to the build.

- **The setting is `spec.personalTools`, `allow` or `forbid`.** A word rather than a
  boolean, as the issue spelled it, so a later middle setting (say, only some servers) has
  somewhere to go. The resource declares the two words and no default, so no existing
  `WorkerProfile` changes when the chart is upgraded: absent is `allow`. `Fleet.Profile`'s
  changeset refuses any other value, `null` included, for `admin.profile.put` and the
  gitops reader alike, because a pod reads only `forbid` as forbidding and a `"Forbid"`
  saved would leave the pods taking what the admin believes they refuse. The console's
  profile editor has it as a toggle and writes the word whichever way it is set, so a save
  from there can lift it.
- **It rides the activation, not the pod's environment.** As `repositoryOverridesBundle`
  does (Decision 826), and for the same reasons: an environment variable the operator set
  would replace every pod of the profile to change it, and an `ssh` profile has no pod
  template. `Harness.bundle_params/1`, which already reads the profile's row at every
  activation, sends `personal_tools` beside the pin; the worker passes it to the session as
  the config field `personal_tools_forbidden_by`, the profile's name, set only for
  `forbid` and never from a file. A change reaches a session the next time it is
  activated; a session awake when the admin changes it keeps what it had until then. The
  operator renders nothing for it, and a test says so.
- **Refused before the challenge, as `managed_mcp_servers_only` is.** Asking somebody to
  consent to tools the pod will not take is worse than refusing. The answer is `forbidden`
  with `setting: personalTools`, `profile`, and the sentence "the worker profile <name>
  does not take a person's own tools on its pods (personalTools: forbid); only the
  profile's MCP servers are available". It covers every client-hosted tool, not only an
  MCP server's: on a pod, any tool a client hosts runs on somebody's machine as them.
- **Logged on the pod, not in the session.** One `warning` line per refusal, naming the
  session, the subject and the tools, so an operator asked why somebody's tools never
  reached a session finds it in the pod's log. Warning rather than info, so a pod log kept
  at warning still has it. The session's log records nothing, as for
  the platform's switch: a session has nothing to say about a tool it never had, and a
  refusal in it would read as something the session did.
- **A `forbidden` refusal holds for the attachment, in both clients.** Neither the
  platform's switch nor the profile's changes while a person is attached, so a client that
  re-offered on every new socket would only repeat the refusal. The TUI says it once, as a
  note in the session's window ("your own MCP servers are not offered to this session:
  ..."), and offers nothing on a later socket of that attachment; the desktop app's offer
  stays `refused` with the session's reason, which its line shows ("Your servers could not
  be offered here: ..."), and lists and registers nothing on a later socket. A session
  opened again is offered again. This also changes what the clients did for
  `managed_mcp_servers_only`, which they used to offer to on every socket.
- **The chart.** The resource is the chart's (`charts/troupe/crds/`); the chart renders no
  `WorkerProfile` and has no values for one, since the plane or a repository writes them,
  so there is nothing to add to its values or templates.
- **Proof:** `Troupe.Worker.PersonalToolsTest` (activated with `forbid`: refused with the
  sentence, the log line, nothing registered or tainted; `allow` and nothing: the consent
  challenge as before; a profile changed while the session slept reaches it at its next
  activation), `Troupe.Gateway.ClientToolsTest` (the refusal over a socket, before any
  challenge), the plane's `BundlesTest` (the push carries `personal_tools`), `AdminTest`
  (the two words kept, anything else refused, the resource declaring them with no
  default) and `PanelTest` (the toggle kept and lifted), the operator's `ResourcesTest`
  (nothing rendered changes), the TUI's `RemoteClientToolsTest` (said once, nothing asked,
  nothing offered on the next socket), and `@troupe/client`'s and the desktop app's
  `own-servers` tests (the refusal shown with its reason, nobody asked, the next socket
  quiet).
