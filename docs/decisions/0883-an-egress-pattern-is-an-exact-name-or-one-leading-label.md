---
number: 883
title: An egress entry is an exact name or a wildcard of one leading label; anything else is refused in the policy and in a profile, and a policy holding one admits nothing
date: 2026-10-12
status: accepted
issue: 662
paths:
  - apps/troupe_protocol/lib/troupe/policy.ex
  - apps/troupe_protocol/test/troupe/policy_test.exs
  - apps/troupe_operator/lib/troupe/operator/resources.ex
  - apps/troupe_operator/test/troupe/operator/resources_test.exs
  - apps/troupe_operator/test/troupe/operator/reconciler_test.exs
  - apps/troupe_operator/test/support/fixtures.ex
  - charts/troupe/templates/admission-policy.yaml
  - charts/troupe/crds/troupepolicy.yaml
  - docs/admin/profiles-and-policy.md
symbols:
  - Troupe.Policy.pattern?/1
  - Troupe.Policy.matches?/2
gist: "Pattern = exact host or `*.` + starless domain, no empty label; else refused in policy and profile; a policy holding one admits no profile"
---

Issue #662, found in the chunk 32 docs sweep. The values file said a bare `*` was not a
pattern `allowedEgress` accepts. The code took any entry not starting with `*.` as an
exact hostname, so a `TroupePolicy` holding `*` admitted a `WorkerProfile` holding `*`,
in `Troupe.Policy` and in the admission CEL alike, and the operator wrote any entry with a
star as a Cilium `matchPattern`, where a bare `*` is every name. Looking closer, a
profile's `**.example.com` also passed a policy's `*.example.com` (its first label, `**`,
is one label) and became a `matchPattern` that Cilium reads as any number of labels: a
profile could reach more than the policy it passed.

- **The rule.** An egress entry is a pattern when it has no star (an exact name) or is
  `*.` followed by a domain with no star and no empty label. Nothing else: not `*`, `**`,
  `*.*`, `**.example.com`, `a.*.example.com`, `*example.com`, `a*.example.com`,
  `example.*`, `*.`, `*..example.com`, `*.example.com.`. The one table of those forms
  (`Troupe.Operator.Fixtures.refused_patterns/0`) is what the policy test and the
  operator's rendering test both run over.
- **Everywhere, the same test.** `Troupe.Policy.pattern?/1`; the admission rule, which
  writes the same test out in CEL twice (once for the policy's entries, once for the
  profile's hosts) because CEL has no functions; the `TroupePolicy` CRD, whose
  `allowedEgress` items carry it as a validation rule, so a policy holding one is refused
  when it is written, naming the entry. `matches?/2` covers nothing with an entry that is
  not a pattern, on either side.
- **A profile's entry** that is not a pattern is refused naming it
  (`egress_not_a_pattern`), whatever the policy holds.
- **A policy's entry** that is not a pattern refuses every profile, naming it
  (`allowed_egress_not_a_pattern`), until it is taken out. The alternative was to ignore
  it, so that it covered nothing and every other entry went on working. Refusing was
  chosen because a policy is a cluster admin's statement of intent, and an entry its
  author took for a pattern and the code cannot read is intent nobody can know; a missing
  policy already admits nothing, for the same reason. It is reachable only past the CRD's
  rule (a cluster with an older CRD, or a plane's configured policy), and the refusal
  names the entry, so the fix is one line. A refused profile's running pods are not
  removed: the operator writes nothing for it until the policy is fixed.
- **The operator's own fence.** `Resources` gives an entry that is not a pattern no rule
  at all, so no `matchPattern` the policy check would refuse is ever written, whatever path
  reaches the renderer.

The bounds on the CRD's list (512 entries of at most 253 characters, a hostname's limit)
keep the rule's cost estimate inside what the API server accepts for a CRD.
