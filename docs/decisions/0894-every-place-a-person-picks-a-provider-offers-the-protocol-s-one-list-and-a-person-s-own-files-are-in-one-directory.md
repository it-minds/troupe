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
  - apps/troupe_protocol/lib/troupe/protocol/organisation.ex
  - apps/troupe_core/lib/troupe/llm/provider_type.ex
  - apps/troupe_core/lib/troupe/setup.ex
  - apps/troupe_core/lib/troupe/config/model_settings.ex
  - apps/troupe_core/lib/troupe/config/schema.ex
  - apps/troupe_core/lib/troupe/paths.ex
  - apps/troupe_core/lib/troupe/mcp/local.ex
  - clients/tui/lib/troupe/cli/config_setup.ex
  - clients/tui/lib/troupe/ui/setup.ex
  - clients/tui/lib/troupe/settings.ex
  - clients/tui/lib/troupe/remote/credentials.ex
  - clients/tui/lib/troupe/client.ex
  - clients/tui/lib/mix/tasks/troupe.xref.ex
  - clients/gui/packages/client/src/setup.ts
  - clients/gui/packages/client/src/config.ts
  - clients/gui/apps/desktop/src/views/Models.tsx
  - clients/gui/apps/desktop/src/views/Onboarding/Provider.tsx
  - clients/gui/apps/desktop/src/views/Onboarding/Key.tsx
  - apps/troupe_plane/lib/troupe/plane/settings.ex
  - apps/troupe_plane/lib/troupe/plane/fleet/profile.ex
  - clients/gui/apps/console/src/views/Profiles.tsx
  - charts/troupe/crds/workerprofile.yaml
  - apps/troupe_operator/lib/troupe/operator/resources.ex
  - .github/workflows/cluster.yml
  - docs/user/configuration/*.md
  - apps/troupe_core/test/troupe/config/cookbook_test.exs
symbols:
  - Troupe.Protocol.ProviderTypes.wire/0
  - Troupe.Setup.kinds/0
  - Troupe.Paths.config_file/2
gist: Provider types are Troupe.Protocol.ProviderTypes for every chooser; a profile's llm fields need llm.endpoint; own files in one dir, old Windows ones moved
---

Issue #658, slice 2, after Decision 887: the four new provider types offered everywhere a
person picks a provider, the Windows path split resolved, and a tested cookbook.

**What the tip did.** Slice 1 made a config file take `ollama`, `openrouter`,
`azure_openai` and `gemini`, and left every chooser as it was. The daemon's first-run flow
(`Troupe.Setup`, which `troupe setup` and the desktop app's first run both walk) refused
them: `provider must be one of anthropic, openai, fake, not "ollama"`. `troupe config`'s
questions offered Anthropic, or OpenAI and a gateway. The terminal UI's settings page had
no provider. The desktop app's first run had four hand-kept cards and its Models panel two
options. On the plane, the provider offered to people's machines (`client_provider`) took
`anthropic` and `openai`, the profile editor offered `openai`, `anthropic` and `fake`, and
the WorkerProfile resource's enum had those three, so a profile naming `gemini` was refused
by the cluster.

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

The clients that are not Elixir read the list from the daemon: `config.get` carries
`provider_types` (`ProviderTypes.wire/0`) and `setup.get` carries `kinds`
(`ProviderTypes.kinds/0`, which `Troupe.Setup.kinds/0` answers: every named type, then the
two ways to an OpenAI-compatible gateway, each saying what it asks). The terminal client
reads the protocol module itself, which its `mix troupe.xref` now lets it, as one of the
harness's doors, rather than the core's `ProviderType` or `Troupe.Setup`; its screens go
through `Troupe.Client.setup_kinds/1`, the flow's `kinds`. The desktop app's only fallback is what a daemon from
before this change takes, which it does not list: offering one of today's types to such a
daemon would only be refused. The GUI's fake daemon carries the daemon's answer as a test
fixture. The WorkerProfile resource's enum is YAML, so a test holds it equal to the
protocol's names; the plane checks `llm.provider` against them too, as it checks
`personalTools`, so a profile that is never a resource is refused in the same words.

**Each place asks only what its type needs.** Ollama takes no key: the first run asks for
its models as soon as the provider is answered and its path has no key step, `troupe
config` asks no key, the Models panel hides the key field, and a profile has no credential
to reference. Ollama's address is asked with its default offered, which an empty answer
takes. Azure has no address of its own: every chooser requires its `base_url` (the plane:
`llm.endpoint`), and with no variable to stand in, its key is required, where a gateway
may go without one. The vendors (Anthropic, OpenAI, OpenRouter, Gemini) are asked no
address in the first run, and their variable is offered where it is set. The terminal UI's
settings page offers `provider` as a menu, each type saying what else it needs, and leaves
the address and key to `troupe setup`: the page edits one key at a time, and `provider` is
now a labelled key of the schema, so it is the desktop app's to show too.

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
sentence, and keeps the profile's row as it was. Release note: a WorkerProfile's `llm`
settings without `llm.endpoint` are now refused; they used to be ignored.

**The Windows path split: one directory, with the older files moved in.** #122 named
`config.yaml` under `%APPDATA%` and `credentials.json` and `mcp.json` under `~/.config`.
That was the old command-line client's layout (its credentials, and a personal MCP file
read from `$HOME/.config`); the code has used `Troupe.Paths.config_dir/0` for all three
since that client went, and only the documentation still said otherwise in places. Of the
two ways the slot allowed, one place with a migration was taken over documenting the
split, because the split is gone from the code and documenting it would describe a layout
no build writes, while a person who used the older one would still find their sign-in
and servers missing. `Troupe.Paths.config_file/2` is how `credentials.json` and `mcp.json`
are found: on Windows, with `TROUPE_CONFIG_HOME` unset (the old client honoured it too), a
file that is in `~\.config\troupe` (`%XDG_CONFIG_HOME%\troupe` where that is set) and not
in `%APPDATA%\troupe` is moved there the first time it is asked for, and restricted to its
owner. Moved, not read in place, so every later read and write is of one copy; when both
exist the one under `%APPDATA%` wins and the other is left for the person. One page,
`docs/user/configuration/files.md`, says where each file is, and the others link to it.

**The cookbook.** `docs/user/configuration/` has a complete, annotated file for each
recipe #658 lists, each after a `<!-- recipe: NAME -->` marker, and
`Troupe.Config.CookbookTest` loads every one through the reader Troupe uses for it: the
strict reader for each YAML file and then the whole load, `Troupe.MCP.Local` for
`mcp.json`, `agents.put`'s check for the agent, the skill layers for the skill. The test
fails when a recipe is missing, appears twice, stops loading, or stops meaning what its
page says.

**Not here.** Per-tool permission rules, #658's last part. Bedrock and Vertex, which are
not provider types (Decision 887). The VS Code extension's settings, which is not a
default path. The new admin console (`/console`) has no profile editor yet; the one under
`/admin` is the one changed.

**Proof:** `Troupe.SetupTest` "every provider type" (each a kind in the list's order; Ollama
against its stand-in with no key step and no key sent; Azure's address and key required
and its key not tried; OpenRouter's key checked and its variable offered), failing on the
tip with `provider must be one of anthropic, openai, fake, not "ollama"`;
`Troupe.Paths.ConfigFileTest` (an older `credentials.json` and `mcp.json` moved in and
restricted, both places, `TROUPE_CONFIG_HOME`, elsewhere, one directory for all);
`Troupe.Config.CookbookTest`; `Troupe.Plane.ClientDefaultsTest` (every type offered to
machines; `gemini` refused on the tip), `Troupe.Plane.AdminTest` (the resource's enum is
the protocol's names with no default; its `spec.llm` rule names the plane's fields and
carries a plain message; `llm.provider` checked; every `llm` field refused without
`llm.endpoint`, naming the fields, each failing on the tip),
`Troupe.Plane.PanelTest` (the editor offers every type, no credential for Ollama, Azure's
endpoint required, and refuses a model without an endpoint on apply),
`Troupe.Operator.ResourcesTest` (a profile with an endpoint gives the pods every setting,
an absent provider still `openai`), and the cluster job's server-side dry run of a
profile with a model and no endpoint, refused with the rule's message, and of the same
with one, taken; the terminal client's `ConfigSetupTest` (every type numbered, Ollama
with no key, Azure's address and key, Gemini's variable), `SettingsTest` (the provider
menu) and `SetupScreenDaemonTest` (Ollama's stand-in through the screen against the
daemon, with no key step, writing the file `troupe config`'s questions write for the same
answers); the desktop app's `provider-types.test.tsx` (the first run's cards, Azure's key,
an older daemon's four, a first run with Ollama against the fake daemon, the Models
panel).
