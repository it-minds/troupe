---
number: 852
title: agents.list lists the subagents when asked, a save names the hash of the file it replaces and is refused over one that changed, a file that does not parse is opened to mend through agents.get, and the desktop app's palette, watch box and transcript show what the daemon and the log say
date: 2026-10-11
status: accepted
issue: 565
supersedes: [841]
paths:
  - apps/troupe_gateway/lib/troupe/gateway/agents.ex
  - apps/troupe_core/lib/troupe/agent/local.ex
  - apps/troupe_core/lib/troupe/agent/definitions.ex
symbols:
  - Troupe.Agent.Local.broken/3
  - Troupe.Agent.Local.hash/1
  - Troupe.Onboard.put_file/5
  - Troupe.UI.TUI.Agents.heard/2
  - agentConflict
  - ifHashOf
gist: "agents.list subagents:true (rows say mode); agents.get hash + broken; agents.put if_hash, conflict when changed; palette kinds; watch box is watch.get + watch_changed"
---

## Subagents: a parameter, not every row

`agents.list` takes `subagents: true` and then lists the subagents after the primaries;
every row now says its `mode`. Not chosen: listing every agent with its `mode` to
everyone. Every picker of what a session runs reads `agents.list` (the desktop app's agent
switch and start screen, the terminal's Tab chooser and palette rows, a remote client's),
and `session.create` and `profile.switch` refuse a subagent (Decision 841), so a client
older than the change would offer agents the daemon then refuses. The parameter leaves
every existing caller's answer as it was; the two managers ask for it and group by `mode`.

## Two clients editing one agent

`agents.get` gives `hash`, `"sha256:<hex>"` of `text` (the form `fs.read` and `fs_changed`
use), and `agents.put` takes it back as `if_hash`. The writer compares it with the file at
the target in the same VM-wide transaction it writes in (`Troupe.Onboard.put_file/5`), so
nothing can land between the check and the rename. A file that holds anything else, or is
gone, is not written: the answer is `conflict` with a sentence and the hash of what is
there now.

- **When a client sends it.** Only when it saves an edit back into the file it was opened
  from: the same name and layer, the rule Decision 842 uses for "the file being replaced".
  A copy into the other layer or a new agent sends none, since what it would replace there
  is not a file it read; there the last write still wins, as Decision 841 left it.
- **What a client does with the refusal.** Both keep the edit and say the daemon's
  sentence, and take the hash it carries as the edit's new base, so the next save, made
  knowingly, replaces the other change. Not chosen: merging (a definition is short, and
  both texts are in front of the person), or refusing until the edit is reopened from the
  file (which throws the person's text away or leaves them to copy it out).

This replaces the one line of Decision 841 that said a conflict between two clients is the
last write's; the rest of 841 stands.

## A file that does not parse, opened to mend

`agents.get` answers `broken`, `{scope, layer, path, text, hash, reason}`, for the
person's or the workspace's file of that name that was found and does not parse, the one
that would answer once mended (`Troupe.Agent.Local.broken/3`). Not chosen: a method of its
own (a fourth read, a permission row and a remote path for one field), or the text in
every `agents.list` row of `skipped` (the list is read on every change, and almost every
skipped file is one no client may open). Only a file at the place `agents.put` writes
counts: one linked out of the workspace is never read (Decision 829), and a main
checkout's draft in a worktree is not offered as if saving here would mend it.
