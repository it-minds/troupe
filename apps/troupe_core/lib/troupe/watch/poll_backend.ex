defmodule Troupe.Watch.PollBackend do
  @moduledoc """
  Change detection by scanning mtime and size.

  Always available, which is what lets a single self-contained binary support watch
  mode on a machine with no `inotify-tools` installed. It walks the workspace on an
  interval, skipping ignored paths, and reports every file whose mtime or size moved
  since the last pass.
  """

  use GenServer

  @behaviour Troupe.Watch.Backend

  alias Troupe.Gitignore

  @default_interval 1_000

  # Ignore rules are re-read every so often rather than every pass: reloading means
  # walking the tree for `.gitignore` files, and doing that once a second would
  # double the cost of watching. The listener reloads immediately on a `.gitignore`
  # change event, so this is only the backstop for a change the scan itself missed.
  @ignore_reload_every 10

  @impl Troupe.Watch.Backend
  def name, do: :poll

  @impl Troupe.Watch.Backend
  def available?(_root), do: true

  @impl Troupe.Watch.Backend
  def start_link(root, listener, opts \\ []) do
    GenServer.start_link(__MODULE__, {root, listener, opts})
  end

  @impl GenServer
  def init({root, listener, opts}) do
    Process.set_label("troupe watch backend (poll)")

    interval = Keyword.get(opts, :interval_ms, @default_interval)
    ignore = Gitignore.load(root)

    state = %{
      root: root,
      listener: listener,
      interval: interval,
      ignore: ignore,
      passes: 0,
      # The first scan seeds the baseline: files that already exist are not "changes".
      seen: scan(root, ignore)
    }

    schedule(interval)
    {:ok, state}
  end

  @impl GenServer
  def handle_info(:poll, state) do
    state = maybe_reload_ignore(state)
    current = scan(state.root, state.ignore)
    changed = changed_paths(state.seen, current)

    if changed != [], do: send(state.listener, {:watch_paths, changed})

    schedule(state.interval)
    {:noreply, %{state | seen: current, passes: state.passes + 1}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @doc """
  Stat every watchable file under `root`.

  A pruning walk rather than `Path.wildcard/2`, for two reasons. It skips ignored
  directories instead of enumerating them and filtering afterwards, which on a real
  project is the difference between walking `_build` and `.git` every second and not.
  And it sees dotfiles, so a `.gitignore` written mid-session registers as a change
  and the listener can reload its rules.
  """
  @spec scan(Path.t(), Gitignore.t()) :: %{optional(Path.t()) => {integer(), integer()}}
  def scan(root, ignore), do: walk(root, root, ignore, %{})

  defp walk(dir, root, ignore, acc) do
    case File.ls(dir) do
      {:ok, entries} -> Enum.reduce(entries, acc, &visit(Path.join(dir, &1), root, ignore, &2))
      {:error, _} -> acc
    end
  end

  defp visit(path, root, ignore, acc) do
    relative = Path.relative_to(path, root)

    if Gitignore.ignored?(ignore, relative) do
      acc
    else
      case File.stat(path, time: :posix) do
        {:ok, %File.Stat{type: :directory}} ->
          walk(path, root, ignore, acc)

        {:ok, %File.Stat{type: :regular, mtime: mtime, size: size}} ->
          Map.put(acc, path, {mtime, size})

        _ ->
          acc
      end
    end
  end

  defp maybe_reload_ignore(%{passes: passes} = state)
       when rem(passes, @ignore_reload_every) == 0 do
    %{state | ignore: Gitignore.load(state.root)}
  end

  defp maybe_reload_ignore(state), do: state

  defp changed_paths(previous, current) do
    # Additions and modifications are what a marker scan cares about; a deleted file
    # cannot contain a marker, so it is not reported.
    Enum.flat_map(current, fn {path, stamp} ->
      if Map.get(previous, path) == stamp, do: [], else: [path]
    end)
  end

  defp schedule(interval), do: Process.send_after(self(), :poll, interval)
end
