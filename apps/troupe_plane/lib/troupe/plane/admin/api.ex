defmodule Troupe.Plane.Admin.API do
  @moduledoc """
  The admin JSON-RPC methods, and nothing behind them.

  Every entry here is a rename: a method name to a `Troupe.Plane.Admin` function and its
  arguments. That is deliberate and is the point of the module — if a method needed logic
  of its own, the panel and the CLI would not be getting the same behaviour, and the
  parity this whole arrangement exists to guarantee would be a claim rather than a fact.

  `Troupe.Plane.AdminParityTest` enumerates `Admin` and asserts each function appears
  here, in `troupe admin`, and in the MCP tool list.

  ## Why the table carries prose and types

  It did not always. It was a method name, a function and a list of argument names, which
  is everything a dispatcher needs and nothing a *caller* does — and there are now four
  callers, one of which is a language model reaching the platform over MCP. A model
  choosing between `admin.team.revoke` and `admin.profile.delete` has whatever the tool
  description says and nothing else, so the description is not documentation about the
  interface, it *is* the interface, and it belongs where the method is declared rather
  than in a second table somebody has to remember to update.

  So each method carries a summary, a typed argument list and a risk.
  `Troupe.Plane.Admin.MCP` projects them into JSON Schema; the parity test asserts none of
  it is missing. A method added without a summary fails the test rather than reaching a
  model as a bare name.

  `risk` is the honest one:

  * `:read` answers a question and changes nothing.
  * `:write` changes configuration. Reversible by making the opposite change.
  * `:destructive` destroys something, or stops something that is running. `confirm` names
    the argument whose value a caller must echo back — the erase dialog's rule, which the
    design gives as the model for everything irreversible, applied to a caller that has no
    dialog to read.
  """

  alias Troupe.Plane.Admin
  alias Troupe.Plane.Admin.API.{Argument, Method}
  alias Troupe.Protocol.Error

  # -- the shapes that appear in more than one method -------------------------

  # A profile's spec, as `admin.profile.put` takes it.
  @profile_properties [
    %Argument{
      name: "name",
      type: :string,
      required: true,
      description: "The profile's name, which is also the name of its WorkerProfile resource."
    },
    %Argument{
      name: "image",
      type: :string,
      required: true,
      description:
        "The worker image, as repository:tag or repository@sha256:digest. A digest pins it; a tag does not."
    },
    %Argument{
      name: "replicas",
      type: :integer,
      description: "How many pods this profile runs."
    },
    %Argument{
      name: "sessions_per_pod",
      type: :integer,
      description: "How many sessions one pod carries before placement fills the next."
    },
    %Argument{
      name: "spec",
      type: :object,
      description:
        "The rest of the WorkerProfile spec, in the resource's own camelCase: llm, egress, storage, resources, mcpServers, configBundleChannel, orgMount. Read the profile first and send it back changed rather than composing one from nothing."
    }
  ]

  @filter_properties [
    %Argument{name: "limit", type: :integer, description: "How many rows at most."},
    %Argument{name: "team", type: :string, description: "Narrow to one team, by name."},
    %Argument{name: "profile", type: :string, description: "Narrow to one profile."},
    %Argument{
      name: "state",
      type: :string,
      description: "Narrow to sessions in one state: active, dormant or read_only."
    },
    %Argument{name: "actor", type: :string, description: "Narrow to one actor's changes."},
    %Argument{name: "kind", type: :string, description: "Narrow to one kind of audit entry."},
    %Argument{name: "subject_id", type: :string, description: "Narrow to one changed thing."},
    %Argument{name: "channel", type: :string, description: "Narrow to one bundle channel."},
    %Argument{name: "trigger", type: :string, description: "Narrow to one trigger's runs."},
    %Argument{name: "status", type: :string, description: "Narrow to runs of one status."},
    %Argument{name: "origin", type: :string, description: "Narrow to one origin."},
    %Argument{
      name: "needs_review",
      type: :boolean,
      description: "Only sessions an unattended run left for a person to look at."
    }
  ]

  @team_properties [
    %Argument{
      name: "budget_micros",
      type: :integer,
      description:
        "The team's spend ceiling per period, in millionths of a currency unit. 0 is unlimited."
    },
    %Argument{name: "budget_period", type: :string, description: "monthly or daily."},
    %Argument{
      name: "idle_timeout_seconds",
      type: :integer,
      description:
        "How long a session sits idle before its actors are released and it goes dormant."
    },
    %Argument{
      name: "cache_eviction_days",
      type: :integer,
      description: "How long a dormant session keeps its cache."
    },
    %Argument{
      name: "erase_after_days",
      type: :integer,
      description: "How long a session is kept at all before it is erased."
    },
    %Argument{
      name: "members_may_control",
      type: :boolean,
      description: "Whether team visibility lets a member steer a session or only watch it."
    },
    %Argument{
      name: "pins_allowed",
      type: :boolean,
      description: "Whether members may pin a session against eviction."
    },
    %Argument{
      name: "volume_size",
      type: :string,
      description: "The team volume's size, as a Kubernetes quantity such as 10Gi."
    },
    %Argument{
      name: "volume_storage_class",
      type: :string,
      description: "The storage class the team volume is provisioned from."
    }
  ]

  @principal_properties [
    %Argument{
      name: "name",
      type: :string,
      required: true,
      description: "What this principal is for."
    },
    %Argument{
      name: "profiles",
      type: :array,
      description:
        "The profiles it may start sessions on. Empty means every profile the team has."
    }
  ]

  @trigger_properties [
    %Argument{
      name: "team",
      type: :string,
      required: true,
      description: "The team the trigger belongs to."
    },
    %Argument{
      name: "name",
      type: :string,
      required: true,
      description: "The trigger's name, unique within the team."
    },
    %Argument{name: "kind", type: :string, description: "schedule, webhook or event."},
    %Argument{
      name: "schedule",
      type: :string,
      description: "A cron expression, for a schedule trigger."
    },
    %Argument{name: "profile", type: :string, description: "The profile its sessions start on."},
    %Argument{name: "prompt", type: :string, description: "What the session is asked to do."},
    %Argument{name: "enabled", type: :boolean, description: "Whether it fires at all."}
  ]

  @methods [
    %Method{
      name: "admin.overview",
      function: :overview,
      summary:
        "Fleet health, active sessions and spend per team, scoped to what the caller administers. The first call to make.",
      risk: :read
    },
    %Method{
      name: "admin.profiles.list",
      function: :profiles_list,
      summary: "Every profile, with its pods, conditions and load.",
      risk: :read
    },
    %Method{
      name: "admin.profile.get",
      function: :profile_get,
      summary:
        "One profile in full: the spec that was asked for, what policy makes of it, and what is actually running. Read this before changing one.",
      risk: :read,
      arguments: [
        %Argument{
          name: "name",
          type: :string,
          required: true,
          description: "The profile's name."
        }
      ]
    },
    %Method{
      name: "admin.profile.put",
      function: :profile_put,
      summary:
        "Create or update a profile, returning the diff that was applied. On a GitOps plane this commits for review rather than changing the cluster.",
      risk: :write,
      arguments: [
        %Argument{
          name: "profile",
          type: :object,
          required: true,
          description:
            "The profile to write. Absent fields are not preserved: send the whole thing.",
          properties: @profile_properties
        }
      ]
    },
    %Method{
      name: "admin.profile.preview",
      function: :preview,
      summary:
        "What policy makes of a profile and what would change, without writing anything. The same check admission makes.",
      risk: :read,
      arguments: [
        %Argument{
          name: "profile",
          type: :object,
          required: true,
          description: "The profile as it would be written.",
          properties: @profile_properties
        }
      ]
    },
    %Method{
      name: "admin.profile.delete",
      function: :profile_delete,
      summary:
        "Remove a profile. Sessions on it become read-only rather than being erased, and its pods go away.",
      risk: :destructive,
      confirm: "name",
      arguments: [
        %Argument{
          name: "name",
          type: :string,
          required: true,
          description: "The profile's name."
        }
      ]
    },
    %Method{
      name: "admin.pod.drain",
      function: :pod_drain,
      summary:
        "Drain a pod: it stops taking new sessions and hands back what it was holding. Reversible, and sessions are moved rather than lost.",
      risk: :destructive,
      confirm: "worker_id",
      arguments: [
        %Argument{
          name: "worker_id",
          type: :string,
          required: true,
          description: "The worker's id, as admin.profiles.list reports it."
        }
      ]
    },
    %Method{
      name: "admin.teams.list",
      function: :teams_list,
      summary: "Teams, with their grants, budgets, volumes, retention and spend.",
      risk: :read
    },
    %Method{
      name: "admin.team.enable",
      function: :team_enable,
      summary:
        "Make an identity-provider group into a team. Enabling is the only thing Troupe adds to a group: membership stays the provider's.",
      risk: :write,
      arguments: [
        %Argument{
          name: "group",
          type: :string,
          required: true,
          description: "The group's external id in the identity provider."
        },
        %Argument{
          name: "attrs",
          type: :object,
          description: "Anything to set at the same time, as in admin.team.update.",
          properties: @team_properties
        }
      ]
    },
    %Method{
      name: "admin.team.update",
      function: :team_update,
      summary: "Change a team's budget, retention, volume or default visibility.",
      risk: :write,
      arguments: [
        %Argument{name: "name", type: :string, required: true, description: "The team's name."},
        %Argument{
          name: "attrs",
          type: :object,
          required: true,
          description: "The fields to change. Anything not named is left alone.",
          properties: @team_properties
        }
      ]
    },
    %Method{
      name: "admin.team.grant",
      function: :team_grant,
      summary: "Give a team access to a profile. Effective for sessions started after it.",
      risk: :write,
      arguments: [
        %Argument{name: "name", type: :string, required: true, description: "The team's name."},
        %Argument{
          name: "profile",
          type: :string,
          required: true,
          description: "The profile's name."
        },
        %Argument{
          name: "attrs",
          type: :object,
          description: "Grant options, such as the volume mode the team gets on this profile."
        }
      ]
    },
    %Method{
      name: "admin.team.revoke",
      function: :team_revoke,
      summary:
        "Take a profile away from a team. Sessions already running on it become read-only rather than stopping.",
      risk: :destructive,
      confirm: "profile",
      arguments: [
        %Argument{name: "name", type: :string, required: true, description: "The team's name."},
        %Argument{
          name: "profile",
          type: :string,
          required: true,
          description: "The profile's name."
        }
      ]
    },
    %Method{
      name: "admin.team.admin.add",
      function: :team_admin_add,
      summary: "Make somebody an administrator of one team.",
      risk: :write,
      arguments: [
        %Argument{name: "name", type: :string, required: true, description: "The team's name."},
        %Argument{
          name: "subject",
          type: :string,
          required: true,
          description: "The person's subject, as their identity provider issues it."
        }
      ]
    },
    %Method{
      name: "admin.team.admin.remove",
      function: :team_admin_remove,
      summary: "Take the team-admin role away. The person keeps their membership of the team.",
      risk: :write,
      arguments: [
        %Argument{name: "name", type: :string, required: true, description: "The team's name."},
        %Argument{
          name: "subject",
          type: :string,
          required: true,
          description: "The person's subject."
        }
      ]
    },
    %Method{
      name: "admin.sessions.list",
      function: :sessions_list,
      summary:
        "Session metadata: who, which profile, what state, what it cost. Never content — there is no method that returns content.",
      risk: :read,
      arguments: [
        %Argument{
          name: "filter",
          type: :object,
          description: "Narrowing, all optional.",
          properties: @filter_properties
        }
      ]
    },
    %Method{
      name: "admin.session.erase",
      function: :session_erase,
      summary:
        "Erase a session and everything it holds. Irreversible: no snapshot restores it, the owner is not notified, spend already recorded stays in the month's total, and the audit record of the erasure survives with your name on it.",
      risk: :destructive,
      confirm: "session_id",
      arguments: [
        %Argument{
          name: "session_id",
          type: :string,
          required: true,
          description: "The session's id."
        }
      ]
    },
    %Method{
      name: "admin.bundles.list",
      function: :bundles_list,
      summary: "Every version of a configuration channel, newest first.",
      risk: :read,
      arguments: [
        %Argument{
          name: "channel",
          type: :string,
          required: true,
          description: "The channel, such as stable."
        }
      ]
    },
    %Method{
      name: "admin.bundle.get",
      function: :bundle_get,
      summary: "One version of a channel: its document, its summary and its hash.",
      risk: :read,
      arguments: [
        %Argument{name: "channel", type: :string, required: true, description: "The channel."},
        %Argument{
          name: "version",
          type: :integer,
          required: true,
          description: "The version number."
        }
      ]
    },
    %Method{
      name: "admin.bundle.validate",
      function: :bundle_validate,
      summary:
        "Check a bundle without publishing it: its shape, and whether policy lets a pod reach the MCP servers it names.",
      risk: :read,
      arguments: [
        %Argument{
          name: "content",
          type: :object,
          required: true,
          description: "The bundle document: agents, skills and mcp_servers."
        }
      ]
    },
    %Method{
      name: "admin.bundle.publish",
      function: :bundle_publish,
      summary:
        "Publish a new version of a channel, which pushes config.updated to every pod on it. History is append-only: a rollback is a new version carrying the old content.",
      risk: :write,
      arguments: [
        %Argument{name: "channel", type: :string, required: true, description: "The channel."},
        %Argument{
          name: "content",
          type: :object,
          required: true,
          description: "The bundle document: agents, skills and mcp_servers."
        }
      ]
    },
    %Method{
      name: "admin.bundle.retire",
      function: :bundle_retire,
      summary: "Retire a version, so nothing new starts on it. Running sessions are untouched.",
      risk: :write,
      arguments: [
        %Argument{name: "channel", type: :string, required: true, description: "The channel."},
        %Argument{
          name: "version",
          type: :integer,
          required: true,
          description: "The version to retire."
        }
      ]
    },
    %Method{
      name: "admin.mcp.check",
      function: :mcp_check,
      summary: "Whether the cluster's egress policy lets a pod reach an MCP server at this URL.",
      risk: :read,
      arguments: [
        %Argument{name: "url", type: :string, required: true, description: "The server's URL."}
      ]
    },
    %Method{
      name: "admin.audit.list",
      function: :audit_list,
      summary: "Who changed what, newest first, with the diff of each change.",
      risk: :read,
      arguments: [
        %Argument{
          name: "filter",
          type: :object,
          description: "Narrowing, all optional.",
          properties: @filter_properties
        }
      ]
    },
    %Method{
      name: "admin.provisioning.mode",
      function: :provisioning_mode,
      summary:
        "Whether this plane applies profiles to the cluster directly or commits them for review. Worth knowing before writing one.",
      risk: :read
    },
    %Method{
      name: "admin.settings.list",
      function: :settings_list,
      summary:
        "Every platform setting: what it is set to, where that value came from, and what changing it would do.",
      risk: :read
    },
    %Method{
      name: "admin.setting.put",
      function: :setting_put,
      summary:
        "Change one platform setting. Some take effect on the next call and some at the next restart; the answer says which.",
      risk: :write,
      arguments: [
        %Argument{
          name: "key",
          type: :string,
          required: true,
          description: "The setting's key, as admin.settings.list reports it."
        },
        %Argument{
          name: "value",
          type: :string,
          required: true,
          description:
            "The new value, written as a string. It is parsed against the setting's type and refused if it does not fit."
        }
      ]
    },
    %Method{
      name: "admin.setting.reset",
      function: :setting_reset,
      summary:
        "Drop a setting's stored value, so it goes back to whatever this plane was deployed with.",
      risk: :write,
      arguments: [
        %Argument{name: "key", type: :string, required: true, description: "The setting's key."}
      ]
    },
    %Method{
      name: "admin.identity.check",
      function: :identity_check,
      summary:
        "Test the identity configuration: provider discovery, its signing keys, the endpoints this plane was given, and whether anybody actually carries the group that grants platform admin. Four named checks, each with what it proved.",
      risk: :read,
      arguments: [
        %Argument{
          name: "group",
          type: :string,
          required: false,
          description:
            "A group to check instead of the configured one, to find out who would administer this platform before making it the setting."
        }
      ]
    },
    %Method{
      name: "admin.principals.list",
      function: :principals_list,
      summary:
        "A team's service principals: what each may use, when it was last used, whether it still works.",
      risk: :read,
      arguments: [
        %Argument{name: "team", type: :string, required: true, description: "The team's name."}
      ]
    },
    %Method{
      name: "admin.principal.create",
      function: :principal_create,
      summary:
        "Create a service principal for a team. Its secret is in the answer and is not stored anywhere it can be read again.",
      risk: :write,
      arguments: [
        %Argument{name: "team", type: :string, required: true, description: "The team's name."},
        %Argument{
          name: "principal",
          type: :object,
          required: true,
          description: "What to create.",
          properties: @principal_properties
        }
      ]
    },
    %Method{
      name: "admin.principal.rotate",
      function: :principal_rotate,
      summary:
        "Mint a new secret for a principal. The old one stops working at once, so anything still using it fails until it is given the new one.",
      risk: :destructive,
      confirm: "subject",
      arguments: [
        %Argument{
          name: "subject",
          type: :string,
          required: true,
          description: "The principal's subject."
        }
      ]
    },
    %Method{
      name: "admin.principal.disable",
      function: :principal_disable,
      summary: "Disable a principal. Its next call is refused; its sessions are kept.",
      risk: :destructive,
      confirm: "subject",
      arguments: [
        %Argument{
          name: "subject",
          type: :string,
          required: true,
          description: "The principal's subject."
        }
      ]
    },
    %Method{
      name: "admin.triggers.list",
      function: :triggers_list,
      summary: "A team's triggers: what fires them, what they run, and whether they are enabled.",
      risk: :read,
      arguments: [
        %Argument{name: "team", type: :string, required: true, description: "The team's name."}
      ]
    },
    %Method{
      name: "admin.trigger.put",
      function: :trigger_put,
      summary: "Create or update a trigger.",
      risk: :write,
      arguments: [
        %Argument{
          name: "trigger",
          type: :object,
          required: true,
          description: "The trigger, whole.",
          properties: @trigger_properties
        }
      ]
    },
    %Method{
      name: "admin.trigger.delete",
      function: :trigger_delete,
      summary: "Remove a trigger. Its runs go with it; the sessions they created do not.",
      risk: :destructive,
      confirm: "name",
      arguments: [
        %Argument{name: "team", type: :string, required: true, description: "The team's name."},
        %Argument{
          name: "name",
          type: :string,
          required: true,
          description: "The trigger's name."
        }
      ]
    },
    %Method{
      name: "admin.trigger.run",
      function: :trigger_run,
      summary: "Fire a trigger now, by hand. It starts a real session and spends real money.",
      risk: :write,
      arguments: [
        %Argument{name: "team", type: :string, required: true, description: "The team's name."},
        %Argument{
          name: "name",
          type: :string,
          required: true,
          description: "The trigger's name."
        }
      ]
    },
    %Method{
      name: "admin.runs.list",
      function: :runs_list,
      summary: "A team's trigger runs, newest first.",
      risk: :read,
      arguments: [
        %Argument{
          name: "filter",
          type: :object,
          description: "Narrowing, all optional.",
          properties: @filter_properties
        }
      ]
    }
  ]

  @by_name Map.new(@methods, &{&1.name, &1})

  @doc "Every admin method, keyed by name."
  @spec methods() :: %{String.t() => Method.t()}
  def methods, do: @by_name

  @doc "Every admin method, in the order the table declares them."
  @spec list() :: [Method.t()]
  def list, do: @methods

  @doc "One method, or `nil`."
  @spec method(String.t()) :: Method.t() | nil
  def method(name), do: Map.get(@by_name, name)

  @doc "Whether a method name is an admin one."
  @spec admin_method?(String.t()) :: boolean()
  def admin_method?(name), do: Map.has_key?(@by_name, name)

  @doc "Dispatch one admin request."
  @spec call(String.t(), map(), Admin.actor()) :: {:ok, term()} | {:error, Error.t()}
  def call(name, params, actor) do
    case Map.fetch(@by_name, name) do
      :error -> {:error, Error.new(:method_not_found, %{method: name})}
      {:ok, method} -> invoke(method, params, actor)
    end
  end

  defp invoke(%Method{} = method, params, actor) do
    arguments = Enum.map(Method.argument_names(method), &argument(&1, params))
    Kernel.apply(Admin, method.function, [actor | arguments])
  end

  # `filter` and `attrs` are the two shapes a method takes a bag of options in; the rest
  # are plain values. A keyword list for the former because that is what the context
  # takes, and a context that took maps would be awkward for the CLI. A `profile`, a
  # `principal` or a `trigger` is the whole params map when it is not nested, so a
  # client may send the object flat or under its name.
  defp argument("filter", params), do: options(params["filter"] || params)
  defp argument("attrs", params), do: params["attrs"] || %{}
  defp argument("profile", params), do: params["profile"] || params
  defp argument("principal", params), do: params["principal"] || params
  defp argument("trigger", params), do: params["trigger"] || params
  defp argument("content", params), do: params["content"] || %{}
  defp argument(name, params), do: params[name]

  @known_options ~w(limit actor kind subject_id profile state team channel) ++
                   ~w(trigger status origin needs_review)

  defp options(params) when is_map(params) do
    for {key, value} <- params, key in @known_options, do: {String.to_existing_atom(key), value}
  end

  defp options(_params), do: []
end
