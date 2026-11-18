---
number: 894
title: Every place a person picks a provider offers the provider types from one list in the protocol app, which the core, the plane and the daemon's answers to clients read, each asking only what its type needs, a WorkerProfile's llm settings refused without llm.endpoint rather than ignored; and every file of a person's own is in the one config directory, the two an older build kept under ~/.config on Windows moved in the first time they are asked for
date: 2026-10-13
status: accepted
issue: 658
supersedes:
  - 887
paths:
  - apps/troupe_protocol/lib/troupe/protocol/provider_types.ex
  - apps/troupe_core/lib/troupe/llm/provider_type.ex
  - apps/troupe_core/lib/troupe/setup.ex
  - apps/troupe_core/lib/troupe/config/model_settings.ex
  - apps/troupe_core/lib/troupe/paths.ex
  - apps/troupe_plane/lib/troupe/plane/fleet/profile.ex
symbols:
  - Troupe.Protocol.ProviderTypes.wire/0
  - Troupe.Setup.kinds/0
  - Troupe.Paths.config_file/2
gist: Provider types are Troupe.Protocol.ProviderTypes for every chooser; a profile's llm fields need llm.endpoint; own files in one dir, old Windows ones moved
---

Issue #658, slice 2, after Decision 887: the four new provider types offered everywhere a
person picks a provider, the Windows path split resolved, and a tested cookbook.

**One list, in the protocol app.** Decision 887 kept the list in `Troupe.LLM.ProviderType`
alone, in the core, and let `Troupe.Protocol.Organisation` keep a copy of the names held
equal by a test, since the protocol app does not depend on the core. The plane does not
depend on the core either, and needs the names and what each type asks, so a third copy
would have followed. Instead the list moves to `Troupe.Protocol.ProviderTypes`, which every
app reaches: each type's name, the label and sentence a person reads, where it is (`url`:
`own`, the vendor's endpoint; `server`, a server of the person's with a default; `required`,
an address only the person knows; `none`) and whether it takes a key and which variable
stands in for one. `ProviderType` takes those from it and adds what speaking to the type
takes (the adapter, the model list, what a call says about Troupe, the reference's
columns), and does not compile when its rows and the protocol's names differ, in either
direction. `Organisation`'s enum reads the protocol's names, so its copy is gone. That is
the part of Decision 887 this replaces: the names are no longer `ProviderType`'s alone,
and nothing keeps a second list of them.

**Each place asks only what its type needs.** Ollama takes no key: the first run asks for
its models as soon as the provider is answered and its path has no key step, `troupe
config` asks no key, the Models panel hides the key field, and a profile has no credential
to reference. Ollama's address is asked with its default offered, which an empty answer
takes. Azure has no address of its own: every chooser requires its `base_url` (the plane:
`llm.endpoint`), and with no variable to stand in, its key is required, where a gateway
may go without one. The vendors (Anthropic, OpenAI, OpenRouter, Gemini) are asked no
address in the first run, and their variable is offered where it is set.

**A WorkerProfile's `llm` settings need `llm.endpoint`.** The operator hands the pods
the `llm` settings only with an endpoint (`llm_env`): without one it drops the whole
block, and the pods run on Troupe's built-in model settings. With every type choosable
for a profile, `provider: gemini` and a model without an endpoint would have been a
choice that silently did nothing. It is refused instead, failing closed, in two places
with one meaning: the plane's profile check (`admin.profile.put`, the editor and every
`admin.*` write, and a GitOps read of a resource) refuses a profile that sets `provider`,
`model`, `smallModel`, `secretRef` or `prices` without `llm.endpoint`, naming the fields
and saying what the pods would otherwise run on; and the resource's schema has a CEL
rule on `spec.llm` with the same meaning and a plain `message`, so a profile kept in a
repository is refused by the API server too. `llm.provider` loses its schema default
(`openai`): a default the API server filled in would be a setting nobody wrote, and the
rule would refuse an `llm: {}` for it; the operator reads an absent provider as `openai`,
as it did, so no pod changes. `llm_env` itself is unchanged.

An existing profile the cluster holds with such settings keeps running as it did, its
`llm` settings ignored. The API server's validation ratcheting keeps it valid while
`spec.llm` is unchanged, so an edit elsewhere in it goes through; an edit that touches
`spec.llm` is refused until it adds `llm.endpoint` or takes the other fields out. On a
cluster without ratcheting (Kubernetes before 1.30, or with the feature off) any edit of
it is refused until then. A GitOps plane reports such a resource as refused, with the
sentence, and keeps the profile's row as it was.

**The Windows path split: one directory, with the older files moved in.** Of the two ways
the slot allowed, one place with a migration was taken over documenting the split, because
the split is gone from the code and documenting it would describe a layout no build
writes, while a person who used the older one would still find their sign-in and servers
missing. `Troupe.Paths.config_file/2` is how `credentials.json` and `mcp.json` are found:
on Windows, with `TROUPE_CONFIG_HOME` unset (the old client honoured it too), a file that
is in `~\.config\troupe` (`%XDG_CONFIG_HOME%\troupe` where that is set) and not in
`%APPDATA%\troupe` is moved there the first time it is asked for, and restricted to its
owner. Moved, not read in place, so every later read and write is of one copy; when both
exist the one under `%APPDATA%` wins and the other is left for the person.
