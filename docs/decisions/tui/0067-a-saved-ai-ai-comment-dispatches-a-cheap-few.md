---
number: 67
title: A saved `AI!`/`AI?` comment dispatches a cheap, few-turn profile (`quick` / `answer`) instead of `/code` and `/plan`, and an agent definition can set its own `reasoning_effort`
date: 2026-09-15
status: accepted
paths:
  - apps/troupe_core/lib/troupe/agent/definition.ex
  - apps/troupe_core/lib/troupe/llm/request.ex
gist: A saved `AI!`/`AI?` comment dispatches a cheap, few-turn profile (`quick` / `answer`) instead of `/code` and `/plan`, and an agent definition can…
---

An `AI?` comment is one question about code the user is looking at; sending it to `plan` — default model, 30 turns, a prompt that tells it to write a task list and delegate — cost 4.5M tokens to answer. The mismatch is that watch mode's trigger is a keystroke while its target profiles are the ones you reach for deliberately. `answer` reads at most a file or two on the cheap model and replies in its `finish` summary (write, edit and shell denied, six turns); `quick` keeps the write tools and their `ask` permission but drops the delegation and todo-list machinery that a two-file edit does not need. Both are configurable (`watch.change_command`, `watch.question_command`) because "quick and cheap" is a judgement about the user's repository, not a fact about the harness — naming `code` and `plan` there restores the old behaviour exactly. The profile for `AI!` is called `quick` rather than `watch` because `/watch` is already the toggle in the TUI's command table and would shadow it. Effort had been a property of a *model* in a provider's config (Decision 61), which is the wrong owner: how much thinking work is worth is a property of the agent doing it, and on Anthropic `high` buys a 16k-token thinking budget on every turn regardless of whether the turn is a coding task or a one-line answer. `Definition.reasoning_effort` now beats the provider's declaration, which beats a new global `reasoning_effort` setting, resolved in one place (`Provider.effort/2`) so both adapters agree; `Request.reasoning_effort` carries it, and `nil` still means "whatever the provider says", so nothing changes for a config that never mentions it.
