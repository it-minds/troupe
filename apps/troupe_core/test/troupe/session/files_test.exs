defmodule Troupe.Session.FilesTest do
  @moduledoc """
  What `fs_changed` runs on when the native watcher cannot.

  `inotifywait` can be installed and still not run: a machine whose inotify instances or
  watches are used up refuses it at start, or stops it later. A worker pod shares those
  limits with everything else on its node that runs as the same user, so that is a
  failure a pod can meet. Polling is late and reports no deletion, but a session whose
  native watcher had stopped reported nothing at all. These stand in for the refusal and
  for the stop, and pin that polling takes over.
  """

  use ExUnit.Case, async: true

  alias Troupe.Session.Files
  alias Troupe.Workspace

  defmodule Refused do
    @moduledoc false
    @behaviour Troupe.Watch.Backend

    @impl true
    def name, do: :native

    @impl true
    def available?(_root), do: true

    @impl true
    def start_link(_root, _listener, _opts), do: {:error, :inotify_instances_used_up}
  end

  defmodule Stops do
    @moduledoc false
    @behaviour Troupe.Watch.Backend

    @impl true
    def name, do: :native

    @impl true
    def available?(_root), do: true

    @impl true
    def start_link(_root, _listener, _opts) do
      {:ok, spawn_link(fn -> receive do: (:stop -> exit(:watcher_stopped)) end)}
    end
  end

  setup do
    root = Path.join(System.tmp_dir!(), "troupe-files-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, workspace} = Workspace.new(root)
    %{workspace: workspace, session_id: "files-#{System.unique_integer([:positive])}"}
  end

  test "a native watcher that will not start leaves polling, not silence", context do
    start_files!(context, Refused)
    assert Files.backend(context.session_id) == :poll
  end

  test "a native watcher that stops is replaced by polling", context do
    files = start_files!(context, Stops)
    assert Files.backend(context.session_id) == :native

    send(:sys.get_state(files).backend, :stop)

    assert eventually(fn -> Files.backend(context.session_id) == :poll end)
  end

  defp start_files!(context, backend) do
    start_supervised!(
      {Files,
       session_id: context.session_id,
       workspace: context.workspace,
       enabled: true,
       backend: backend,
       interval_ms: 60_000}
    )
  end

  defp eventually(fun, attempts \\ 100) do
    cond do
      fun.() ->
        true

      attempts == 0 ->
        false

      true ->
        Process.sleep(20)
        eventually(fun, attempts - 1)
    end
  end
end
