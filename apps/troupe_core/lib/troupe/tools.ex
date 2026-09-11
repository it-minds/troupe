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
  @spec all() :: [module()]
  def all, do: @builtins ++ extra()

  defp extra, do: Application.get_env(:troupe_core, :extra_tools, [])

  @spec fetch(String.t()) :: {:ok, module()} | {:error, {:unknown_tool, String.t()}}
  def fetch(name) do
    case Enum.find(all(), &(&1.name() == name)) do
      nil -> {:error, {:unknown_tool, name}}
      module -> {:ok, module}
    end
  end

  @doc "The tools a profile may use, in a stable order."
  @spec for_definition(Definition.t()) :: [module()]
  def for_definition(%Definition{} = definition) do
    Enum.filter(all(), fn module ->
      Definition.permission(definition, module.name(), module.default_permission()) != :deny
    end)
  end

  @doc """
  The tool specs to send a provider, with descriptions rendered for this session.
  """
  @spec specs(Definition.t(), Ctx.t()) :: [Troupe.LLM.Request.tool_spec()]
  def specs(%Definition{} = definition, %Ctx{} = ctx) do
    definition
    |> for_definition()
    |> Enum.map(fn module ->
      %{name: module.name(), description: Tool.describe(module, ctx), schema: module.schema()}
    end)
  end

  @doc """
  Decide whether a call may proceed at all, before anything is spawned.

  Returns `{:run, module, mode}`, or a `Result` the agent hands straight back to the
  model without running anything.
  """
  @spec authorize(String.t(), Definition.t(), Ctx.t()) ::
          {:run, module(), :task | :inline} | {:reject, Result.t()}
  def authorize(name, %Definition{} = definition, %Ctx{} = ctx) do
    case fetch(name) do
      {:error, reason} ->
        {:reject, Result.error(ctx.call_id, name, reason)}

      {:ok, module} ->
        cond do
          not Definition.allows_tool?(definition, name) ->
            {:reject, Result.error(ctx.call_id, name, {:not_allowed, name})}

          Definition.permission(definition, name, module.default_permission()) == :deny ->
            {:reject, Result.error(ctx.call_id, name, {:denied_by_policy, name})}

          true ->
            {:run, module, Tool.mode(module)}
        end
    end
  end

  @doc """
  Run a `:task` tool, blocking on approval if the profile asks for one.

  Called from inside a task under the agent's `Agent.Tasks` supervisor, never from
  the agent process: it can block for a human, and it must be killable.
  """
  @spec run_task(module(), map(), Definition.t(), Ctx.t()) :: Result.t()
  def run_task(module, args, %Definition{} = definition, %Ctx{} = ctx) do
    name = module.name()

    case Definition.permission(definition, name, module.default_permission()) do
      :ask ->
        case ask(ctx, name, args) do
          :allow -> execute(module, args, ctx)
          :deny -> Result.error(ctx.call_id, name, {:denied, name})
        end

      :auto ->
        execute(module, args, ctx)

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
  @spec execute(module(), map(), Ctx.t()) :: Result.t()
  def execute(module, args, %Ctx{} = ctx) do
    name = module.name()

    try do
      case module.run(args, ctx) do
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
