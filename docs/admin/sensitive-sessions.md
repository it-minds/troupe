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
`session.create` with `sensitive: true`), which is one-way as well.

## Sharing a sensitive session
