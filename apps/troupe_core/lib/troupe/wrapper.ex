defmodule Troupe.Wrapper do
  @moduledoc """
  Shuts the VM down when the binary that launched it goes away.

  Burrito's launcher does not `exec` into the BEAM on Linux — it forks it and waits.
  So `kill -9` on the `troupe` process a user can see leaves the BEAM running,
  orphaned, still holding open the reaper pipes that would otherwise reap every shell
  command. Everything Troupe does to guarantee no orphans is undone by that one gap.

  This closes it. The launcher's process id is recorded at boot and its liveness
  checked periodically; once it is gone the VM halts, every reaper pipe closes, and
  every OS process tree is reaped.

  "Gone" has to mean more than "my parent id changed". A dead parent that nothing has
  reaped yet is a zombie, and a zombie keeps its children's parent id pointing at it —
  so the naive check would wait indefinitely on exactly the case it exists for. The
  check is therefore: the parent is missing, or it is a zombie, or it has been
  replaced.

  It only runs inside a wrapped binary, where a launcher parent exists. In
  development and under test there is nothing to watch and this never starts.
  """

  use GenServer

  alias Troupe.Reaper

  require Logger

  @interval_ms 1_000

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  A child spec, or `nil` when there is no launcher to watch.

  `nil` in development, under test, and on any platform where the parent cannot be
  read — the watchdog is a safety net, never a requirement for starting.
  """
  @spec child_spec_if_wrapped() :: Supervisor.child_spec() | nil
  def child_spec_if_wrapped do
    if wrapped?() and parent_pid() != nil do
      Supervisor.child_spec({__MODULE__, []}, id: __MODULE__)
    end
  end

  @doc "Whether this VM is running inside a Burrito-wrapped binary."
  @spec wrapped?() :: boolean()
  def wrapped?, do: System.get_env("__BURRITO") != nil

  @doc """
  This process's parent process id, or `nil` where it cannot be read.

  Linux exposes it in `/proc`, which costs nothing. macOS has no `/proc`, so it takes
  one `ps` call — cheap enough at this interval, and only inside a packaged binary.
  Windows has no equivalent worth the complexity, so the watchdog does not run there.
  """
  @spec parent_pid() :: pos_integer() | nil
  def parent_pid do
    case :os.type() do
      {:unix, :darwin} -> darwin_stat(:os.getpid() |> List.to_string(), "ppid=") |> to_pid()
      {:unix, _} -> linux_stat("self") |> elem(1)
      {:win32, _} -> nil
    end
  end

  @doc """
  Whether the process that launched this VM is gone.

  Missing, a zombie, or replaced all count. The zombie case is the one that matters:
  a launcher killed by `kill -9` stays a zombie until whatever started it reaps it,
  and until then this VM's parent id still points at the corpse.
  """
  @spec parent_gone?(pos_integer() | nil) :: boolean()
  def parent_gone?(nil), do: false

  def parent_gone?(recorded) do
    case :os.type() do
      {:unix, :darwin} -> darwin_gone?(recorded)
      {:unix, _} -> linux_gone?(recorded)
      {:win32, _} -> false
    end
  end

  defp linux_gone?(recorded) do
    case linux_stat(Integer.to_string(recorded)) do
      {nil, _ppid} -> true
      {"Z", _ppid} -> true
      {_state, _ppid} -> parent_pid() != recorded
    end
  end

  # /proc/<pid>/stat is "pid (comm) state ppid ...". The comm field can contain
  # spaces and parentheses, so parsing starts after the last ") ".
  defp linux_stat(who) do
    with {:ok, contents} <- File.read("/proc/#{who}/stat"),
         [_, after_comm] <- String.split(contents, ") ", parts: 2),
         [state, ppid | _] <- String.split(after_comm, " ") do
      {state, to_pid(ppid)}
    else
      _ -> {nil, nil}
    end
  end

  defp darwin_gone?(recorded) do
    case darwin_stat(Integer.to_string(recorded), "state=") do
      nil -> true
      state -> String.starts_with?(state, "Z") or parent_pid() != recorded
    end
  end

  # Through reaper, like every other OS process this application starts.
  defp darwin_stat(pid, field) do
    case Reaper.run(System.tmp_dir!(), ["ps", "-o", field, "-p", pid], timeout_ms: 5_000) do
      {:ok, output, 0} ->
        case String.trim(output) do
          "" -> nil
          value -> value
        end

      _ ->
        nil
    end
  rescue
    # `ps` missing, or no reaper for this platform, is not worth crashing over.
    _ -> nil
  end

  defp to_pid(nil), do: nil

  defp to_pid(value) when is_binary(value) do
    case Integer.parse(value) do
      {pid, _} -> pid
      :error -> nil
    end
  end

  defp to_pid(value), do: value

  @impl GenServer
  def init(opts) do
    Process.set_label("troupe launcher watchdog")

    interval = Keyword.get(opts, :interval_ms, @interval_ms)
    parent = parent_pid()

    schedule(interval)
    {:ok, %{parent: parent, interval: interval, halt: Keyword.get(opts, :halt, &System.halt/1)}}
  end

  @impl GenServer
  def handle_info(:check, %{parent: parent} = state) do
    if parent_gone?(parent) do
      Logger.info("troupe: the launcher exited; shutting down so nothing is left running")
      state.halt.(0)
      {:noreply, state}
    else
      schedule(state.interval)
      {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp schedule(interval), do: Process.send_after(self(), :check, interval)
end
