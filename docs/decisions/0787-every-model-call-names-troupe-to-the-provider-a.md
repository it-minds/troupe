---
number: 787
title: "Every model call names Troupe to the provider: a User-Agent with the version, the client and the platform everywhere, LiteLLM's tags and spend-log metadata to a gateway, OpenRouter's app headers to OpenRouter. A local session names the software and nobody, and `identify: false` sends none of it"
date: 2026-10-05
status: accepted
issue: 419
paths:
  - PROTOCOL.md
  - apps/troupe_core/lib/troupe.ex
  - apps/troupe_core/lib/troupe/agent/server.ex
  - apps/troupe_core/lib/troupe/config.ex
  - apps/troupe_core/lib/troupe/doctor.ex
  - apps/troupe_core/lib/troupe/llm/identify.ex
  - apps/troupe_core/lib/troupe/llm/providers/anthropic.ex
  - apps/troupe_core/lib/troupe/llm/providers/openai.ex
  - apps/troupe_core/lib/troupe/llm/request.ex
  - apps/troupe_core/test/support/fake_openai.exs
  - apps/troupe_core/test/troupe/agent/identify_test.exs
  - apps/troupe_core/test/troupe/doctor_test.exs
  - apps/troupe_core/test/troupe/llm/attribution_test.exs
  - apps/troupe_core/test/troupe/llm/identify_test.exs
  - apps/troupe_gateway/lib/troupe/gateway/dispatch.ex
  - apps/troupe_gateway/test/troupe/gateway/identify_test.exs
  - apps/troupe_worker/lib/troupe/worker/session/restore.ex
  - apps/troupe_worker/test/troupe/worker/identify_test.exs
  - clients/tui/lib/troupe/cli/runner.ex
  - clients/tui/lib/troupe/client/daemon/link.ex
  - clients/tui/test/troupe/cli_test.exs
gist: "Every model call names Troupe to the provider: a User-Agent with the version, the client and the platform everywhere, LiteLLM's tags and spend-log…"
---

Issue #419; TUI Decision 147. A
gateway recorded our calls under `req/0.7.4`, the HTTP client's default, with nothing
else in the headers, and a local session's body carried its id and its agent's name
in `metadata` and nothing that said Troupe. So a LiteLLM dashboard labelled the other
coding agents and not us, and nobody could split our spend by client or version.
- **What goes out**, built in one place (`Troupe.LLM.Identify`) for both adapters:
  - `User-Agent: troupe/<version> (<client>; <os>/<arch>)` on every call to every
    endpoint, product first so a prefix match on `troupe/` holds. The version is the
    build's (`Troupe.Version`); the os is `windows`, `macos` or `linux` and the arch
    the VM's `system_architecture` (`x86_64`, `aarch64`).
  - To a gateway, a `base_url` that is neither the vendor's own API nor OpenRouter:
    `x-litellm-tags: troupe,troupe-<client>,troupe-<version>` and
    `x-litellm-spend-logs-metadata`, JSON, the session's id and, only where the plane
    attributes the session, its `team`, worker `profile` and `agent`. "The vendor's
    own API" is the test that decides where a vendor's key may go
    (`Endpoint.vendor_api?/2`), so the two cannot disagree. A gateway in front of
    Anthropic's API (LiteLLM's `/v1/messages`) is a gateway too. A server that is not
    LiteLLM ignores both. A vendor's own API gets the User-Agent alone: neither has a
    convention beyond it, and the session's id is nothing it needs.
  - To OpenRouter (`openrouter.ai` or a subdomain of it), `HTTP-Referer:
    https://github.com/it-minds/troupe` and `X-Title: Troupe`, and nothing of
    LiteLLM's. Only there: they are OpenRouter's convention and nobody else reads
    them, `HTTP-Referer` is a browser's header a proxy or a firewall may act on, and a
    LiteLLM gateway in front of OpenRouter does not pass a client's headers on (its
    operator names the app there). The URL is the repository's, not a deployment's
    nor the docs site's, because OpenRouter keys an app by it and it must not move.
  - In an OpenAI-compatible body, `troupe_client` and `troupe_version` in `metadata`.
