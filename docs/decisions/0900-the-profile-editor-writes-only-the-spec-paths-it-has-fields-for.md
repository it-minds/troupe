---
number: 900
title: "The plane's profile editor writes only the spec paths it has fields for, and carries everything else in the spec through a save as it was loaded"
date: 2026-10-13
status: accepted
paths:
  - apps/troupe_plane/lib/troupe/plane/web/live/profile_editor.ex
  - apps/troupe_plane/test/troupe/plane/panel_test.exs
gist: "A save changes only the form's own spec paths; other spec fields and MCP row fields go back as loaded, the plane-written ones never"
---

The LiveView profile editor (`/admin/profile/<name>`) built the spec it saved from its form
fields. `admin.profile.put` replaces a profile's spec with what it is sent, so anything the
form had no field for was gone after a save. Two fields were carried through by hand,
`llm.prices` (Decision 689) and `github`, and everything else was not: `mcpIdentities`, an
MCP server row's `secretRef`, `credentialMode` and `credentialSlot`, and any field the
resource gains later. Changing a profile's egress on this page took away its identities at
the servers its bundle calls with client credentials, without a word. The chunk 34 fixers
recorded it in `docs/developer/defects.md`, and it was fixed in chunk 35.

**What is decided.** Carrying is the default, not a list of exceptions. The editor names
the paths it writes (`llm.endpoint`, `llm.provider`, `llm.model`, `llm.smallModel`,
`llm.secretRef`, `egress.fqdns`, `egress.gitHosts`, `storage`, `mcpServers`,
`configBundleChannel`, `orgMount`, `repositoryOverridesBundle`, `personalTools`). On load it
keeps the spec without those paths, and a save sends that, with what the form says merged
over it, key by key. A path the form owns that is blank is absent, as before; a path it
does not own is sent back exactly as it was loaded.

An MCP server row is kept the same way: a row the form sends is merged over the row as it
was loaded at the same position, so a server's credential settings, which have no input on
this page, survive an edit to its URL or timeout.

**Not carried.** What the plane writes into the resource itself: `replicas`,
`sessionsPerPod` and `resources` (from the size class and the scaler, refused by
`admin.profile.put` from anyone else), `teams` (from the grants) and `image` (from the row).
A spec read back from the cluster in GitOps mode may hold them, and sending them back would
have a save from a plane switched back to direct mode refused.

**The other choice** was to add each field to the form as a read-only or JSON field, or to
add each to the carried list as it was found missing. Both leave the next field the
resource gains to be dropped until someone notices, which is how `mcpIdentities` was lost.
The new console's editor (#56 slice 3) is held to the same rule: it keeps every field of
the spec it does not edit.

**Proof.** `panel_test.exs`, "keeps every part of the spec it has no field for": a profile
with `mcpIdentities`, two servers with credential settings, `github`, a field the page has
never heard of and a plane-written `sessionsPerPod` is changed and saved through the
editor; everything it has no field for is in the saved spec as it was, the change is
there, and `sessionsPerPod` is not.
