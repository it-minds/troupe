---
number: 56
title: The brief sits immediately after the agent's own instructions, ahead of the harness block, and its preamble tells the agent to start from it rather than verify it
date: 2026-09-11
status: accepted
paths:
  - clients/tui
gist: The brief sits immediately after the agent's own instructions, ahead of the harness block, and its preamble tells the agent to start from it rather…
---

The first version said the brief "may be out of date" and that `list_files`/`grep`/`read_file` "are authoritative", which is true but reads as an instruction to go and check — an agent with a full brief in its prompt still opened by delegating two `explore` subagents and reading 40k tokens of the tree. Decision 54's guarantee (the brief is derived, never authoritative) is about what Troupe may *assume*, not about what the model should *do*: the preamble now scopes verification to the specific fact an agent is about to depend on, and the working profiles say not to spend a turn or a subagent rediscovering what the brief already covers. Position matters for the same reason — buried under the todo list it read as reference material rather than as what the agent already knows.