- **A local session names nobody.** Its `metadata` is `troupe_session_id`,
  `troupe_client` and `troupe_version`, and its spend-log metadata the id alone. It
  no longer sends `troupe_agent`: an agent's name is its definition's, and a
  repository's `.troupe/agents/` can name one after itself. No `user`: one value for
  every person would make them one end user at a LiteLLM gateway, under one end
  user's budget, which stops all of them at once. The Anthropic adapter sends a local
  session no `metadata.user_id` for the same reason at Anthropic, which treats it as
  the person to act on. Paths, repository names, host names and email addresses are
  not in reach of the code that builds any of this.
- **A pod session keeps what the plane attributes it with:** `user` is the owner, and
  `metadata` has `troupe_owner`, `troupe_team`, `troupe_session_id` and `troupe_agent`
  as before, and now `troupe_profile`, which the worker puts in the attribution beside
  owner and team. That is an arrangement the operator made with their gateway, older
  than this, and `identify: false` leaves it as it is.
- **The client has one source: the connection.** Every client names itself in
  `initialize` (`client_info.name`); the daemon maps the name to a word from a fixed
  list (`Identify.client/2`): `troupe` is `tui`, `troupe-headless` is `headless`,
  `troupe-gui` is `desktop`, an ACP connection is `acp`, anything else is `other`, so
  what a client calls itself never reaches a provider. The connection that creates a
  session puts its word in the session's config (`Config.client`, never from a file,
  like `attribution`), and so does the one whose command wakes a dormant session
  (`Troupe.activate/2`'s `:client`); a session already running keeps the word of the
  client that brought it up. A worker sets `worker` whatever is attached, and a
  session nobody named (`troupe bench --live`, a test) is `other`. Not by the process:
  the terminal UI embeds a daemon that the desktop app uses when it finds it first,
  and the desktop app's `troupe-daemon` serves the terminal UI the same way, so a word
  per process would name the wrong client whenever both are open. A headless run says
  `troupe-headless` (TUI Decision 147); the desktop app already said `troupe-gui`.
- **The switch.** `identify`, a boolean on the config ladder, default `true`, trusted
  scope like `base_url`, since it decides what goes out with every request: `false`
  sends no header of ours and no client in the body, and the User-Agent is the HTTP
  client's own (`req/<version>`), which is what went out before. Not a bare `troupe`,
  which would still name the software.
- **`troupe doctor`** has an `identify` line, made by the function that makes the
  headers: each header as it goes to the default model's provider, a session's id
  standing as `<session id>`, or `off`, or nothing for the fake provider. Through
  `troupe` it names the terminal UI, through `troupe-daemon` the desktop app.
- **Not in this:** the model listing and the catalog refresh (`/v1/models`, LiteLLM's
  `/model_group/info`) still go with the HTTP client's User-Agent; a `WorkerProfile`
  field that turns `identify` off for a profile's pods; a documented set of our own
  `x-troupe-*` headers for LiteLLM's `extra_spend_tag_headers`.
- **Proof:** `Troupe.LLM.IdentifyTest`, against a stand-in gateway on a loopback port
  that records each request's headers and body (on the chunk's tip it saw
  `user-agent: req/0.7.4`, no tags, and `metadata` of the session's id and its agent
  only): the User-Agent, the tags and the spend-log metadata of a local session and a
  pod's through the OpenAI-compatible adapter, the same through the Anthropic one with
  no end user, a client not on the list sent as `other`, nothing of a person, a
  repository's agent, the host or the user in a local session's call, `identify:
  false` for both, and a vendor's own API and OpenRouter told apart through a
  recording transport; `Troupe.Agent.IdentifyTest`, the session's client and switch
  on every request and the key on the ladder, a project's file only where trusted;
  `Troupe.Gateway.IdentifyTest`, a session the desktop app creates naming `desktop`, a
  headless run's `headless`, and the terminal UI that wakes it `tui`;
  `Troupe.Worker.IdentifyTest`, a pod session's call naming the worker with its
  owner, team and profile; `Troupe.DoctorTest`, the line for a gateway through both
  programs, `off` and the fake; TUI `cli_test.exs`, what a headless run calls itself.
  And the installed `troupe run --headless` and `troupe doctor` against a stand-in,
  on the pull request.
