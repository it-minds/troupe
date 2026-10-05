---
number: 634
title: Runtime config names its atoms; it does not look them up
date: 2026-09-19
status: accepted
paths:
  - apps/troupe_daemon/config/runtime.exs
  - config/runtime.exs
gist: Runtime config names its atoms; it does not look them up
---

`eval` boots
`start_clean` interactively with nothing of the application loaded, so
`binary_to_existing_atom/1` on an environment value raises there although the
embedded `start` boot gets past it — and the admin docs' recipes (rebuilding the
index, reconciling, rolling back) and the migration Job all run through `eval`. So a
value such as `TROUPE_PROVISIONING_MODE` is matched against the strings it may be,
and anything else is a named error rather than a crash in the boot script. Never
`to_existing_atom` on a value read from the environment.
