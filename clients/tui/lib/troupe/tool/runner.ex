defmodule Troupe.Tool.Runner do
  @moduledoc """
  Runs a tool inside the current (task) process with a timeout. This is the
  one deliberate exception to "let it crash": a raise, exit or timeout in a
  tool becomes an error result so the model can self-correct.
  """

  alias Troupe.Session.Outputs
  alias Troupe.Tool.{Bound, Context}

  # Lines a `read_output` call returns by default when this is the cut that bit.
  @page 200

  @spec run(module(), map(), Context.t(), pos_integer()) :: Troupe.Tool.result()
  def run(mod, args, %Context{} = ctx, timeout_ms) do
    task = Task.async(fn -> mod.run(args, ctx) end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, content}} when is_binary(content) -> {:ok, bound(content, ctx)}
      {:ok, {:error, reason}} when is_binary(reason) -> {:error, bound(reason, ctx)}
      {:ok, {:error, reason}} -> {:error, inspect(reason)}
      {:ok, other} -> {:error, "tool returned unexpected value: #{inspect(other)}"}
      {:exit, reason} -> {:error, "tool crashed: #{Exception.format_exit(reason)}"}
      nil -> {:error, "tool timed out after #{timeout_ms}ms"}
    end
  end

  # The universal backstop, applied where every tool result is created and before
  # any of it reaches the conversation: escapes and invalid UTF-8 out (`Jason`
  # raises on the latter and would take the turn down with it), and a hard
  # character cap for the case no tool-specific rule catches — a minified file on
  # a single line. Output a tool already bounded is under the cap and passes
  # through untouched.
  defp bound(content, %Context{} = ctx) do
    text = Bound.sanitize(content)

    Outputs.store_and_mark(
      ctx.session_id,
      text,
      Bound.chars(text, Context.limits(ctx).max_chars),
      @page
    )
  end
end
