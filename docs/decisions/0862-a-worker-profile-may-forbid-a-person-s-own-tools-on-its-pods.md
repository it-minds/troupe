---
number: 862
title: "A worker profile may forbid people offering their own signed-in tools to its pods; allowed is the default, and a pod on a profile that forbids it refuses the offer with a sentence"
date: 2026-10-11
status: accepted
issue: 331
paths:
  - apps/troupe_core/lib/troupe/session/client_tools.ex
  - charts/troupe/crds/workerprofile.yaml
gist: "A WorkerProfile may forbid personal tools on its pods (default allow); the pod refuses tools.register from a person with a sentence. To build: #595"
---

#331 asked whose identity a remote MCP call carries, and #308 (Decision 0861, PR #584) answered it for a person's own servers. A person offers their signed-in servers' tools to a pod session they work in. The pod calls them back through the person's client, so the call runs on the person's machine with the person's token. The question #331 left open was whether a team may refuse that on its pods.

**Decided by the maintainer, 2026-10-11: yes, per worker profile, with allowed as the default.**

- **Where the setting lives.** It is on the profile, not the team and not the policy. A profile is what an administrator already uses to say what a team's pods may do: their egress, their bundle, whether a repository may override it (Decision 826). A team that needs both kinds of session uses two profiles.
- **Allowed is the default.** It keeps #308 working everywhere it works today. A team that must keep its pods' inputs to what the profile names can forbid it.
- **How a forbidding pod answers.** On a profile that forbids it, a pod refuses `tools.register` from a person with a sentence naming the setting. The refusal is logged and nothing is registered. The clients read the refusal and don't offer the person's servers to that session.
- **What it doesn't change.** It doesn't change the profile's own MCP identities (`mcpIdentities`), which are the profile's, not a person's. It doesn't change a local session either.

**Not built yet.** The setting, the pod's refusal and the clients' handling are #595. This file records the decision so #595 builds to it.
