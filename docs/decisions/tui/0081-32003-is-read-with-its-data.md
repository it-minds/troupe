---
number: 81
title: "`-32003` is read with its `data`"
date: 2026-09-16
status: superseded
paths:
  - clients/tui
gist: "`-32003` is read with its `data`"
---

The contract gives -32001 to Unauthorized and -32003 to Forbidden; the live plane answers an unauthenticated call with `-32003 unauthenticated` and `data.reason` of `no_token` or `bad_signature`. A -32003 whose `data.reason` names a token problem is treated as unauthorized (refresh, then prompt for re-login); one carrying a scope is explained as a missing scope. Both codes still mean what the contract says they mean.
