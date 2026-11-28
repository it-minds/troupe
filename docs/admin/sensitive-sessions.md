# Sensitive sessions

A session that has read data which must not leave it (medical records, personnel files, a
customer's ledger) can still, in the same turn, publish an artifact, fetch a web page, push
to GitHub or propose a line for the team's memory. The per-tool rules of a profile
([per-tool rules](profile-options.md#per-tool-rules-on-a-profile)) are the same before the
read and after it. `spec.sensitive` makes them differ: a session becomes **sensitive** by
what it read, stays so, and is refused what the profile says a sensitive session may not do
(Decision 1120).

## Configuring it

On the worker profile, beside `permissions`:

```yaml
spec:
  sensitive:
    markedBy: ["mcp(records.*)", "read_file(/mnt/records/**)", "shell(psql)"]
    deny: ["publish_artifact", "web_fetch", "git_push", "pr_open", "pr_comment",
           "mcp(slack.*)", "shell(curl)", "remember"]
    sharing: ask
```

- **`markedBy`**: rules in the [per-tool rule grammar](../user/configuration/permissions.md),
  at most 200. A call that matches one marks the session sensitive, **before the call runs**,
  so the mark is there before the data is. A call a permission rule refuses does not mark:
  it read nothing.
- **`deny`**: rules refused while the session is sensitive, at most 200. They apply above the
  profile's own `permissions`, in the root agent and every subagent, in this turn and every
  later one, after a sleep and a wake. The tool stays in the list the model is offered; a call
  to it is refused with a sentence saying since when and by what, for example: *This session
  is sensitive since mcp.records.lookup read from it at 10:14: publish_artifact is refused in
  a sensitive session by the profile records. It did not run.*
- **`sharing`**: what a person may do with a sensitive session beyond the people who read it
  now: `allow` (the default), `ask` or `deny` ([sharing](#sharing-a-sensitive-session)).

`markedBy` without `deny` is refused by `admin.profile.put` and by a repository's manifest,
so the choice is explicit. A rule the pods could not read is refused with the reader's
sentence. The rules are the grammar's and nothing more: `web_fetch` names the tool whole, with
no host; `remember` names the tool whole, so `deny: [remember]` refuses every level of it,
the person's own memory included. The plane refuses a sensitive session's proposals for a
team's or the organisation's memory whatever `deny` says.

A profile that extends another adds rules to both lists and keeps every one of its parent's;
it may tighten `sharing` (`allow` < `ask` < `deny`) and not loosen it: a looser word is kept
as written, does nothing, and the profile's effective view says so. The plane reads
`spec.sensitive` at every activation, so a change restarts no pod and reaches a session the
next time it wakes.

## Nothing clears it

There is no method, event or tool that takes the mark away: not the owner, not a team
administrator, not a platform administrator. A sensitive session is sensitive until it is
erased. A person may also mark a session by hand (`session.sensitive.set`, or
`session.create` with `sensitive: true`), which is one-way as well. A session spawned or
forked from a sensitive one is sensitive from its start, marked as its parent is: a
sibling's prompt is the parent agent's words, and a fork carries its parent's history.

## Sharing a sensitive session

`sharing` covers what takes a sensitive session beyond the people who read it now: giving it
to the team (`session.visibility.set`), inviting a person (`session.invite`), granting one a
role (`session.grant`), minting a link to it (`session.share`), and moving or sharing an
artifact it published wider (`artifact.put` with another visibility, `artifact.share`,
switching its public links on). Taking it back is never refused, and the people who read it
now go on reading it.

- **`allow`** (the default): as for any session.
- **`deny`**: each is refused, naming the profile and who reads the session now: *This
  session is sensitive and records does not allow sharing it outside the team that already
  reads it, ward-7*.
- **`ask`**: each is held for a team administrator of the session's team, and the owner is
  told it is *waiting on a team administrator*; nothing is applied. The administrator lists
  what waits with `session.share_requests` and answers with `session.share_request.decide`
  (`approve` or `decline`); a yes applies the share as the owner asked it. The request, the
  answer and the share are each audited (`session.share_request`,
  `session.share_request.decide`, and the share's own action under the owner). A link cannot
  wait, since it is a secret handed back at once, so under `ask` it is refused with a sentence
  that says to invite the person by name instead. A team administrator's own share is not
  held: it is the yes it would have waited for.

## What the plane refuses on its own side

The pods refuse at their gate; the plane refuses what it owns as well, so a session marked on
a pod is held there even if something on the pod were to let a call through:

- every proposal for a team's or the organisation's memory from a sensitive session, with a
  sentence its agent relays (as it refuses a throwaway session's);
- `artifact.publish`, the pod's publication and a new version from a sensitive session whose
  profile's `deny` names `publish_artifact`;
- a trigger proposal (Decision 1111): a sensitive session proposes none.

Every session row says `sensitive` (`{at, by, how}`, or `null`), and the audit has
`session.sensitive` for each mark: actor `system:harness` with the `tool` and `rule` for a
call, or the person for a mark by hand.

## On people's own computers

A session on a person's own computer is marked and refused by the same gate, against rules
the organisation's managed file enforces ([client configuration](client-config.md)), in the
config file's spelling (Decision 1124):

```yaml
version: 1
enforced:
  sensitive:
    marked_by: ["mcp(records.*)", "read_file(/srv/records/**)"]
    deny: ["publish_artifact", "web_fetch", "mcp(chat.*)", "shell(curl)", "remember"]
    sharing: deny
```

- **`marked_by`** and **`deny`** are the profile's `markedBy` and `deny`. A person's own
  `config.yaml` may add rules to both (a `sensitive:` block at its top level) and cannot take
  one of these away; a project's file sets none. `marked_by` with no `deny` in either file
  refuses the configuration, naming the file.
- **`sharing`** may be tightened by the person's file and not loosened: a looser word is
  ignored and warned about. On a laptop it holds an offer for steering from another device
  and an invitation into a private session. `ask` refuses as `deny` does there, with a
  sentence saying so: no team administrator answers a laptop's request.
- **The daemon refuses on its own side** what it does for a session outside its agents' gate:
  a publication where `deny` names `publish_artifact`, every proposal for a team's or the
  organisation's memory, and a call it makes to one of the person's servers for the session,
  which marks it where `marked_by` names the call. A session here has no plane row, so the
  plane's own refusals and its audit of the mark do not reach it.

`sensitive` under `defaults:` is ignored with a warning: a default a person's file could
replace would be neither the organisation's rule nor theirs. The plane's organisation set
(`client_enforced`) does not carry `sensitive` yet; the managed file does. People see the
rules in effect, and where each came from, on *This computer* in the desktop app, in the
terminal's `/settings` and with `troupe config --explain sensitive`.

## A worked example

A team works with a patients' records system the bundle reaches as the MCP server `records`.
Reading from it must keep the session from publishing, fetching, pushing or posting to chat,
and the session from being shared without a ward administrator's yes:

```yaml
apiVersion: troupe.dev/v1alpha1
kind: WorkerProfile
metadata:
  name: ward
spec:
  extends: standard
  sensitive:
    markedBy: ["mcp(records.*)"]
    deny: ["publish_artifact", "web_fetch", "git_push", "pr_open", "pr_comment",
           "mcp(chat.*)", "shell(curl)", "remember"]
    sharing: ask
```

An agent on `ward` calls `mcp.records.lookup`. Before the call runs, the session's log has
`session_marked_sensitive` (`by: mcp.records.lookup`, `rule: mcp(records.*)`), the pod's next
status marks the row, and the audit has `session.sensitive`. The lookup's result reaches the
agent, whose next model call is told in its configuration that the session is sensitive and
what is refused. When it then calls `publish_artifact`, the call is refused with the sentence
above, the transcript shows the refusal, and nothing is published; the same holds for a
subagent it delegates to, after the session sleeps and wakes, and whatever the prompt tells
the agent to try. When the owner gives the session to the team (`session.visibility.set`),
the share waits for an administrator of the session's team, who sees it with
`session.share_requests` and answers it with `session.share_request.decide`.
