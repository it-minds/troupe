defmodule Troupe.Tool.Runner do
  @moduledoc """
  Runs a tool inside the current (task) process with a timeout. This is the
  one deliberate exception to "let it crash": a raise, exit or timeout in a
  tool becomes an error result so the model can self-correct.
  """

  alias Troupe.Tool.Context

  @spec run(module(), map(), Context.t(), pos_integer()) :: Troupe.Tool.result()
  def run(mod, args, %Context{} = ctx, timeout_ms) do
    task = Task.async(fn -> mod.run(args, ctx) end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, content}} when is_binary(content) -> {:ok, content}
      {:ok, {:error, reason}} when is_binary(reason) -> {:error, reason}
      {:ok, {:error, reason}} -> {:error, inspect(reason)}
      {:ok, other} -> {:error, "tool returned unexpected value: #{inspect(other)}"}
      {:exit, reason} -> {:error, "tool crashed: #{Exception.format_exit(reason)}"}
      nil -> {:error, "tool timed out after #{timeout_ms}ms"}
    end
  end
end
