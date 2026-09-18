defmodule Troupe.Egress do
  @moduledoc """
  Everything this product dials, declared by the component that dials it.

  An allowlist is only trustworthy if it is generated from what the code actually reaches
  for. One written by hand is a list of what somebody remembered, and the failure it
  produces is the worst kind: a NetworkPolicy that looks complete and refuses one host at
  the moment somebody first needs it.

  So the declarations are here, beside nothing else, and three things are derived from
  them: `docs/egress-allowlist.md` (written by `mix troupe.egress`, checked in CI),
  the assertion that every fixed host is covered by the chart's `troupePolicy.allowedEgress`
  defaults, and the answer the Integrations screen shows per host.

  ## Three kinds of entry, and the difference matters

  * **`:fixed`** — a hostname in the source. `api.anthropic.com` is where the Anthropic
    provider goes unless somebody overrides it, and a deployment that allows nothing else
    still has to allow this or the product does not work. These are what the chart's
    defaults are checked against.
  * **`:configured`** — a host named by a setting rather than by the code. The identity
    provider, the object store, the key manager and the database are all somebody's, and
    the honest declaration is *which setting names it*, so an operator can resolve the list
    for their own deployment rather than guessing what we meant.
  * **`:browser`** — fetched by the reader's browser and never by a pod. The console's
    fonts are the whole of this, and they are declared because an allowlist that silently
    omitted them would have somebody hunting a NetworkPolicy for a request no pod makes.

  ## What is deliberately not here

  Anything a *profile* names. `egress.fqdns` and `egress.gitHosts` are a platform admin's
  per-profile decision and are already checked against the policy at publish and at
  admission — a generated list that mixed them in would be a list that changed when
  somebody edited a profile, which is not what a chart's defaults are for.
  """

  @typedoc "Where a host is named: in the source, by a setting, or only in a browser."
  @type kind :: :fixed | :configured | :browser

  @typedoc "One thing something dials, and why."
  @type entry :: %{
          component: String.t(),
          kind: kind(),
          host: String.t() | nil,
          setting: String.t() | nil,
          why: String.t()
        }

  @entries [
    # -- what a worker dials -------------------------------------------------
    %{
      component: "worker",
      kind: :fixed,
      host: "api.anthropic.com",
      setting: nil,
      why: "the Anthropic provider's default base URL, where a session's model calls go"
    },
    %{
      component: "worker",
      kind: :fixed,
      host: "api.openai.com",
      setting: nil,
      why: "the OpenAI provider's default base URL, for a profile configured to use it"
    },
    %{
      component: "worker",
      kind: :configured,
      host: nil,
      setting: "llm.endpoint (per profile)",
      why:
        "a gateway or a self-hosted model, where a profile names one instead of a provider's own"
    },
    %{
      component: "worker",
      kind: :configured,
      host: nil,
      setting: "egress.gitHosts (per profile)",
      why: "the git remotes a session may clone from and push to"
    },
    %{
      component: "worker",
      kind: :configured,
      host: nil,
      setting: "mcpServers[].url (per bundle)",
      why: "every MCP server a session's tools reach, named by the profile's bundle"
    },

    # -- what the plane dials ------------------------------------------------
    %{
      component: "plane",
      kind: :configured,
      host: nil,
      setting: "TROUPE_OIDC_ISSUER",
      why: "the identity provider's discovery document and its signing keys"
    },
    %{
      component: "plane",
      kind: :configured,
      host: nil,
      setting: "TROUPE_OIDC_TOKEN_URL",
      why: "exchanging an authorization code and a device grant"
    },
    %{
      component: "plane",
      kind: :configured,
      host: nil,
      setting: "DATABASE_URL",
      why: "the index, the ledger and the audit trail"
    },
    %{
      component: "plane",
      kind: :configured,
      host: nil,
      setting: "TROUPE_BAO_ADDR",
      why: "the key manager: signing session tokens, and the per-person credential paths"
    },
    %{
      component: "plane",
      kind: :configured,
      host: nil,
      setting: "object_store.endpoint",
      why: "the bucket a session's log and workspace live in"
    },
    %{
      component: "plane",
      kind: :configured,
      host: nil,
      setting: "notify_url (per trigger)",
      why:
        "where a trigger posts its outcome. Absolute and not loopback, checked at save and again at send"
    },

    # -- what the operator dials ---------------------------------------------
    %{
      component: "operator",
      kind: :configured,
      host: nil,
      setting: "the cluster's API server",
      why: "reconciling WorkerProfile resources, and the TokenReview a pod enrols with"
    },

    # -- and what a browser fetches, which is not a pod ----------------------
    %{
      component: "console (browser)",
      kind: :browser,
      host: "fonts.googleapis.com",
      setting: nil,
      why: "the console's stylesheet for IBM Plex, requested by the reader's browser"
    },
    %{
      component: "console (browser)",
      kind: :browser,
      host: "fonts.gstatic.com",
      setting: nil,
      why: "the font files themselves, requested by the reader's browser"
    }
  ]

  @doc "Every declaration, in the order a reader should meet them."
  @spec entries() :: [entry()]
  def entries, do: @entries

  @doc """
  The hosts named in the source, which a deployment's policy has to allow.

  What the chart's `troupePolicy.allowedEgress` defaults are checked against: a fixed host
  no pattern covers is a tool that fails the first time somebody uses it.
  """
  @spec fixed_hosts() :: [String.t()]
  def fixed_hosts do
    for %{kind: :fixed, host: host} <- @entries, do: host
  end

  @doc "The components that declare something, in the order they appear."
  @spec components() :: [String.t()]
  def components, do: @entries |> Enum.map(& &1.component) |> Enum.uniq()

  @doc """
  Whether one of the chart's patterns covers a host.

  The same globbing the policy itself applies — a leading `*.` matches one or more labels
  in front of the rest — so the check here and the rule in the cluster cannot disagree
  about what `*.anthropic.com` includes.
  """
  @spec covered?(String.t(), [String.t()]) :: boolean()
  def covered?(host, patterns), do: Enum.any?(patterns, &matches?(host, &1))

  defp matches?(host, "*." <> rest), do: String.ends_with?(host, "." <> rest)
  defp matches?(host, pattern), do: host == pattern
end
