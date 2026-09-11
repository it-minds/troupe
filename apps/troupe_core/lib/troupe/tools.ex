defmodule Troupe.Tools do
  @moduledoc """
  The tool set, and the gate every call passes through.

  The allowlist and the permission map are enforced here, in the harness. A model
  that asks for a tool the active profile does not have gets an error tool result and
  the tool never runs — the tool list sent to the provider is a convenience for the
  model, not the security boundary.
  """

  alias Troupe.Agent.Definition
  alias Troupe.Session.Approvals
  alias Troupe.Tool
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
  """
  @spec all() :: [Tool.handle()]
  def all, do: @builtins ++ extra() ++ remote()

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

  @spec fetch(String.t()) :: {:ok, Tool.handle()} | {:error, {:unknown_tool, String.t()}}
  def fetch(name) do
    case Enum.find(all(), &(Tool.name(&1) == name)) do
      nil -> {:error, {:unknown_tool, name}}
      tool -> {:ok, tool}
    end
  end

  @doc "The tools a profile may use, in a stable order."
  @spec for_definition(Definition.t()) :: [Tool.handle()]
  def for_definition(%Definition{} = definition) do
    Enum.filter(all(), fn tool ->
      Definition.permission(definition, Tool.name(tool), Tool.default_permission(tool)) != :deny
    end)
  end

  @doc """
  The tool specs to send a provider, with descriptions rendered for this session.
  """
  @spec specs(Definition.t(), Ctx.t()) :: [Troupe.LLM.Request.tool_spec()]
  def specs(%Definition{} = definition, %Ctx{} = ctx) do
    definition
    |> for_definition()
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
    case fetch(name) do
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
