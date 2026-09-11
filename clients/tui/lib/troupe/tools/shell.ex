defmodule Troupe.Tools.Shell do
  @moduledoc false
  @behaviour Troupe.Tool

  alias Troupe.OS

  @impl true
  def name, do: "shell"

  @impl true
  def description do
    {_shell, info} = OS.Process.shell_info()

    "Run a shell command in the workspace root on #{info}. Output (stdout and stderr) is returned with the exit code, capped at 200000 bytes. Default timeout 120s (override with `timeout_ms`). Note: file locks held by other branches are advisory only and do not apply to shell commands; do not use shell to edit files another branch may be editing."
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
      {:ok, out, 0} -> {:ok, if(out == "", do: "(no output)", else: out)}
      {:ok, out, status} -> {:error, "exit #{status}\n#{out}"}
      {:error, :timeout, out} -> {:error, "timed out after #{timeout}ms\n#{out}"}
    end
  end

  def run(_, _), do: {:error, "command is required"}
end
