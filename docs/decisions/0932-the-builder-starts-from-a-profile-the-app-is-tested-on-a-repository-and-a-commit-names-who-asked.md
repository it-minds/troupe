---
number: 932
title: The console's agent builder starts from a profile's agents as its bundle in effect has them, with who may run each, and picks a model from the ones the plane has been told of or seen run; the App's test mints, uses and revokes a token for a chosen repository and shows what it could do; a fix loop's commit names who the run is for in a Requested-By trailer the plane writes; and the desktop manager is the picker's rows
date: 2026-10-23
status: accepted
issue: 594
paths:
  - apps/troupe_plane/lib/troupe/plane/admin.ex
  - apps/troupe_plane/lib/troupe/plane/ledger.ex
  - apps/troupe_plane/lib/troupe/plane/github.ex
  - apps/troupe_worker/lib/troupe/worker/github.ex
symbols:
  - Troupe.Plane.Admin.profile_agents/2
  - Troupe.Plane.Admin.profile_choices/2
  - Troupe.Plane.Admin.github_check/2
  - Troupe.Plane.GitHub.check/1
  - Troupe.Plane.GitHub.requested_by/1
  - Troupe.Plane.Ledger.models_run/2
gist: "admin.profile.agents feeds the builder; models are ones the plane knows; App test mints+revokes for a repo; Requested-By is the plane's, agent's stripped"
---

- **The builder starts from the profile.** `admin.profile.agents {name}` answers the
  profile's agents as its bundle in effect has them (Decision 910's composition through
  what it extends), each with the fields the builder edits (mode, description, model,
  `max_turns`, skills, permissions), `from` and `channel` (where it was published, which
  the builder opens), its definition, `delegate` and `teams`. A built-in primary the profile
  offers because its bundle has none of that name is a row too, `builtin: true` and no
  channel, to copy rather than edit; `builtins` is every agent Troupe ships with its file,
  read from `troupe_core`'s `priv/agents` when the plane is compiled as the names already
  were, so the plane still never depends on core at run time. A platform admin's, as
  editing a bundle is.
- **`delegate` is the harness's rule, not a key.** A definition has no list of whom it
  calls: a primary holding the `delegate` tool (or every tool) may hand work to any of its
  bundle's subagents, so that is the list, and `nil` for one that cannot delegate. Not
  chosen: a new frontmatter key, which the daemon's check (Decision 920) would refuse and
  no harness reads.
- **Who may run each agent is the grant, resolved.** For every team granted the profile,
  `may` is `Entitlement.resolve/2` of the agent against the grant's agent rows, as a
  session of that team's is narrowed, so a grant that allows other agents, or denies this
  one, says false. Shown, not edited: a grant is changed on Teams.
- **A model is picked from the ones the plane knows a provider serves.** The plane does not
  ask a provider for its list: the key is the pods', and a plane that called providers to
  draw a form would be a new reach for one read. `admin.profile.choices {profile}` answers
  `models`, each `{name, why}`, the first reason found in this order: the profile's own
  `llm.model`, the models the organisation gives people's machines (`client_model_*`), the
  models the ledger has charged the profile's sessions for (`Ledger.models_run/2`, which
  only a provider that served them could have produced), and the models its bundle's agents
  name. Without a profile, the organisation's and every session's. The builder offers these
  and "the session's model"; a model already written that is not among them is kept and
  marked, not dropped. Not chosen: a free text field (the issue's "picked, not typed"), or
  a fixed catalogue in the protocol, which would be wrong for every gateway.
- **The App's test takes a repository.** `admin.github.check {repository}` adds a fifth
  check, `Repository`, tried only when the four before it pass: a token for that one
  repository is minted with no permissions named, which GitHub answers with all the
  installation's own there, the repository is read with it, and it is revoked
  (`DELETE /installation/token`) before the answer. The answer's `repository` is
  `{name, installation_id, permissions, revoked}`, GitHub's own list of what the token
  could do; the token is in no answer, error or log, and is audited as `github.token`
  "for the App's test" with whether it was revoked. Asking for all the installation's
  permissions is the point of the question (what can the App do on this repository); the
  token lives for one read. Not chosen: asking for the fix loop's grants, which GitHub
  refuses whole when the App lacks one, and so could not say which.
- **`Requested-By:` is the plane's word.** Beside `Troupe-Session:` (Decision 891), each
  commit the fix loop makes ends with `Requested-By:`, which the plane computes from its
  own rows and sends in every `github.record` answer (`GitHub.requested_by/1`): the latest
  trigger run that made the session names who fired it, a person by display name and email
  (`Ada Lovelace <ada@example.com>`), a GitHub login for a label a person put on
  (`octocat on GitHub (trigger fix-label, team core)`), the trigger and its team for a sweep,
  a schedule or a trigger's key (`trigger nightly-fix, team core`); a session no trigger made
  is its owner's. Made one line of printable characters, at most 200, on the plane, and the
  pod takes it only so; every line of the agent's message that looks like either trailer is
  taken out, so issue text that talks the agent into writing `Requested-By: someone` names
  nobody. Not chosen: the issue's author, which a hostile issue sets; or the subject alone,
  which is opaque to a reviewer.
- **The desktop manager is the picker's rows.** `Agents.tsx` draws `AgentPicker`'s rows,
  groups and actions (the four origin words, the badges, Start, Switch, Edit), with the
  manager's density (mode, what it stands in for, the windows running it) and its own Copy,
  New from this and Delete; a new agent saved offers to start a session on it.
