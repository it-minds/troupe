---
number: 980
title: A bundle's skill may say which agents may load it (`agents`, `all` or names, the built-ins included), an agent loading a skill its own `skills:` opens or one whose `agents` names it, a team's grant still narrowing after both; a draft naming an agent that is neither the bundle's nor Troupe's is refused, and `admin.profile.agents` says on each agent which skills it loads
date: 2026-11-13
status: accepted
issue: 886
paths:
  - apps/troupe_protocol/lib/troupe/protocol/bundle.ex
  - apps/troupe_protocol/test/troupe/protocol/bundle_test.exs
  - apps/troupe_core/lib/troupe/agent/definition.ex
  - apps/troupe_core/lib/troupe/agent/hold.ex
  - apps/troupe_core/lib/troupe/skills.ex
  - apps/troupe_core/test/troupe/skills_test.exs
  - apps/troupe_plane/lib/troupe/plane/admin.ex
  - apps/troupe_plane/lib/troupe/plane/bundles.ex
  - apps/troupe_plane/test/troupe/plane/admin_test.exs
  - clients/gui/apps/console/src/views/ProfileAgents.tsx
  - clients/gui/apps/console/src/views/Bundles.tsx
  - docs/admin/bundles-and-triggers.md
  - PROTOCOL.md
symbols:
  - Troupe.Protocol.Bundle.loads?/3
  - Troupe.Protocol.Bundle.skill_agents/1
  - Troupe.Agent.Definition.allows_skill?/2
gist: "A skill's agents (all or names, built-ins too) opens it beside an agent's own skills:; either suffices, the grant narrows after; unknown names refused in a draft"
---

A config bundle's skills reached the pod, but an agent loaded only the skills its own
frontmatter opened (`skills: all` or a list, none by default), and none of the agents
Troupe ships opens any (#886). On a profile whose bundle brought skills and no agents of
its own, which is most profiles, a session had no `skill` tool and its prompt listed no
skill, and nothing said so: the bundle validated and published. The only way round it was
to copy each built-in into the bundle with `override: true`, which freezes Troupe's prompt
at the release it was copied from for the sake of one frontmatter line.

## Decision

**A skill says which agents may load it.** A skill entry in a bundle may carry `agents`:
`"all"`, or a list of agent names, the built-in ones (`build`, `plan`, ...) included.
Absent, nothing changes. An agent may load a bundle's skill when **either** its own
`skills:` opens it **or** the skill's `agents` names it or says `all`
(`Troupe.Protocol.Bundle.loads?/3`, the one rule the pod loads by and the plane reports
by). A team's grant narrows after both, as it always has (Decision 826): nothing here
widens past a grant. A person's own and a repository's skills, which every agent of a
session is offered already, are untouched.

**On the skill, in the bundle, rather than a profile option.** The skill is what the
bundle ships, so the admin who publishes it says once where it goes; a child profile
composing its chain's bundle (Decision 910) takes the word with the skill, raw entries
being carried through composition, instead of needing a second knob on every profile; and
a profile option next to `spec.agents` would have said the same thing about every skill at
once, where an organisation's house rules and a team's template want different agents. The
third option in the issue, an override of an agent's frontmatter keys alone, would have
been a second kind of agent entry for one key.

**Checked where a draft is checked.** `agents` that is neither `"all"` nor a list of names
is refused wherever a document is validated. A name that is neither one of the bundle's
agents nor one Troupe ships is refused at `admin.bundle.validate`, `preview` and `publish`
by name, as an agent listing a skill the bundle lacks is: it would open the skill to
nothing, a typo nobody would otherwise be told of. A version read again (composed into a
child's bundle, fetched by a pod) is not held to the names, since the built-ins of the
Troupe that reads it may not be those of the one that published it.

**On the pod.** The skill list comes from the materialised directory, whose `bundle.json`
is the document, so `Bundle.list_skills/1` reads each skill's `agents` from it. A turn's
hold (Decision 876) writes `agents` for a skill that says it, and only then, so a hold of
skills that say nothing reads and hashes as it did, and an agent restarted mid-turn still
offers what the skill opened to it.

**Seen before a session finds it.** `admin.profile.agents` gives each agent `loads`, the
bundle's skills it may load before a grant narrows them, and the answer `skills`, every
skill the bundle in effect carries. The row's `skills` stays its own frontmatter's, which
the builder edits; `loads` is beside it rather than in its place. The console's profile
page says "loads ..." or "loads none of its bundle's skills" on each agent where the bundle
has skills, and a bundle version's page shows each skill's `agents`. The bundle editor
holds skills as JSON, so the key is written and kept there as any other key of a skill.

## Proof

`apps/troupe_core/test/troupe/skills_test.exs` ("a skill the bundle opens to agents": an
agent with no `skills:` loads a skill whose `agents` names it, with the tool and the prompt
line; `all`; one not named cannot; a grant still narrows; the hold keeps it).
`apps/troupe_protocol/test/troupe/protocol/bundle_test.exs` (parse, refuse a bad shape,
refuse an unknown name in a draft but not on a re-read, `loads?/3`, a materialised
bundle's skills carry `agents`). `apps/troupe_plane/test/troupe/plane/admin_test.exs`
("each agent of a profile says which of its bundle's skills it loads", and the refusal at
`admin.bundle.validate` and `publish`). Each failed before the change.
