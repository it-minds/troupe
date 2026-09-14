defmodule Troupe.Reaper do
  @moduledoc """
  Locating and running the `reaper` helper.

  Every OS process Troupe starts goes through reaper, and reaper is owned by a Port
  belonging to the tool task. That ownership is the entire cleanup story: when the
  task dies — cancel, agent crash, supervisor shutdown, SIGKILL on the VM — the Port
  closes, reaper reads EOF on its stdin, and it kills the command's whole process
  tree. No cleanup code runs on the Elixir side because none can be relied on when
  the VM is killed outright.
  """

  @doc """
  Path to the reaper binary for this host, or `{:error, :reaper_missing}`.

  `priv/reaper/<triple>/reaper` is populated by `mix compile.reaper` and packed into
  the release, so a worker image carries the reaper for the architecture its pods run
  on and never builds anything at runtime.
  """
  @spec path() :: {:ok, Path.t()} | {:error, :reaper_missing}
  def path do
    candidate = Path.join([:code.priv_dir(:troupe_core), "reaper", triple(), exe_name()])

    if File.regular?(candidate), do: {:ok, candidate}, else: {:error, :reaper_missing}
  end

  @doc """
  Open a Port running `command` under reaper, owned by the calling process.

  Returns the Port. The caller reads `{port, {:data, _}}` and `{port, {:exit_status, _}}`
  as usual; closing the port, or dying, reaps the tree.
  """
  @spec open(Path.t(), [String.t()], keyword()) :: {:ok, port()} | {:error, term()}
  def open(cwd, argv, opts \\ []) do
    with {:ok, reaper} <- path() do
      port =
        Port.open({:spawn_executable, String.to_charlist(reaper)}, [
          :binary,
          :exit_status,
          :hide,
          :stderr_to_stdout,
          {:args, argv},
          {:cd, String.to_charlist(cwd)},
          {:env, env(opts)},
          # A packet-less stream: we want bytes as they arrive, not framed messages.
          {:line, 65_536}
        ])

      {:ok, port}
    end
  end

  @doc """
  Run a command to completion under reaper and return its combined output.

  The `System.cmd/3` of this codebase. Everything that starts an OS process goes
  through reaper — not only the `shell` tool — so that "no OS process outside reaper"
  is a property of the code rather than a rule people remember. A `ripgrep` over a
  huge tree is exactly as cancellable as a shell command, because it is one.

  Returns `{:error, :reaper_missing}` when the helper was not built for this platform,
  so callers can fall back to something that needs no process at all.
  """
  @spec run(Path.t(), [String.t()], keyword()) ::
          {:ok, String.t(), integer()} | {:error, term()}
  def run(cwd, argv, opts \\ []) do
    timeout = Keyword.get(opts, :timeout_ms, 120_000)

    with {:ok, port} <- open(cwd, argv, opts) do
      collect(port, System.monotonic_time(:millisecond) + timeout, [])
    end
  end

  defp collect(port, deadline, acc) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      close(port)
      {:ok, flatten(acc), :timeout}
    else
      receive do
        {^port, {:data, {:eol, line}}} -> collect(port, deadline, ["\n", line | acc])
        {^port, {:data, {:noeol, chunk}}} -> collect(port, deadline, [chunk | acc])
        {^port, {:data, data}} when is_binary(data) -> collect(port, deadline, [data | acc])
        {^port, {:exit_status, status}} -> {:ok, flatten(acc), status}
      after
        remaining ->
          close(port)
          {:ok, flatten(acc), :timeout}
      end
    end
  end

  defp flatten(acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp close(port) do
    if Port.info(port), do: Port.close(port)
  catch
    # Racing the port's own exit is fine: it is already closed, which is the goal.
    :error, :badarg -> :ok
  end

  defp env(opts) do
    opts
    |> Keyword.get(:env, [])
    |> Enum.map(fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)
  end

  @doc "The Zig target triple for the host, matching the `priv/reaper/` layout."
  @spec triple() :: String.t()
  def triple do
    arch =
      case List.to_string(:erlang.system_info(:system_architecture)) do
        "aarch64" <> _ -> "aarch64"
        "arm64" <> _ -> "aarch64"
        _ -> "x86_64"
      end

    case :os.type() do
      {:unix, :darwin} -> arch <> "-macos"
      {:unix, _} -> arch <> "-linux-musl"
      {:win32, _} -> "x86_64-windows"
    end
  end

  defp exe_name do
    case :os.type() do
      {:win32, _} -> "reaper.exe"
      _ -> "reaper"
    end
  end
end
