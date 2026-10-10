defmodule Troupe.Gateway.Agents do
  @moduledoc """
  `agents.list`, `agents.get`, `agents.validate`, `agents.put` and `agents.delete`: the
  agents a session here could run, each whole, checked, written and taken away (#503,
  Decision 841).

  The writes are the daemon's alone, like `mcp.*` (Decision 700): the files are the
  person's config directory and a workspace on this machine. A pod's agents are its
  bundle's, so there `agents.put` and `agents.delete` refuse, saying where they are
  changed, rather than answer `method_not_found`; reading and checking answer on both.
  Every client attached hears a write as `agents.changed`, so the desktop app's list
  follows what the terminal saved. Paths go back as a person on this platform writes them
  (`Troupe.Paths.display/1`).
  """

  alias Troupe.Agent.{Definition, Definitions, Local, Validate}
  alias Troupe.Gateway.{Connections, Worktrees}
  alias Troupe.LLM.Catalog.Store
  alias Troupe.Paths
  alias Troupe.Protocol.Error

  @type outcome :: {:ok, map()} | {:error, Error.t()}

  @doc "Dispatch one of the five."
  @spec call(String.t(), map()) :: outcome()
  def call("agents.list", params), do: list(params)
  def call("agents.get", params), do: get(params)
  def call("agents.validate", params), do: validate(params)
  def call("agents.put", params), do: on_the_daemon(fn -> put(params) end)
  def call("agents.delete", params), do: on_the_daemon(fn -> delete(params) end)
  def call(method, _params), do: {:error, Error.new(:method_not_found, %{method: method})}

  # -- reads ---------------------------------------------------------------------

  # The agents a session in this workspace could run: the built-ins, the machine's
  # `agents/`, the project's `.troupe/agents/` — resolved the way `session.create` will
  # resolve them, so a picker offers exactly what a `profile` may name. A project agent's
  # `notes` say what of it waits for the workspace to be trusted (Decision 825): a
  # session here trusts it as the user's file says, and a pod's trusts none. `skipped` is
  # each agent file found and not read, with why: one linked out of the workspace
  # (Decision 829), in a worktree one its main checkout has not committed, or one that
  # does not parse (Decision 841). Each row says what decides whether a person wants it.
  defp list(params) do
    with {:ok, workspace} <- required(params, "workspace") do
      workspace = Path.expand(workspace)
      definitions = load(workspace)
      context = row_context(workspace)

      agents =
        definitions
        |> Definitions.primaries()
        |> Enum.map(&row(&1, context))
        |> Enum.sort_by(& &1["name"])

      skipped =
        definitions
        |> Definitions.skipped()
        |> Enum.map(&(&1 |> Definitions.skipped_to_json() |> Map.delete("kind")))

      {:ok, %{"agents" => agents, "skipped" => skipped}}
    end
  end

  # One definition whole, from the session's own definitions when one is named (on a pod
  # its bundle's), read again from their files as a switch would read them, else from the
  # workspace's. With a session, the windows of its family that run it now.
  defp get(params) do
    with {:ok, name} <- required(params, "name"),
         {:ok, workspace, session} <- where(params) do
      definitions = definitions(workspace, session)

      case Definitions.fetch(definitions, name) do
        {:ok, definition} ->
          {:ok, whole(definition, workspace, session)}

        {:error, _unknown} ->
          {:error, Error.new(:not_found, %{kind: "agent", name: name})}
      end
    end
  end

  defp validate(params) do
    with {:ok, source} <- source(params),
         {:ok, workspace, _session} <- where(params) do
      checked = Validate.check(source, name: params["name"], config: config(workspace))
      {:ok, checked_json(checked)}
    end
  end

  # -- writes --------------------------------------------------------------------

  defp put(params) do
    with {:ok, name} <- required(params, "name"),
         {:ok, scope} <- scope(params),
         {:ok, source} <- source(params),
         {:ok, workspace, _session} <- where(params),
         :ok <- has_workspace(scope, workspace) do
      case Local.put(scope, workspace, name, source, config: config(workspace)) do
        {:ok, written} ->
          announce(name, scope, workspace, written.file, written.action)

          {:ok,
           %{
             "name" => name,
             "scope" => Atom.to_string(scope),
             "layer" => Atom.to_string(scope),
             "path" => Paths.display(written.file),
             "action" => Atom.to_string(written.action),
             "warnings" => Enum.map(written.warnings, &finding_json/1)
           }}

        {:error, {:invalid, checked}} ->
          {:error,
           Error.new(:invalid_params, %{
             reason: "#{name} is not saved: #{summary(checked.errors)}",
             errors: Enum.map(checked.errors, &finding_json/1),
             warnings: Enum.map(checked.warnings, &finding_json/1)
           })}

        {:error, refused} ->
          refusal(refused)
      end
    end
  end

  # The copy taken away, and the layer that answers to the name now, if any does.
  defp delete(params) do
    with {:ok, name} <- required(params, "name"),
         {:ok, scope} <- scope(params),
         {:ok, workspace, _session} <- where(params),
         :ok <- has_workspace(scope, workspace) do
      case Local.delete(scope, workspace, name) do
        {:ok, removed} ->
          announce(name, scope, workspace, removed.file, :deleted)

          {:ok,
           %{
             "name" => name,
             "scope" => Atom.to_string(scope),
             "path" => Paths.display(removed.file),
             "deleted" => true,
             "layer" => answering(workspace, name)
           }}

        {:error, :not_found} ->
          {:error,
           Error.new(:not_found, %{kind: "agent", name: name, scope: Atom.to_string(scope)})}

        {:error, refused} ->
          refusal(refused)
      end
    end
  end

  # The layer that answers to a name now, or `nil` when none does.
  defp answering(workspace, name) do
    case workspace |> load() |> Definitions.fetch(name) do
      {:ok, definition} -> Local.layer(definition)
      {:error, _none} -> nil
    end
  end

  defp on_the_daemon(write) do
    if daemon?(),
      do: write.(),
      else: {:error, Error.new(:forbidden, %{reason: Local.on_a_pod()})}
  end

  defp refusal({:read_only, sentence}), do: {:error, Error.new(:forbidden, %{reason: sentence})}

  defp refusal({:bad_name, sentence}),
    do: {:error, Error.new(:invalid_params, %{field: "name", reason: sentence})}

  defp refusal(sentence) when is_binary(sentence),
    do: {:error, Error.new(:invalid_params, %{reason: sentence})}

  defp announce(name, scope, workspace, file, action) do
    changed = %{
      "name" => name,
      "scope" => Atom.to_string(scope),
      "path" => Paths.display(file),
      "action" => Atom.to_string(action)
    }

    Connections.broadcast(
      "agents.changed",
      if(scope == :project, do: Map.put(changed, "workspace", workspace), else: changed)
    )
  end

  # -- shapes --------------------------------------------------------------------

  # What decides whether a person wants an agent, worked out once for a listing.
  defp row_context(workspace) do
    %{
      workspace: workspace,
      config: config(workspace),
      worktree: is_binary(workspace) and Worktrees.auto?(workspace),
      pod: not daemon?()
    }
  end

  defp row(%Definition{} = definition, context) do
    {available, reason} = available(definition, context.config)

    %{
      "name" => definition.name,
      "description" => definition.description,
      "source" => Atom.to_string(definition.source),
      "layer" => Local.layer(definition),
      "model" => definition.model,
      "tool_count" => definition |> Troupe.Tools.for_definition() |> length(),
      "read_only" => Local.read_only?(definition),
      "max_turns" => definition.max_turns,
      "worktree" => context.worktree,
      "available" => available,
      "reason" => reason,
      "notes" => Enum.map(definition.notes, &%{"key" => &1.key, "reason" => &1.reason})
    }
  end

  defp whole(definition, workspace, session) do
    context = row_context(workspace)
    why = Local.not_editable(definition, pod: context.pod)

    definition
    |> row(context)
    |> Map.merge(%{
      "mode" => Atom.to_string(definition.mode),
      "tools" => names(definition.tools),
      "permissions" =>
        Map.new(definition.permissions, fn {tool, p} -> {tool, Atom.to_string(p)} end),
      "budget_share" => definition.budget_share,
      "skills" => names(definition.skills),
      "prompt" => definition.prompt,
      "path" => definition.path && Paths.display(definition.path),
      "text" => text(definition.path),
      "editable" => why == nil,
      "editable_reason" => why,
      "also" =>
        Enum.map(Local.hidden(definition, workspace), fn file ->
          %{"layer" => file.layer, "path" => Paths.display(file.path)}
        end),
      "running" => running(definition.name, session)
    })
  end

  defp names(:all), do: "all"
  defp names(list), do: list

  defp text(nil), do: nil

  defp text(path) do
    case File.read(path) do
      {:ok, text} -> text
      {:error, _reason} -> nil
    end
  end

  # Whether a session could run it: a model the provider does not serve, by the list the
  # daemon already keeps (Decision 778), is the one thing that stops it here. A list
  # nobody has fetched says nothing either way.
  defp available(%Definition{model: model}, config) when is_binary(model) and config != nil do
    with resolved when is_binary(resolved) <- Troupe.Config.resolve_model(config, model),
         {:not_served, _source, _nearest} <- Store.served(config, resolved) do
      {false, "its model, #{model}, is not one the provider serves"}
    else
      _served_or_unknown -> {true, nil}
    end
  end

  defp available(_definition, _config), do: {true, nil}

  # The windows of the named session's family running the agent now: the session, the
  # branches made from it and, for a branch, the session it came from and its other
  # branches (Decision 646), as `read_branch` reads a family.
  defp running(_name, nil), do: []

  defp running(name, session) do
    family = family(session)

    %{}
    |> Troupe.list_live_sessions()
    |> Enum.filter(&(&1.id in family and &1.state == :active and &1.profile == name))
    |> Enum.sort_by(& &1.id)
    |> Enum.map(&%{"session_id" => &1.id, "parent" => Map.get(&1, :parent)})
  end

  defp family(session) do
    root = Map.get(session, :parent) || session.id

    branches =
      %{"parent" => root}
      |> Troupe.list_live_sessions()
      |> Enum.map(& &1.id)

    [root | branches]
  end

  defp checked_json(checked) do
    %{
      "ok" => checked.ok,
      "errors" => Enum.map(checked.errors, &finding_json/1),
      "warnings" => Enum.map(checked.warnings, &finding_json/1)
    }
  end

  defp finding_json(finding), do: %{"field" => finding.field, "message" => finding.message}

  defp summary([one]), do: one.message

  defp summary([first | rest]),
    do: "#{first.message}, and #{length(rest)} more (in errors)"

  # -- loading -------------------------------------------------------------------

  # A daemon trusts a workspace's agents as its user's file says; a pod trusts none
  # (Decision 825).
  defp load(workspace) do
    trusted? = daemon?() and is_binary(workspace) and Troupe.Config.trusted?(workspace)
    workspace |> Definitions.load() |> Definitions.trust(trusted?, workspace)
  end

  defp definitions(workspace, nil), do: load(workspace)

  defp definitions(workspace, session) do
    case Troupe.definitions(session.id) do
      {:ok, definitions} -> Definitions.reload(definitions)
      {:error, :no_agent} -> load(workspace)
    end
  end

  # What a model is checked against; a configuration Troupe refuses checks none.
  defp config(workspace) do
    case Troupe.Config.resolve(workspace) do
      {:ok, config, _layers} -> config
      {:error, _refused} -> nil
    end
  end

  # -- params --------------------------------------------------------------------

  # A workspace named outright, or the one a named session runs in, with the session.
  defp where(%{"session_id" => session_id} = params)
       when is_binary(session_id) and session_id != "" do
    case Troupe.get_session(session_id) do
      %{workspace: workspace} = session when is_binary(workspace) ->
        {:ok, workspace_of(params) || Path.expand(workspace), session}

      _none ->
        {:error, Error.new(:not_found, %{kind: "session", session_id: session_id})}
    end
  end

  defp where(params), do: {:ok, workspace_of(params), nil}

  defp workspace_of(%{"workspace" => workspace}) when is_binary(workspace) and workspace != "",
    do: Path.expand(workspace)

  defp workspace_of(_params), do: nil

  # `project` is a workspace's `.troupe/agents/`, and `workspace` is taken as the same, the
  # word `mcp.*` and `skills.*` use for it.
  defp scope(params) do
    case Map.get(params, "scope") do
      "user" ->
        {:ok, :user}

      scope when scope in ["project", "workspace"] ->
        {:ok, :project}

      other ->
        {:error,
         Error.new(:invalid_params, %{
           field: "scope",
           reason: "scope is user or project, not #{inspect(other)}"
         })}
    end
  end

  defp has_workspace(:project, nil),
    do:
      {:error,
       Error.new(:invalid_params, %{
         field: "workspace",
         reason: "a project agent is a workspace's: name the workspace, or a session in it"
       })}

  defp has_workspace(_scope, _workspace), do: :ok

  defp source(params) do
    case Map.get(params, "source") do
      source when is_binary(source) -> {:ok, source}
      _ -> {:error, Error.new(:invalid_params, %{field: "source", reason: "required"})}
    end
  end

  # `missing` as the dispatcher's own reads say it, which `agents.list` answered before it
  # moved here; `field` as the rest of these do.
  defp required(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, Error.new(:invalid_params, %{field: key, missing: key, reason: "required"})}
    end
  end

  defp daemon?, do: Process.whereis(Troupe.Gateway.Daemon) != nil
end
