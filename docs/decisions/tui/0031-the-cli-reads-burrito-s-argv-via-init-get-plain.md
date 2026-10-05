---
number: 31
title: The CLI reads Burrito's argv via `:init.get_plain_arguments/0` when `__BURRITO` is set
date: 2026-09-11
status: accepted
paths:
  - clients/tui
gist: The CLI reads Burrito's argv via `:init.get_plain_arguments/0` when `__BURRITO` is set
---

`burrito` is a `runtime: false` dependency so `Burrito.Util.Args` is not in the release; the code mirrors that helper.
