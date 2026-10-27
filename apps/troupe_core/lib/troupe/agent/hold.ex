defmodule Troupe.Agent.Hold do
  @moduledoc """
  What an agent holds for a turn, and how a restart gets it back (issue #617, Decision 876).

  As a turn's first model call begins, the agent takes the tools that come and go (the MCP
  servers' and the person's clients', `Troupe.Tools.mcp/1`, Decision 871) and the skills
  there are (`Troupe.Skills.found/3`), and offers those to the turn's end. That call's
  `llm_request` carries them as `turn_hold`: a `digest`, with the `tools` and the `skills`
  when they differ from the last hold this agent wrote whole, so a session whose tools stay
  put writes them once. An agent restarted in the middle of a turn folds them back and
  offers what the turn began with; one restarted between turns takes them afresh.

  A tool comes back as a `Hold.Tool`: its name, description, schema and default permission,
  which is all an offer reads. A call goes to the tool as it is now, or is told it went
  (`tool_gone`), as when nothing restarted.
  """

  alias Troupe.Protocol.Canonical
  alias Troupe.Skills

  defmodule Tool do
    @moduledoc "A tool a turn was offered, as its `llm_request` wrote it down."

    @enforce_keys [:name, :description, :schema]
    defstruct [:name, :description, :schema, default_permission: :ask, files: false]

    @type t :: %__MODULE__{
            name: String.t(),
            description: String.t(),
            schema: map(),
            default_permission: :auto | :ask | :deny,
            files: boolean()
          }
  end

  @typedoc "A hold as `llm_request.turn_hold` writes it: `digest`, `tools`, `skills`."
  @type json :: %{optional(String.t()) => term()}

  @permissions %{"auto" => :auto, "ask" => :ask, "deny" => :deny}
  @layers %{
    "bundle" => :bundle,
    "user_agents" => :user_agents,
    "agents" => :agents,
    "user" => :user,
    "workspace" => :workspace
  }

  @doc "A hold taken, whole: its tools and skills as JSON, and the digest of the two."
  @spec to_json([Troupe.Tool.handle()], Skills.found()) :: json()
  def to_json(tools, %{bundle: from_bundle, local: local}) do
    held = %{
      "tools" => Enum.map(tools, &tool_json/1),
      "skills" => %{
        "bundle" => Enum.map(from_bundle, &skill_json/1),
        "local" => Enum.map(local, &skill_json/1)
      }
    }

    Map.put(held, "digest", Canonical.hash(held))
  end

  @doc """
  What a call writes of the hold it took, and the hold written whole that a later one is
  compared with: the digest alone when it is the one `before` names, else the whole of it.
  """
  @spec written(json(), json() | nil) :: {json(), json()}
  def written(%{"digest" => digest}, %{"digest" => digest} = before),
    do: {%{"digest" => digest}, before}

  def written(hold, _before), do: {hold, hold}

  @doc """
  A call's `turn_hold` read back: the tools and skills it held, and the hold written whole
  that it is or names. `:error` for a digest naming none written before it, which leaves
  the next call to take the tools afresh.
  """
  @spec fold(json(), json() | nil) :: {:ok, [Tool.t()], Skills.found(), json()} | :error
  def fold(%{"tools" => _, "skills" => _} = hold, _before), do: restore(hold)
  def fold(%{"digest" => digest}, %{"digest" => digest} = before), do: restore(before)
  def fold(_hold, _before), do: :error

  defp restore(%{"tools" => tools, "skills" => skills} = hold) do
    found = %{
      bundle: Enum.map(skills["bundle"] || [], &skill/1),
      local: Enum.map(skills["local"] || [], &skill/1)
    }

    {:ok, Enum.map(tools, &tool/1), found, hold}
  end

  defp tool_json(tool) do
    %{
      "name" => Troupe.Tool.name(tool),
      "description" => description(tool),
      "schema" => Troupe.Tool.schema(tool),
      "default_permission" => Atom.to_string(Troupe.Tool.default_permission(tool))
    }
    |> put_files(tool)
  end

  # Where the organisation keeps files (the harness names it), written only where it is, so
  # a hold of any other tool reads and hashes as it always did.
  defp put_files(json, %{files: true}), do: Map.put(json, "files", true)
  defp put_files(json, _tool), do: json

  # The tools that come and go are values, whose description is what they say; a module
  # among them says its own.
  defp description(%{description: description}), do: description
  defp description(module) when is_atom(module), do: module.description()

  defp tool(json) do
    %Tool{
      name: json["name"],
      description: json["description"],
      schema: json["schema"],
      default_permission: Map.get(@permissions, json["default_permission"], :ask),
      files: json["files"] == true
    }
  end

  defp skill_json(skill) do
    %{
      "name" => skill.name,
      "description" => skill.description,
      "layer" => Atom.to_string(skill.layer),
      "dir" => skill.dir
    }
  end

  defp skill(json) do
    %{
      name: json["name"],
      description: json["description"],
      layer: Map.get(@layers, json["layer"], :user),
      dir: json["dir"]
    }
  end
end
