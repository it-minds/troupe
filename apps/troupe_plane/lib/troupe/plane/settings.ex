defmodule Troupe.Plane.Settings do
  @moduledoc """
  What a platform admin may change about this plane, and where each value comes from.

  Every setting here had a value before this module existed: an environment variable, read
  through `Application.get_env/3` at the point of use. That is the right home for what a
  *deployment* decides and the wrong one for what an *operator* does, and the difference
  showed up the first time it mattered — a plane whose `platform_admin_group` named a group
  nobody was in had no administrator, and no administrator meant no console, and the only
  repair was a Helm change and a rollout. A setting that can lock you out of the thing that
  changes settings should be changeable from behind the break-glass door.

  ## The ordering, which is the whole safety argument

  A stored row **overrides** the deployment; it never replaces it. A setting with no row
  reads whatever the plane was deployed with, and `reset/2` deletes the row rather than
  writing today's default into it — writing it back would freeze this release's default
  into the database and make the next deployment's change invisible. So the deployment
  stays the floor, and the worst a bad setting can do is be reset.

  Some settings are deliberately **not** editable and are here to be read: the audience,
  the base URL, the deployment's own tokens. Changing those from inside the console is how
  you lock every administrator out at once, and they belong to the deployment for the same
  reason a lock's keyhole is not adjustable from inside the house. They are listed anyway,
  with their values, because "where is this plane's configuration" should have one answer
  and not "some of it is here and the rest is in a values file somebody has".

  The identity provider — issuer, client id, secret, endpoints, scopes — used to be in
  that list and is not any more (Decision 664). The argument for keeping it read-only was
  the lock-out, and the lock-out has three answers that did not exist when the argument
  was made: the break-glass door opens the console without the provider; `reset/2`
  deletes the row and the deployed value is back; and `Admin.provider_put/3` refuses a
  candidate the provider's own discovery does not stand behind unless told to save
  anyway. What stays true is the ladder: the deployment is the floor, a stored value only
  ever overrides it, and the worst a bad one can do is be reset.

  Secrets are listed too and never shown. What is reported is whether one is *set*, which
  is the only thing anybody debugging can act on and the only thing that is not a leak.

  ## Freshness

  Reads go through a small table with a five-second life. `platform_admin_group` is read on
  every administrative request, and the alternative is a query per request for a value that
  changes twice a year. A change is visible immediately on the replica that made it and
  within five seconds everywhere else; a plane where an administrator is added and their
  next click is still refused would be worse than the delay, which is why the writer clears
  its own node rather than waiting.
  """

  use GenServer

  import Ecto.Query

  alias Troupe.Plane.Repo
  alias Troupe.Plane.Settings.Setting
  alias Troupe.Plane.Settings.Stored

  @settings [
    %Setting{
      key: "platform_admin_group",
      group: :administration,
      type: :string,
      app_key: :platform_admin_group,
      summary: "The identity-provider group whose members administer this whole platform.",
      consequence:
        "Members of this group can do everything here. Setting it to a group you are not in removes your own access at your next request; a break-glass session can put it back.",
      effect: :immediate
    },
    %Setting{
      key: "groups_claim",
      group: :administration,
      type: :string,
      app_key: :groups_claim,
      fallback: "groups",
      summary: "The claim in an identity token that carries a person's groups.",
      consequence:
        "Wrong, and every login arrives with no groups: nobody is a platform admin and nobody is in a team. Entra ID calls it groups; some providers use roles.",
      effect: :immediate
    },
    %Setting{
      key: "provisioning_mode",
      group: :provisioning,
      type: :enum,
      values: [:direct, :gitops],
      app_key: :provisioning_mode,
      fallback: :direct,
      summary: "Whether writing a profile changes the cluster or commits it for review.",
      consequence:
        "In gitops the console proposes and a reviewer disposes: a profile write lands as a commit and nothing changes until it is applied. In direct it changes the cluster as soon as you apply.",
      effect: :immediate
    },
    %Setting{
      key: "default_budget_micros",
      group: :team_defaults,
      type: :integer,
      fallback: 0,
      summary: "The spend ceiling a team gets when it is enabled, in millionths.",
      consequence:
        "Only for teams enabled after the change. 0 is unlimited, which is what a team gets today unless you set this.",
      effect: :next_team
    },
    %Setting{
      key: "platform_budget_micros",
      group: :administration,
      type: :integer,
      fallback: 0,
      summary: "A ceiling on everything this plane spends, in millionths. 0 is no ceiling.",
      consequence:
        "Above every team's. It only ever narrows: where the deployment was given a tighter ceiling, that one binds and this is ignored. A reservation refused here names which of the two it was.",
      effect: :immediate
    },
    %Setting{
      key: "default_person_budget_micros",
      group: :team_defaults,
      type: :integer,
      fallback: 0,
      summary: "The spend ceiling a person gets, in millionths, across every team.",
      consequence:
        "Applied to people who have not been given one of their own. 0 is unlimited, which is what everybody gets today unless you set this.",
      effect: :immediate
    },
    %Setting{
      key: "default_budget_period",
      group: :team_defaults,
      type: :enum,
      # `Identity.Team.budget_periods/0`, as atoms, and the settings test fails if the two
      # part. `daily` was here once, and every team enabled after somebody chose it was
      # refused, because a team has never accepted it.
      values: [:monthly, :never],
      # An atom, like every other enum's fallback: a setting whose type depends on whether
      # anybody has changed it is a setting every caller has to handle twice.
      fallback: :monthly,
      summary: "The period that ceiling is measured over.",
      consequence:
        "Only for teams enabled after the change. Monthly turns over on the 1st of the month (UTC); a period of never is a ceiling that does not turn over.",
      effect: :next_team
    },
    %Setting{
      key: "default_idle_timeout_seconds",
      group: :team_defaults,
      type: :integer,
      app_key: :default_idle_timeout_seconds,
      fallback: 1800,
      summary: "The longest a team may let its sessions sit idle before going dormant.",
      consequence:
        "A ceiling as well as a default: a team may set a shorter timeout and not a longer one, and the Teams page quotes this when it refuses. A dormant session costs nothing and wakes with its history.",
      effect: :immediate
    },
    %Setting{
      key: "default_cache_eviction_days",
      group: :team_defaults,
      type: :integer,
      app_key: :default_cache_eviction_days,
      fallback: 7,
      summary: "The longest a team may keep a dormant session's cache.",
      consequence:
        "A ceiling as well as a default. A team may keep a cache for fewer days and not more.",
      effect: :immediate
    },
    %Setting{
      key: "pins_allowed",
      group: :team_defaults,
      type: :boolean,
      app_key: :pins_allowed,
      fallback: true,
      summary: "Whether teams may let their members pin a session against eviction.",
      consequence:
        "Off here and no team may turn it on, whatever their own setting says. A lower rung may only narrow.",
      effect: :immediate
    },
    %Setting{
      key: "members_may_control",
      group: :team_defaults,
      type: :boolean,
      app_key: :members_may_control,
      fallback: true,
      summary: "Whether teams may let members steer a shared session rather than watch it.",
      consequence:
        "Off here and no team may turn it on. A team that has it on already stops being able to steer at the next request.",
      effect: :immediate
    },
    %Setting{
      key: "managed_permission_rules_only",
      group: :sessions,
      type: :boolean,
      app_key: :managed_permission_rules_only,
      fallback: false,
      summary: "Ignore a session's own permission rules; only the platform's apply.",
      consequence:
        "A client may still send rules and they change nothing. Turn this on where what a session may do has to be decided by somebody other than the session.",
      effect: :next_session
    },
    %Setting{
      key: "managed_mcp_servers_only",
      group: :sessions,
      type: :boolean,
      app_key: :managed_mcp_servers_only,
      fallback: false,
      summary: "Refuse client-hosted tools: only the profile's MCP servers may be used.",
      consequence:
        "`tools.register` is refused with a reason the model can relay, and nothing is registered. A personal connector on somebody's laptop is exactly what this turns off.",
      effect: :next_session
    },
    %Setting{
      key: "default_erase_after_days",
      group: :team_defaults,
      type: :integer,
      app_key: :default_erase_after_days,
      fallback: 365,
      summary: "The longest a team may keep its sessions before they are erased.",
      consequence:
        "A ceiling as well as a default: a team may shorten its retention and not lengthen it, which is the direction a retention policy has to be enforceable in. Erasure is irreversible.",
      effect: :immediate
    },
    %Setting{
      key: "default_bundle_channel",
      group: :sessions,
      type: :string,
      fallback: "stable",
      summary: "The configuration channel a new profile follows.",
      consequence:
        "A profile with no channel of its own takes this one. Existing profiles keep what they were given.",
      effect: :next_session
    },
    # -- where people sign in: the provider, editable behind a check ------------
    %Setting{
      key: "issuer",
      group: :sign_in,
      type: :string,
      app_key: [:oidc, :issuer],
      summary: "The identity provider this plane trusts, as it names itself in its discovery document.",
      consequence:
        "Every token is checked against this issuer's keys. Saving one the provider does not answer for is refused unless you say save anyway; a wrong one is undone with reset, and the break-glass door opens this console without any provider.",
      effect: :immediate
    },
    %Setting{
      key: "client_id",
      group: :sign_in,
      type: :string,
      app_key: [:oidc, :client_id],
      summary: "The application registration this plane signs people in as.",
      consequence:
        "The provider will not issue tokens for a client it has no registration for, and a token for another registration is refused here on audience.",
      effect: :immediate
    },
    %Setting{
      key: "client_secret",
      group: :sign_in,
      type: :string,
      app_key: [:oidc, :client_secret],
      secret: true,
      summary: "The client secret used to redeem an authorization code for the console.",
      consequence:
        "Never shown once saved. Without it the console's own sign-in cannot complete, though the CLI's device flow still can. Stored as it is — a secret the plane has to present cannot be hashed — so it is exactly as protected as the database.",
      effect: :immediate
    },
    %Setting{
      key: "authorization_endpoint",
      group: :sign_in,
      type: :string,
      app_key: [:oidc, :authorization_endpoint],
      summary: "Where the console sends a browser to sign in.",
      consequence: "Blank means <issuer>/authorize, which is right for most providers and wrong for Entra.",
      effect: :immediate
    },
    %Setting{
      key: "device_authorization_endpoint",
      group: :sign_in,
      type: :string,
      app_key: [:oidc, :device_authorization_endpoint],
      summary: "Where the CLI starts the device grant. Published to every client at /.well-known/troupe.",
      consequence:
        "The check compares it with what the provider publishes: an Entra v2 issuer with a v1 endpoint fails every device login with a message about the audience.",
      effect: :immediate
    },
    %Setting{
      key: "token_endpoint",
      group: :sign_in,
      type: :string,
      app_key: [:oidc, :token_endpoint],
      summary: "Where codes and device grants are exchanged for tokens. Published to every client.",
      consequence: "Checked against the provider's discovery document before it is saved.",
      effect: :immediate
    },
    %Setting{
      key: "scopes",
      group: :sign_in,
      type: :list,
      app_key: [:oidc, :scopes],
      fallback: ["openid", "profile", "email", "offline_access"],
      summary: "What a client asks the provider for, separated by spaces or commas.",
      consequence:
        "Groups are not a scope — they are a claim the provider is configured to put in the token — and asking for one makes Entra refuse every sign-in before a password is typed. Leave the default unless the provider says otherwise.",
      effect: :immediate
    },
    %Setting{
      key: "mcp_scope",
      group: :sign_in,
      type: :string,
      app_key: [:oidc, :mcp_scope],
      summary: "The scope an MCP client is told to ask for.",
      consequence:
        "Blank means <base_url>/mcp/admin, the resource's own name, which is the only name a client may send as RFC 8707's resource. Set it only where the registration exposes another.",
      effect: :immediate
    },
    # -- read-only: what this plane was deployed with ---------------------------
    %Setting{
      key: "audience",
      group: :deployment,
      type: :string,
      app_key: :audience,
      editable: false,
      fallback: "troupe-plane-api",
      summary: "What this plane's own tokens are addressed to.",
      consequence:
        "Deployment only. Workers and the plane must agree, or every token is refused.",
      effect: :restart
    },
    %Setting{
      key: "base_url",
      group: :deployment,
      type: :string,
      app_key: :base_url,
      editable: false,
      summary: "The URL this plane believes it is reached at.",
      consequence:
        "Deployment only. The OIDC redirect must match it exactly, which is the usual cause of a sign-in that returns an error instead of a session.",
      effect: :restart
    },
    %Setting{
      key: "scim_token",
      group: :deployment,
      type: :string,
      app_key: :scim_token,
      editable: false,
      secret: true,
      summary: "The bearer token the identity provider presents when it pushes users and groups.",
      consequence:
        "Deployment only, and never shown. Unset means SCIM is refused and group membership arrives only at login.",
      effect: :restart
    },
    %Setting{
      key: "breakglass_token",
      group: :deployment,
      type: :string,
      app_key: [:breakglass, :token],
      editable: false,
      secret: true,
      summary: "The token that opens the break-glass door.",
      consequence:
        "Deployment only, and never shown. Unset means the door is not there at all: /admin/breakglass answers 404 like any other path that does not exist.",
      effect: :restart
    },
    # What a person's own machine should talk to, offered to the clients through
    # `me.client_defaults`. Never a key: whoever can sign in could read it, so the key
    # stays each person's to paste into their own settings.
    %Setting{
      key: "client_provider",
      group: :client_defaults,
      type: :enum,
      values: [:anthropic, :openai],
      summary: "The provider people's own machines use: Anthropic's API, or anything that speaks OpenAI's Chat Completions.",
      consequence:
        "Unset means the clients offer no organisation defaults at all. Changing it changes what a client pre-fills next time somebody asks; nobody's saved settings change.",
      effect: :immediate
    },
    %Setting{
      key: "client_base_url",
      group: :client_defaults,
      type: :string,
      summary: "Where that provider is: a gateway's URL, or empty for the provider's own API.",
      consequence: "An OpenAI-compatible provider needs one; for Anthropic, empty means api.anthropic.com.",
      effect: :immediate
    },
    %Setting{
      key: "client_auth",
      group: :client_defaults,
      type: :enum,
      values: [:api_key, :bearer],
      fallback: :api_key,
      summary: "How the key is presented: the provider's own header, or Authorization: Bearer for a gateway.",
      consequence: "Wrong, and every request from a machine using the defaults is refused as unauthenticated.",
      effect: :immediate
    },
    %Setting{
      key: "client_model_default",
      group: :client_defaults,
      type: :string,
      summary: "The model that does the editing, as the provider names it.",
      consequence: "Pre-filled as the default model; empty leaves the client's own choice.",
      effect: :immediate
    },
    %Setting{
      key: "client_model_cheap",
      group: :client_defaults,
      type: :string,
      summary: "The cheaper model for exploring, summarising and quick questions.",
      consequence: "Pre-filled as the cheap model; empty leaves the client's own choice.",
      effect: :immediate
    },
    %Setting{
      key: "client_model_expensive",
      group: :client_defaults,
      type: :string,
      summary: "The premium model an orchestrating agent may ask for, if there is one.",
      consequence: "Pre-filled as the expensive model; empty means the default model is used for that too.",
      effect: :immediate
    }
  ]

  @by_key Map.new(@settings, &{&1.key, &1})

  @table __MODULE__
  @ttl_seconds 5

  # The panels of the Settings page, in the order they appear. A group with a heading and
  # a sentence rather than a bare heading: a section called "Provisioning" tells a reader
  # nothing they did not already know from the field beneath it.
  @groups [
    {:administration, "Who administers this platform",
     "Both of these decide whether anybody can use this console at all. Getting one wrong locks everybody out, and the break-glass door is how you get back in."},
    {:provisioning, "How a change reaches the cluster",
     "Whether the console applies a profile itself or writes a commit for somebody to review."},
    {:team_defaults, "What a new team starts with",
     "Applied when a group is enabled as a team. Changing them leaves existing teams alone; each team's own values are on the Teams page."},
    {:client_defaults, "What people's own machines talk to",
     "Offered to the desktop app and the TUI as organisation defaults for a person's local sessions: provider, URL and models. Never a key; each person pastes their own."},
    {:sessions, "What a new session runs with",
     "Defaults for work started after the change. Running sessions keep what they were given."},
    {:sign_in, "Where people sign in",
     "The identity provider, on its own screen: saved behind a check against what the provider publishes, undone with reset, and never a lock-out because the break-glass door does not need a provider."},
    {:deployment, "What this plane was deployed with",
     "Read-only here on purpose: the audience, the base URL and the deployment's own tokens. A console that could change them is a console that could shut itself. Change them in the deployment and roll it."}
  ]

  @doc """
  What a new team starts with, string-keyed for `Identity.enable_team/2`.

  From the platform's settings rather than from the schema's defaults, and here rather
  than in `Admin` because more than one thing enables teams now: an administrator on the
  Teams screen, and the SCIM connector when its switch is on. A team should start the
  same way whichever of them made it.
  """
  @spec team_defaults() :: %{String.t() => term()}
  def team_defaults do
    %{
      "budget_micros" => get("default_budget_micros"),
      "budget_period" => to_string(get("default_budget_period")),
      "idle_timeout_seconds" => get("default_idle_timeout_seconds"),
      "erase_after_days" => get("default_erase_after_days")
    }
  end

  @doc "The panels of the Settings page: a key, a heading and the sentence under it."
  @spec groups() :: [{atom(), String.t(), String.t()}]
  def groups, do: @groups

  @doc "Every setting this plane has, in the order they are shown."
  @spec definitions() :: [Setting.t()]
  def definitions, do: @settings

  @doc "One setting's definition, or `nil`."
  @spec definition(String.t()) :: Setting.t() | nil
  def definition(key), do: Map.get(@by_key, key)

  @doc """
  A setting's value, typed.

  The stored override if there is one, otherwise what the plane was deployed with,
  otherwise the fallback this release ships. Callers use this instead of
  `Application.get_env/3` — that is the whole point, and a caller still reading the
  environment directly is a setting the console cannot actually change.
  """
  @spec get(String.t()) :: term()
  def get(key) do
    case Map.fetch(@by_key, key) do
      :error -> nil
      {:ok, setting} -> value_of(setting, stored())
    end
  end

  @doc """
  Every setting with its value and where that value came from.

  A secret's value is never in the answer; `set` says whether there is one. This is what
  the console's Settings page renders and what `admin.settings.list` returns, so the
  console and a model reading over MCP are looking at exactly the same thing.
  """
  @spec all() :: [map()]
  def all do
    overrides = stored()
    Enum.map(@settings, &describe(&1, overrides))
  end

  defp describe(%Setting{} = setting, overrides) do
    stored_value = Map.get(overrides, setting.key)
    value = value_of(setting, overrides)

    base = %{
      key: setting.key,
      group: setting.group,
      type: setting.type,
      # As strings, because that is what a form option and a JSON schema hold. The
      # registry keeps them as atoms so that parsing one never has to make an atom out
      # of something a caller sent.
      values: setting.values && Enum.map(setting.values, &to_string/1),
      summary: setting.summary,
      consequence: setting.consequence,
      effect: setting.effect,
      effect_description: effect_description(setting.effect),
      editable: setting.editable,
      secret: setting.secret,
      set: not is_nil(value) and value != "",
      source: source(setting, stored_value, value),
      deployed: display(setting, deployed(setting))
    }

    if setting.secret, do: base, else: Map.put(base, :value, display(setting, value))
  end

  defp source(_setting, stored_value, _value) when is_binary(stored_value), do: :stored
  defp source(_setting, _stored, nil), do: :unset
  defp source(_setting, _stored, _value), do: :deployed

  @doc "What the effect atom means, in a sentence a person reads next to the field."
  @spec effect_description(atom()) :: String.t()
  def effect_description(:immediate), do: "Takes effect on the next request."
  def effect_description(:next_team), do: "Applies to teams enabled after the change."
  def effect_description(:next_session), do: "Applies to sessions started after the change."
  def effect_description(:restart), do: "Set at deploy time; changing it needs a rollout."

  @doc """
  Change a setting.

  Refuses anything that is not a setting, anything the deployment owns, and any value that
  does not parse as the declared type — the parse is the validation, and it happens here
  rather than at read time so a bad value is refused by the person who typed it rather than
  discovered by whatever reads it next.
  """
  @spec put(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, :unknown_setting | :not_editable | {:invalid, String.t()}}
  def put(key, value, actor) do
    with {:ok, setting} <- editable(key),
         {:ok, parsed} <- parse(setting, value) do
      %Stored{}
      |> Stored.changeset(%{key: key, value: to_string(value), updated_by: actor})
      |> Repo.insert!(
        on_conflict: {:replace, [:value, :updated_by, :updated_at]},
        conflict_target: :key
      )

      invalidate()
      {:ok, %{key: key, value: parsed, effect: effect_description(setting.effect)}}
    end
  end

  @doc "Drop a stored value, so the setting goes back to what the plane was deployed with."
  @spec reset(String.t(), String.t()) :: {:ok, map()} | {:error, :unknown_setting | :not_editable}
  def reset(key, _actor) do
    with {:ok, setting} <- editable(key) do
      Repo.delete_all(from(s in Stored, where: s.key == ^key))
      invalidate()

      {:ok,
       %{key: key, value: value_of(setting, %{}), effect: effect_description(setting.effect)}}
    end
  end

  @doc """
  What the *deployment* said, ignoring any stored override.

  The ladder's bottom rung, and the one nothing inside the console can move: a plane's
  deployed value is its floor whatever an operator does afterwards.
  """
  @spec deployed_value(String.t()) :: term()
  def deployed_value(key) do
    case Map.fetch(@by_key, key) do
      :error -> nil
      {:ok, setting} -> deployed(setting)
    end
  end

  @doc """
  What a platform admin stored for a key, or `nil` where they stored nothing.

  Distinct from `get/1`, which answers what the plane *runs on*: this says whether
  anybody has had an opinion, which is what an effective-value view has to show.
  """
  @spec stored_value(String.t()) :: term()
  def stored_value(key) do
    with {:ok, setting} <- Map.fetch(@by_key, key),
         raw when is_binary(raw) <- Map.get(stored(), key),
         {:ok, parsed} <- parse(setting, raw) do
      parsed
    else
      _none -> nil
    end
  end

  defp editable(key) do
    case Map.fetch(@by_key, key) do
      :error -> {:error, :unknown_setting}
      {:ok, %Setting{editable: false}} -> {:error, :not_editable}
      {:ok, setting} -> {:ok, setting}
    end
  end

  # -- values -----------------------------------------------------------------

  defp value_of(%Setting{} = setting, overrides) do
    case Map.get(overrides, setting.key) do
      nil ->
        deployed(setting)

      raw ->
        # A stored value that no longer parses — the type of a setting changed under it —
        # is not a crash and not a silent nil: the deployment's value is what a plane runs
        # on when it cannot read its own override.
        case parse(setting, raw) do
          {:ok, parsed} -> parsed
          {:error, _reason} -> deployed(setting)
        end
    end
  end

  defp deployed(%Setting{app_key: nil} = setting), do: setting.fallback

  defp deployed(%Setting{app_key: key} = setting) when is_atom(key) do
    presence(Application.get_env(:troupe_plane, key), setting.fallback)
  end

  # `:oidc` and `:breakglass` are keyword lists, which `get_in/2` reads with plain atom
  # keys. A plane with neither configured at all is a laptop, and `[]` answers `nil`.
  defp deployed(%Setting{app_key: [root | path]} = setting) do
    :troupe_plane
    |> Application.get_env(root, [])
    |> get_in(path)
    |> presence(setting.fallback)
  end

  defp presence(nil, fallback), do: fallback
  defp presence("", fallback), do: fallback
  defp presence(value, _fallback), do: value

  # What a reader sees. Atoms are rendered as their own text so `:direct` reads `direct`
  # rather than as an Elixir term nobody outside this codebase would recognise.
  defp display(%Setting{secret: true}, value), do: if(is_nil(value), do: nil, else: "set")
  defp display(_setting, nil), do: nil

  defp display(_setting, value) when is_atom(value) and not is_boolean(value),
    do: to_string(value)

  defp display(_setting, value), do: value

  # Everything is parsed from text: that is how it is stored, and how a form and a JSON-RPC
  # caller both send it.
  defp parse(%Setting{} = setting, value) when not is_binary(value) do
    parse(setting, to_string(value))
  end

  defp parse(%Setting{type: :string}, value), do: {:ok, value}

  # Matched against the declared atoms rather than converted. `String.to_existing_atom/1`
  # would raise for a value that happens to appear nowhere else in the codebase — which
  # `daily` did — and a settings page that raises on a valid choice is worse than one
  # that refuses an invalid one.
  defp parse(%Setting{type: :enum, values: values}, value) do
    case Enum.find(values, &(to_string(&1) == value)) do
      nil -> {:error, {:invalid, "must be one of: " <> Enum.map_join(values, ", ", &to_string/1)}}
      found -> {:ok, found}
    end
  end

  defp parse(%Setting{type: :integer}, value) do
    case Integer.parse(String.trim(value)) do
      {number, ""} -> {:ok, number}
      _other -> {:error, {:invalid, "must be a whole number"}}
    end
  end

  # Words, however somebody separates them. Stored as typed and read as a list, so a
  # form and a JSON-RPC caller both send a string and every reader gets the same shape
  # the deployment's `TROUPE_OIDC_SCOPES` was parsed into.
  defp parse(%Setting{type: :list}, value) do
    case String.split(value, ~r/[,\s]+/, trim: true) do
      [] -> {:error, {:invalid, "must name at least one"}}
      words -> {:ok, words}
    end
  end

  defp parse(%Setting{type: :boolean}, value) do
    case String.downcase(String.trim(value)) do
      yes when yes in ~w(true yes on 1) -> {:ok, true}
      no when no in ~w(false no off 0) -> {:ok, false}
      _other -> {:error, {:invalid, "must be true or false"}}
    end
  end

  # -- the stored half, and the five seconds it is remembered for --------------

  @doc "Forget what is cached on this node. The writer calls it; a test may."
  @spec invalidate() :: :ok
  def invalidate do
    :ets.delete(@table, :stored)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp stored do
    case lookup() do
      {:ok, overrides} -> overrides
      :error -> remember(from_database())
    end
  end

  defp from_database do
    Repo.all(from(s in Stored, select: {s.key, s.value})) |> Map.new()
  rescue
    # A plane answering `/healthz` before its database is reachable, or a unit test with
    # no repo: the deployment's values are a complete answer on their own.
    _error -> %{}
  catch
    # A database that goes away *during* the query rather than refusing it: a connection
    # whose owner exits takes its caller down with an exit, and an exit is not an
    # exception, so the clause above never sees it. Without this, a request reading a
    # setting at the moment a connection dies answers 500 — from a plane that had the
    # complete answer in its own configuration all along.
    :exit, _reason -> %{}
  end

  defp lookup do
    case :ets.lookup(@table, :stored) do
      [{:stored, overrides, expires_at}] when expires_at > 0 ->
        if expires_at > now(), do: {:ok, overrides}, else: :error

      _miss ->
        :error
    end
  rescue
    ArgumentError -> :error
  end

  defp remember(overrides) do
    :ets.insert(@table, {:stored, overrides, now() + @ttl_seconds})
    overrides
  rescue
    # No table means nothing is running this process — a mix task, a test that starts no
    # application. Reading the database every time is the correct behaviour there.
    ArgumentError -> overrides
  end

  defp now, do: System.system_time(:second)

  # -- the process that owns the table ----------------------------------------

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl GenServer
  def init(_opts) do
    Process.set_label("troupe plane settings")
    _table = :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end
end
