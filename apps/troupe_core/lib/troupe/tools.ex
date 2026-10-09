defmodule Troupe.Tools do
  @moduledoc """
  The tool set, and the gate every call passes through.

  The allowlist and the permission map are enforced here, in the harness. A model
  that asks for a tool the active profile does not have gets an error tool result and
  the tool never runs — the tool list sent to the provider is a convenience for the
  model, not the security boundary.
  """

  alias Troupe.Agent.Definition
  alias Troupe.Session.{Approvals, ClientTools}
  alias Troupe.{Skills, Tool}
  alias Troupe.Tool.{Ctx, Result}

  @builtins [
    Troupe.Tools.ReadFile,
    Troupe.Tools.WriteFile,
    Troupe.Tools.EditFile,
    Troupe.Tools.ListFiles,
    Troupe.Tools.Grep,
    Troupe.Tools.Shell,
    # The only two tools that copy between `session:/` and a shared root. They are in
    # the built-in set rather than added by the worker so that a profile's allowlist can
    # name them whether or not the session turns out to have a team volume.
    Troupe.Tools.Publish,
    Troupe.Tools.Import,
    Troupe.Tools.TodoWrite,
    Troupe.Tools.TodoRead,
    Troupe.Tools.Delegate,
    Troupe.Tools.Finish,
    # What a branch of this session (Decision 646) said when it finished.
    Troupe.Tools.ReadBranch,
    # The project brief (Decision 649): the one file a tool may write unasked.
    Troupe.Tools.Remember,
    # The rest of a cut shell or grep result (Decision 650).
    Troupe.Tools.ReadOutput,
    # The four the TUI's harness had and the core lacked (Decisions 651 and 652).
    Troupe.Tools.AskUser,
    Troupe.Tools.WebFetch,
    Troupe.Tools.GitRead,
    Troupe.Tools.Glob,
    # Onboarding another tool's files into Troupe's own (Decision 823).
    Troupe.Tools.OnboardWrite
  ]

  # The task list's tools, and the model calls a turn makes before a profile that did not
  # name them is offered them (Decision 793).
  @task_list ~w(todo_write todo_read)
  @task_list_after 10

  # Tools a profile has only when it names them (Decision 823): `onboard_write` writes the
  # files that decide what runs, which is the librarian's job, and an agent with every
  # tool (`build`) is neither offered it nor let call it.
  @named_only ~w(onboard_write)

  @doc """
  Every tool available, built-ins plus anything registered in `:extra_tools`.

  The extension point exists so a later MCP adapter can register remote tools as
  ordinary `Troupe.Tool` implementations without touching the agent loop, and the
  test suite uses it to install tools that misbehave on purpose.

  A session id adds the tools an attached client hosts for *that* session. They are
  per-session because the connection offering them is: a personal MCP connection belongs
  to one person on one session, and a pod-wide list would hand it to everybody.
  """
  @spec all(String.t() | nil) :: [Tool.handle()]
  def all(session_id \\ nil),
    do: @builtins ++ extra() ++ remote() ++ local(session_id) ++ hosted(session_id)

  defp hosted(nil), do: []
  defp hosted(session_id), do: ClientTools.list(session_id)

  # The workspace's own MCP servers (Decision 654): per session, because the config is.
  defp local(nil), do: []
  defp local(session_id), do: Troupe.Session.MCP.tools(session_id)

  defp extra, do: Application.get_env(:troupe_core, :extra_tools, [])

  # Tools discovered from MCP servers, as values rather than modules. They go through
  # everything below exactly as a built-in does — which is the point.
  defp remote do
    case Application.get_env(:troupe_core, :remote_tools) do
      nil -> []
      fun when is_function(fun, 0) -> fun.()
      tools when is_list(tools) -> tools
    end
  end

  @spec fetch(String.t(), String.t() | nil) ::
          {:ok, Tool.handle()} | {:error, {:unknown_tool, String.t()}}
  def fetch(name, session_id \\ nil) do
    case Enum.find(all(session_id), &(Tool.name(&1) == name)) do
      nil -> {:error, {:unknown_tool, name}}
      tool -> {:ok, tool}
    end
  end

  @doc "The tools a profile may use, in a stable order."
  @spec for_definition(Definition.t(), String.t() | nil) :: [Tool.handle()]
  def for_definition(%Definition{} = definition, session_id \\ nil) do
    Enum.filter(all(session_id), fn tool ->
      name = Tool.name(tool)

      named?(definition, name) and
        Definition.permission(definition, name, Tool.default_permission(tool)) != :deny
    end)
  end

  # A named-only tool is a profile's when its list names it, not when it has every tool.
  defp named?(%Definition{tools: :all}, name), do: name not in @named_only
  defp named?(%Definition{}, _name), do: true

  @doc """
  The tools a profile may use in one agent's context: everything `for_definition/2`
  gives it, plus the `skill` tool when the session's bundle has skills the profile
  lists, less any MCP server this session's team is not entitled to.

  The skill tool is scoped to the context rather than registered pod-wide because it
  reads the bundle *this session* is pinned to, and two sessions on one pod may be
  pinned to different versions. The entitlement filter is here for the same reason and
  one more: **discovery stays pod-wide**. Asking four servers for their tool list at
  every create would put somebody else's latency on the create path, so the pod
  discovers once and each session composes its own list from what was discovered. A
  session that may not use `jira` does not see `mcp.jira.*`; the pod still knows the
  tools exist.
  """
  @spec available(Definition.t(), Ctx.t()) :: [Tool.handle()]
  def available(%Definition{} = definition, %Ctx{} = ctx) do
    definition
    |> for_definition(ctx.session_id)
    |> entitled_servers(ctx.bundle)
    |> Kernel.++(Skills.tools(ctx.bundle, definition, skills_root(ctx)))
    |> Kernel.++(loop_tools(ctx))
    |> task_list(definition, ctx)
  end

  # The task list (Decision 793). A profile that names `todo_write`, as `plan` and
  # `workflow` do, has it on every call: the list is what it is for. One with every tool,
  # as `build`, is offered it while there is a list and once its turn has made ten model
  # calls, and not before: a model that answers with one call a response paid a call for
  # a list and one for each update, on tasks of a few calls, whatever its prompt said. A
  # call to it unoffered still runs, as the profile allows it.
  defp task_list(tools, %Definition{tools: :all}, %Ctx{todos: [], turn_calls: calls})
       when calls < @task_list_after,
       do: Enum.reject(tools, &(Tool.name(&1) in @task_list))

  defp task_list(tools, _definition, _ctx), do: tools

  # The person's own skills are read beside the workspace (Decision 700), and only when
  # there is one to read beside: a context built without a workspace has no layer.
  defp skills_root(%Ctx{workspace: %Troupe.Workspace{root_real: root}}), do: root
  defp skills_root(%Ctx{}), do: nil

  # A loop's structured verdict (Decision 679), on the turns a running loop started and
  # no others, and outside the profile's list: it changes nothing but whether the loop
  # goes on, and a loop whose agent could not say "done" would only ever stop at its cap.
  defp loop_tools(%Ctx{loop: loop}) when is_binary(loop), do: [Troupe.Tools.GoalComplete]
  defp loop_tools(%Ctx{}), do: []

  defp entitled_servers(tools, %{entitlements: %{"mcp_servers" => names}}) when is_list(names) do
    entitled = MapSet.new(names)

    Enum.reject(tools, fn tool ->
      case Troupe.MCP.server_of(Tool.name(tool)) do
        nil -> false
        server -> not MapSet.member?(entitled, server)
      end
    end)
  end

  defp entitled_servers(tools, _bundle), do: tools

  @doc """
  The tool specs to send a provider, with descriptions rendered for this session.
  """
  @spec specs(Definition.t(), Ctx.t()) :: [Troupe.LLM.Request.tool_spec()]
  def specs(%Definition{} = definition, %Ctx{} = ctx) do
    definition
    |> available(ctx)
    |> Enum.map(fn tool ->
      %{name: Tool.name(tool), description: Tool.describe(tool, ctx), schema: Tool.schema(tool)}
    end)
  end

  @doc """
  Which credential a call to this tool would go out as, or `nil` where the question does
  not arise.

  Only an MCP server has two answers, so only an MCP tool gets one. A built-in runs as
  the pod and a client-hosted tool runs on somebody's laptop; neither is a credential
  anybody chose, and an `identity` on those events would be a field that always said the
  same thing.
  """
  @spec identity_of(String.t(), Ctx.t()) :: Troupe.Protocol.Principal.t() | nil
  def identity_of(name, %Ctx{} = ctx) do
    with server when is_binary(server) <- Troupe.MCP.server_of(name),
         %Troupe.MCP.Tool{server: ^server} = tool <- find_mcp_tool(name, ctx) do
      Troupe.MCP.identity(tool_server(tool), ctx)
    else
      _ -> nil
    end
  end

  defp find_mcp_tool(name, ctx) do
    Enum.find(all(ctx.session_id), &(Tool.name(&1) == name))
  end

  # The tool carries its server's name; the configured server is where the mode is. A
  # tool whose server has gone from the configuration answers as a profile one, which is
  # what it was before anybody wrote a mode.
  defp tool_server(%Troupe.MCP.Tool{server: name}) do
    Enum.find(
      configured_servers(),
      %Troupe.MCP.Server{name: name, url: ""},
      &(&1.name == name)
    )
  end

  defp configured_servers do
    case Application.get_env(:troupe_core, :mcp_servers) do
      fun when is_function(fun, 0) -> fun.()
      list when is_list(list) -> list
      _none -> []
    end
  end

  @doc """
  Decide whether a call may proceed at all, before anything is spawned.

  Returns `{:run, module, mode}`, or a `Result` the agent hands straight back to the
  model without running anything.
  """
  @spec authorize(String.t(), Definition.t(), Ctx.t()) ::
          {:run, Tool.handle(), :task | :inline} | {:reject, Result.t()}
  def authorize(name, %Definition{} = definition, %Ctx{} = ctx) do
    case Enum.find(loop_tools(ctx), &(Tool.name(&1) == name)) do
      nil -> authorize_listed(name, definition, ctx)
      tool -> {:run, tool, Tool.mode(tool)}
    end
  end

  defp authorize_listed(name, definition, ctx) do
    case fetch(name, ctx.session_id) |> or_scoped(name, definition, ctx) do
      {:error, reason} ->
        {:reject, Result.error(ctx.call_id, name, reason)}

      {:ok, tool} ->
        cond do
          not (Definition.allows_tool?(definition, name) and named?(definition, name)) ->
            {:reject, Result.error(ctx.call_id, name, {:not_allowed, name})}

          Definition.permission(definition, name, Tool.default_permission(tool)) == :deny ->
            {:reject, Result.error(ctx.call_id, name, {:denied_by_policy, name})}

          true ->
            {:run, tool, Tool.mode(tool)}
        end
    end
  end

  # The pod-wide list first, then the session-scoped tools. A name found in neither is
  # unknown; a session-scoped tool the profile does not qualify for is unknown too,
  # because for that profile it was never offered.
  defp or_scoped({:ok, tool}, _name, _definition, _ctx), do: {:ok, tool}

  defp or_scoped({:error, reason}, name, definition, ctx) do
    case Enum.find(Skills.tools(ctx.bundle, definition, skills_root(ctx)), &(Tool.name(&1) == name)) do
      nil -> {:error, reason}
      tool -> {:ok, tool}
    end
  end

  @doc """
  Run a `:task` tool, blocking on approval if the profile asks for one.

  Called from inside a task under the agent's `Agent.Tasks` supervisor, never from
  the agent process: it can block for a human, and it must be killable.
  """
  @spec run_task(Tool.handle(), map(), Definition.t(), Ctx.t()) :: Result.t()
  def run_task(tool, args, %Definition{} = definition, %Ctx{} = ctx) do
    name = Tool.name(tool)

    case Definition.permission(definition, name, Tool.default_permission(tool)) do
      :ask ->
        case ask(ctx, name, args) do
          :allow -> execute(tool, args, ctx)
          :deny -> Result.error(ctx.call_id, name, {:denied, name})
          {:deny, :unattended} -> Result.error(ctx.call_id, name, {:denied_unattended, name})
        end

      :auto ->
        execute(tool, args, ctx)

      :deny ->
        Result.error(ctx.call_id, name, {:denied_by_policy, name})
    end
  end

  defp ask(ctx, name, args) do
    Approvals.request(ctx.session_id, %{
      call_id: ctx.call_id,
      tool: name,
      args: args,
      agent_path: ctx.agent_path
    })
  end

  @doc """
  Run a tool and normalise whatever it returns into a `Result`.

  A tool that raises, throws or exits becomes an error result — the one place the
  "let it crash" rule is deliberately suspended, because the model needs the failure
  as feedback in order to correct itself.
  """
  @spec execute(Tool.handle(), map(), Ctx.t()) :: Result.t()
  def execute(tool, args, %Ctx{} = ctx) do
    name = Tool.name(tool)

    try do
      case Tool.invoke(tool, args, ctx) do
        {:ok, content} ->
          Result.ok(ctx.call_id, name, text(content))

        {:ok, content, updates} ->
          Result.ok(ctx.call_id, name, text(content), %{updates: updates})

        {:defer, instruction} ->
          %Result{
            call_id: ctx.call_id,
            name: name,
            ok?: true,
            content: "",
            meta: %{defer: instruction}
          }

        {:error, reason} ->
          Result.error(ctx.call_id, name, text(reason))
      end
    rescue
      error ->
        Result.error(ctx.call_id, name, {:tool_crashed, Exception.message(error)})
    catch
      :throw, value ->
        Result.error(ctx.call_id, name, {:tool_crashed, "threw #{inspect(value)}"})

      :exit, reason ->
        Result.error(ctx.call_id, name, {:tool_crashed, "exited with #{inspect(reason)}"})
    end
  end

  # A result goes into the log and to the model, both JSON, which holds only UTF-8. Bytes
  # that are not (what a command printed, a binary file, a cut inside a character) are
  # replaced here, where every tool's result passes, rather than in each tool: the log
  # refusing one stopped the session mid-turn (#493).
  defp text(content) when is_binary(content), do: String.replace_invalid(content)
  defp text(other), do: other
end
