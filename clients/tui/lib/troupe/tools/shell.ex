defmodule Troupe.Tools.Shell do
  @moduledoc false
  @behaviour Troupe.Tool

  alias Troupe.OS
  alias Troupe.Session.Outputs
  alias Troupe.Tool.{Bound, Context}

  @impl true
  def name, do: "shell"

  @impl true
  def description do
    {_shell, info} = OS.Process.shell_info()

    "Run a shell command in the workspace root on #{info}. Returns the exit code and the combined stdout/stderr; long output keeps its first and last lines and the marker names the `read_output` call that returns the rest. Default timeout 120s (override with `timeout_ms`). Note: file locks held by other branches are advisory only and do not apply to shell commands; do not use shell to edit files another branch may be editing."
  end

  @impl true
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "command" => %{"type" => "string"},
        "timeout_ms" => %{"type" => "integer"}
      },
      "required" => ["command"]
    }
  end

  @impl true
  def default_permission, do: :ask

  @impl true
  def preview(%{"command" => command}, _ctx), do: "$ " <> command
  def preview(args, _ctx), do: inspect(args)

  @impl true
  def run(%{"command" => command} = args, ctx) when is_binary(command) do
    timeout = Map.get(args, "timeout_ms") || (ctx.config && ctx.config.tool_timeout_ms) || 120_000

    case OS.Process.shell(command, cd: ctx.workspace, timeout_ms: timeout) do
      {:ok, out, 0} -> {:ok, render(ctx, "exit 0", out)}
      {:ok, out, status} -> {:error, render(ctx, "exit #{status}", out)}
      {:error, :timeout, out} -> {:error, render(ctx, "timed out after #{timeout}ms", out)}
    end
  end

  def run(_, _), do: {:error, "command is required"}

  # Head and tail, because a build or a test run puts its failures, stack traces
  # and summary at the end and its command echo at the start. The status line is
  # first so it survives the cut, and the whole output is stored so the agent can
  # page through it without running the command a second time.
  defp render(ctx, status, out) do
    limits = Context.limits(ctx)
    full = status <> "\n" <> body(Bound.sanitize(out))

    Outputs.store_and_mark(
      ctx.session_id,
      full,
      Bound.head_tail(full, limits.command_head, limits.command_tail),
      limits.command_head + limits.command_tail
    )
  end

  defp body(""), do: "(no output)"
  defp body(out), do: out
end
