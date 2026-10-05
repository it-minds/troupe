---
number: 54
title: Every agent's system prompt opens with a project brief kept in `.troupe/memory.md`, and once there is one the workspace survey's listing budget drops to `memory.survey_chars` (1500)
date: 2026-09-11
status: accepted
paths:
  - AGENTS.md
  - apps/troupe_core/lib/troupe/agent/server.ex
  - apps/troupe_core/lib/troupe/session/memory.ex
gist: Every agent's system prompt opens with a project brief kept in `.troupe/memory.md`, and once there is one the workspace survey's listing budget…
---

Decision 44 gave an agent a file list; it still had to read `AGENTS.md`, the build manifest and half the tree to learn what the project *is*, and threw all of it away when the branch finished — two branches started back to back each spent about 100k tokens rediscovering the same repository. The brief is markdown with YAML frontmatter, in the repo rather than the state dir so a team shares it and reviews it in a PR, parsed losslessly so hand edits and unknown headings survive a rewrite. `Session.Memory` owns the file and builds its path from the *session* workspace, so a worktree branch writes the user's checkout: one brief per repository, not one per branch. It is fetched once at `Agent.Server.init/1`, never per turn, so the prompt stays byte-stable for the provider's cache — which means a write during a branch reaches the next agent, not the current turn. Like the survey it is derived and never authoritative: not an event, ignored by replay, with `list_files` still the truth. Staleness is age (7 days) or a tracked-file drift over a tenth, deliberately not the HEAD sha, because every commit would trip that.
