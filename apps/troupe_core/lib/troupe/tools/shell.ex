defmodule Troupe.Tools.Shell do
  @moduledoc """
  Run a shell command in the workspace, under `reaper`.

  Every OS process Troupe starts goes through reaper, and the Port running reaper is
  owned by this tool's task. That is the whole cancellation and cleanup story: when
  the task dies for any reason — an explicit cancel, an agent crash, a supervisor
  shutdown, `kill -9` on the VM — the pipe closes and reaper kills the command's
  entire process tree. There is no cleanup code here because none could be trusted in
  the case that matters most.

  `bash` on Linux and macOS. On Windows: `bash` from Git for Windows when present, or
  another on the `PATH` that is not WSL's launcher (`windows_bash/2`), otherwise `pwsh`,
  otherwise `powershell.exe` — and the tool's description tells the model which one it
  got.
  """

  @behaviour Troupe.Tool

  alias Troupe.{Reaper, Sandbox, Tool}
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
    with {:ok, command} <- Tool.fetch_string(args, "command"),
         :ok <- Sandbox.check() do
      timeout = Tool.fetch_int(args, "timeout_ms", ctx.timeout_ms) || 120_000
      {shell, flag} = shell()

      # Path checks are not the enforcement here and cannot be: a shell command can do
      # anything a process can. The mount table the file tools resolve against is also
      # the bind list for the sandbox, so a read-only team volume is read-only to the
      # kernel and another team's volume is absent from the namespace entirely.
      argv =
        Sandbox.wrap([shell, flag, command], ctx.workspace.mounts, cwd: ctx.workspace.root_real)

      case Reaper.open(ctx.workspace.root_real, argv) do
        {:ok, port} -> collect(port, timeout, ctx)
        {:error, reason} -> {:error, unavailable(reason)}
      end
    end
  end

  # Reading the port to completion is the only thing this function does; the timeout
  # simply stops reading and closes the port, which reaps the tree.
  defp collect(port, timeout, ctx) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_collect(port, deadline, [], ctx)
  end

  defp do_collect(port, deadline, acc, ctx) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      close(port)
      {:ok, render(acc, :timeout, ctx)}
    else
      receive do
        {^port, {:data, {:eol, line}}} ->
          do_collect(port, deadline, ["\n", line | acc], ctx)

        {^port, {:data, {:noeol, chunk}}} ->
          do_collect(port, deadline, [chunk | acc], ctx)

        {^port, {:data, data}} when is_binary(data) ->
          do_collect(port, deadline, [data | acc], ctx)

        {^port, {:exit_status, status}} ->
          {:ok, render(acc, status, ctx)}
      after
        remaining ->
          close(port)
          {:ok, render(acc, :timeout, ctx)}
      end
    end
  end

  defp close(port) do
    if Port.info(port), do: Port.close(port)
  catch
    # Racing the port's own exit is fine: it is already closed, which is the goal.
    :error, :badarg -> :ok
  end

  # The tail is what a person reads first — the failure is at the end — and the whole
  # run is kept for `read_output`, because running it again is the expensive thing.
  defp render(acc, status, ctx) do
    output = acc |> Enum.reverse() |> IO.iodata_to_binary() |> Output.cap_tail(cap(ctx), ctx)
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
      bash = windows_bash(System.get_env()) -> {bash, "-c"}
      pwsh = System.find_executable("pwsh") -> {pwsh, "-Command"}
      ps = System.find_executable("powershell.exe") -> {ps, "-Command"}
      true -> {"cmd.exe", "/c"}
    end
  end

  @doc """
  The bash commands run with on Windows, or `nil`: Git for Windows' own, beside the `git`
  on the `PATH` or where its installer puts it, else a `bash.exe` on the `PATH` that is not
  WSL's launcher (Decision 776).

  The first `bash` on a Windows `PATH` is often `C:\\Windows\\System32\\bash.exe` (or its
  `WindowsApps` alias), which starts a Linux distribution: a command there runs in another
  operating system, with that system's programs, where the Windows `elixir` finds no
  `erl`, while the tool's description tells the model it is on Windows. `env` is the
  environment, its names in any case, and `exists?` says whether a file is there.
  """
  @spec windows_bash(%{String.t() => String.t()}, (Path.t() -> boolean())) :: Path.t() | nil
  def windows_bash(env, exists? \\ &File.regular?/1) do
    path =
      env
      |> env_var("PATH")
      |> Kernel.||("")
      |> String.split(";", trim: true)
      |> Enum.map(&slashes/1)

    beside_git =
      for dir <- path,
          exists?.(dir <> "/git.exe"),
          root <- [Path.dirname(dir), Path.dirname(Path.dirname(dir))],
          do: root

    installed =
      for {var, under} <- [
            {"ProgramFiles", "Git"},
            {"ProgramW6432", "Git"},
            {"ProgramFiles(x86)", "Git"},
            {"LOCALAPPDATA", "Programs/Git"}
          ],
          base = env_var(env, var),
          do: slashes(base) <> "/" <> under

    from_git =
      for root <- beside_git ++ installed,
          bin <- ["bin", "usr/bin"],
          do: "#{root}/#{bin}/bash.exe"

    on_path = for dir <- path, not wsl_launcher?(dir, env), do: dir <> "/bash.exe"

    Enum.find(from_git ++ on_path, exists?)
  end

  # Where WSL's `bash.exe` lives: the Windows directory, and the per-user app aliases.
  defp wsl_launcher?(dir, env) do
    windows =
      env |> env_var("SystemRoot") |> Kernel.||("C:/Windows") |> slashes() |> String.downcase()

    dir = String.downcase(dir)

    String.starts_with?(dir <> "/", windows <> "/") or
      String.ends_with?(dir, "/microsoft/windowsapps")
  end

  defp env_var(env, name) do
    Enum.find_value(env, fn {key, value} ->
      String.downcase(key) == String.downcase(name) and value
    end)
  end

  defp slashes(path),
    do:
      path
      |> String.trim()
      |> String.trim("\"")
      |> String.replace("\\", "/")
      |> String.trim_trailing("/")

  defp os_name do
    case :os.type() do
      {:unix, :darwin} -> "macOS"
      {:win32, _} -> "Windows"
      _ -> "Linux"
    end
  end

  defp unavailable(:reaper_missing) do
    "The shell tool is unavailable: #{Reaper.explain(:reaper_missing)}. " <>
      "Run `mix compile.reaper` from a source checkout."
  end

  # What the model reads, so it can tell the person rather than try again: nothing will
  # run until the helper does (Decision 733).
  defp unavailable({:reaper_unstartable, _} = reason) do
    "The shell tool is unavailable: #{Reaper.explain(reason)}, so no command can run on " <>
      "this machine until it does. `troupe doctor` shows the same to the person."
  end

  defp unavailable(reason),
    do: "The shell tool could not run the command: #{Reaper.explain(reason)}."

  defp cap(%{config: nil}), do: 60_000
  defp cap(%{config: config}), do: config.tool_output_limit
end
