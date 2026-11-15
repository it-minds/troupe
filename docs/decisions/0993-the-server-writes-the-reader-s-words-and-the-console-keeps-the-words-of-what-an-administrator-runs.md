---
number: 993
title: "The harness, gateway, worker and plane write every sentence a client shows in the reader's words, so no client rewrites one; the console keeps the words of what an administrator runs and drops the ones a person has another word for"
date: 2026-11-15
status: accepted
issue: 927
paths:
  - apps/troupe_core/lib/troupe/plane_memory.ex
  - apps/troupe_core/lib/troupe/instructions.ex
  - apps/troupe_core/lib/troupe/config/permissions.ex
  - apps/troupe_core/lib/troupe/agent/local.ex
  - apps/troupe_gateway/lib/troupe/gateway/dispatch.ex
  - apps/troupe_worker/lib/troupe/worker/session/restore.ex
  - apps/troupe_plane/lib/troupe/plane/control/connection.ex
  - clients/gui/packages/client/src/config.ts
  - clients/gui/packages/client/src/instructions.ts
  - clients/gui/packages/client/src/transcript.ts
  - clients/gui/apps/console/src/nav.ts
  - clients/gui/apps/console/src/views/bits.tsx
  - clients/gui/apps/console/src/views/Mine.tsx
  - clients/tui/lib/troupe/remote/translate.ex
  - docs/admin/console.md
symbols:
  - inReadersWords
  - SessionState
  - not_editable
gist: "Server sentences use DESIGN §11's words (profile, when the session started, on the platform, asleep; console pages as Group → Area, ask an administrator); inReadersWords goes; console keeps pod/worker/image/channel/drain/node, nav says Profiles and Pods"
---

Issue #927, the second pass after #897. The desktop app rewrote the plane's and the pod's
operator words on their way to the screen (`inReadersWords` in the client package): "the
worker profile" became "the profile", "with the session's activation" became "when the
session started". The terminal showed the same sentences raw, so the two clients said
different things about one session, and every new sentence the server wrote needed a new
rule in one client and none in the other.

**At the source.** Every sentence the harness, the gateway, the worker or the plane writes
for a person to read uses DESIGN.md §11's words:

- "profile", never "worker profile": a memory document's label (`the profile dev's memory`),
  a key's source (`the profile dev (TROUPE_MODEL)`), a rule's scope (`from the profile
  fixing`), the personal-tools refusal, the GitHub refusals;
- "when the session started", never "activation": where a pod's memory came from;
- "on the platform", never "on a pod" or "on a worker pod": what a session reads, what
  onboarding refuses, what a raise lasts, what is in force, what a pod's own layer is called
  (`the platform`);
- a sentence that sends somebody to the console names the page as `Group → Area` and says
  it is an administrator's, as #894 had the terminal's own sentences do: a bundle's agent
  (`Configure → Configuration bundles`), the organisation's, a team's and a profile's memory
  (`Govern → Company memory`). The terminal's console-paths test now reads the worker's and
  the plane's code too.

Logger lines, the admin API's field values (`dormant` stays the state's key), module
documentation and identifiers are an operator's and keep the operator's words.

So `inReadersWords` has nothing to rewrite and goes, with its uses in `keySource` and
`instructionLayers`: a client shows the sentence as it came. The client package's and the
terminal's own lines for a session's sleep and wake say "session went to sleep" and
"session woke on the platform", never "dormant" or the pod's name. The test fakes write the
server's new sentences, and a desktop test holds that what they send reaches the screen
without an operator's word.

**The console's vocabulary.** An administrator's page may name what an administrator runs,
since that is what they act on: pod, worker, image, channel, drain, node, and the cluster
where the page is about its resources (a gitops resource the cluster has or lacks, the
cluster policy, a storage class). It drops the words a person has another word for:
"worker profile" is "profile", a dormant session is "asleep" (the state's one word on every
page, `SessionState`, and the Sessions filter, the Overview's count and a team's idle
limit), and "cluster" where it meant where sessions run is "the plane" or "the platform".
The map's areas are **Profiles** (was Worker profiles) and **Pods** (was Workers and pods).
Mine, a person's own page, shows its sessions' state through `SessionState`, with a running
session's status after it, never the plane's `active · idle`.

This rewrites the sentences Decision 922 quotes for a pod's memory source and leaves its
substance; it supersedes nothing. The plane's settings table's labels (#933's) still say
"dormant" for two team defaults and are left for that table's owner to word.
