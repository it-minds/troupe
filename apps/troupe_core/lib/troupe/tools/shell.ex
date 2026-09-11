defmodule Troupe.Tools.Shell do
  @moduledoc """
  Run a shell command in the workspace, under `reaper`.

  Every OS process Troupe starts goes through reaper, and the Port running reaper is
  owned by this tool's task. That is the whole cancellation and cleanup story: when
  the task dies for any reason — an explicit cancel, an agent crash, a supervisor
  shutdown, `kill -9` on the VM — the pipe closes and reaper kills the command's
  entire process tree. There is no cleanup code here because none could be trusted in
  the case that matters most.

  `bash` on Linux and macOS. On Windows: `bash` from Git for Windows when present,
  otherwise `pwsh`, otherwise `powershell.exe` — and the tool's description tells the
  model which one it got.
  """

  @behaviour Troupe.Tool

  alias Troupe.{Reaper, Tool}
  alias Troupe.Tools.Output

  @impl Troupe.Tool
  def name, do: "shell"

  @impl Troupe.Tool
  def description do
    "Run a shell command in the workspace root and return its combined output."
  end

  @impl Troupe.Tool
  def describe(_ctx) do
    {shell, _flag} = shell()

    """
    Run a command in the workspace root and return its combined stdout and stderr,
    plus the exit status.

    The host is #{os_name()} and the shell is #{Path.basename(shell)}. Write commands
    for that shell. The command runs with stdin at the null device: nothing
    interactive will work, so pass flags that avoid prompts.

    Long-running commands are killed at the timeout along with everything they
    spawned. Prefer the project's own test and build commands over ad-hoc scripts.
    """
    |> String.trim()
  end

  @impl Troupe.Tool
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "command" => %{"type" => "string", "description" => "The command line to run."},
        "timeout_ms" => %{
          "type" => "integer",
          "description" => "Milliseconds before the command and its children are killed."
        }
      },
      "required" => ["command"]
    }
  end

  @impl Troupe.Tool
  def default_permission, do: :ask

  @impl Troupe.Tool
  def run(args, ctx) do
    with {:ok, command} <- Tool.fetch_string(args, "command") do
      timeout = Tool.fetch_int(args, "timeout_ms", ctx.timeout_ms) || 120_000
      {shell, flag} = shell()

      case Reaper.open(ctx.workspace.root_real, [shell, flag, command]) do
        {:ok, port} -> collect(port, timeout, cap(ctx))
        {:error, :reaper_missing} -> {:error, reaper_missing_message()}
      end
    end
  end

  # Reading the port to completion is the only thing this function does; the timeout
  # simply stops reading and closes the port, which reaps the tree.
  defp collect(port, timeout, cap) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_collect(port, deadline, [], cap)
  end

  defp do_collect(port, deadline, acc, cap) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      close(port)
      {:ok, render(acc, :timeout, cap)}
    else
      receive do
        {^port, {:data, {:eol, line}}} ->
          do_collect(port, deadline, [line, "\n" | acc], cap)

        {^port, {:data, {:noeol, chunk}}} ->
          do_collect(port, deadline, [chunk | acc], cap)

        {^port, {:data, data}} when is_binary(data) ->
          do_collect(port, deadline, [data | acc], cap)

        {^port, {:exit_status, status}} ->
          {:ok, render(acc, status, cap)}
      after
        remaining ->
          close(port)
          {:ok, render(acc, :timeout, cap)}
      end
    end
  end

  defp close(port) do
    if Port.info(port), do: Port.close(port)
  catch
    # Racing the port's own exit is fine: it is already closed, which is the goal.
    :error, :badarg -> :ok
  end

  defp render(acc, status, cap) do
    output = acc |> Enum.reverse() |> IO.iodata_to_binary() |> Output.cap_tail(cap)
    body = if String.trim(output) == "", do: "(no output)", else: output

    case status do
      0 -> body
      :timeout -> body <> "\n\n[timed out; the command and everything it started were killed]"
      code -> body <> "\n\n[exit status #{code}]"
    end
  end

  @doc "The shell and its command flag for this host."
  @spec shell() :: {String.t(), String.t()}
  def shell do
    case :os.type() do
      {:win32, _} -> windows_shell()
      _ -> {System.find_executable("bash") || "/bin/sh", "-c"}
    end
  end

  defp windows_shell do
    cond do
      bash = git_bash() -> {bash, "-c"}
      pwsh = System.find_executable("pwsh") -> {pwsh, "-Command"}
      ps = System.find_executable("powershell.exe") -> {ps, "-Command"}
      true -> {"cmd.exe", "/c"}
    end
  end

  defp git_bash do
    System.find_executable("bash") ||
      Enum.find(
        [
          "C:/Program Files/Git/bin/bash.exe",
          "C:/Program Files (x86)/Git/bin/bash.exe"
        ],
        &File.regular?/1
      )
  end

  defp os_name do
    case :os.type() do
      {:unix, :darwin} -> "macOS"
      {:win32, _} -> "Windows"
      _ -> "Linux"
    end
  end

  defp reaper_missing_message do
    "The shell tool is unavailable: the reaper helper for #{Reaper.triple()} was not " <>
      "built into this install. Run `mix compile.reaper` from a source checkout."
  end

  defp cap(%{config: nil}), do: 60_000
  defp cap(%{config: config}), do: config.tool_output_limit
end
