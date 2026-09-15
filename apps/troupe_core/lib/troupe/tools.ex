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
    Troupe.Tools.Finish
  ]

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
  def all(session_id \\ nil), do: @builtins ++ extra() ++ remote() ++ hosted(session_id)

  defp hosted(nil), do: []
  defp hosted(session_id), do: ClientTools.list(session_id)

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
      Definition.permission(definition, Tool.name(tool), Tool.default_permission(tool)) != :deny
    end)
  end

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
    |> Kernel.++(Skills.tools(ctx.bundle, definition))
  end

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
  Decide whether a call may proceed at all, before anything is spawned.

  Returns `{:run, module, mode}`, or a `Result` the agent hands straight back to the
  model without running anything.
  """
  @spec authorize(String.t(), Definition.t(), Ctx.t()) ::
          {:run, Tool.handle(), :task | :inline} | {:reject, Result.t()}
  def authorize(name, %Definition{} = definition, %Ctx{} = ctx) do
    case fetch(name, ctx.session_id) |> or_scoped(name, definition, ctx) do
      {:error, reason} ->
        {:reject, Result.error(ctx.call_id, name, reason)}

      {:ok, tool} ->
        cond do
          not Definition.allows_tool?(definition, name) ->
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
    case Enum.find(Skills.tools(ctx.bundle, definition), &(Tool.name(&1) == name)) do
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
          Result.ok(ctx.call_id, name, content)

        {:ok, content, updates} ->
          Result.ok(ctx.call_id, name, content, %{updates: updates})

        {:defer, instruction} ->
          %Result{
            call_id: ctx.call_id,
            name: name,
            ok?: true,
            content: "",
            meta: %{defer: instruction}
          }

        {:error, reason} ->
          Result.error(ctx.call_id, name, reason)
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
end
