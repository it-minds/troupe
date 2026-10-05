---
number: 111
title: "`troupe config` with nothing to report sets the model up instead"
date: 2026-09-24
status: accepted
paths:
  - clients/tui/test/troupe/config_setup_test.exs
gist: "`troupe config` with nothing to report sets the model up instead"
---

On a machine
with no `config.yaml`, and no provider in `TROUPE_*` variables, it asks in a
terminal how the machine should reach a model. With opencode set up, it offers to
copy it (`config.import`); otherwise the choices are a plane's settings, a provider
set up here, or not now. Without a terminal it prints those choices. A report of the
defaults would have said `anthropic`, `claude-sonnet-5` and no key, which is true
and useless. Every write goes through the daemon, as `config pull`'s does. The key
prompt reads without echo in `-noshell`'s raw mode where the terminal allows it,
and says so where it cannot. Proof: `test/troupe/config_setup_test.exs`, and
`scripts/dev config` driven through a pseudo-terminal.
