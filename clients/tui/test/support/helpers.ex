defmodule Troupe.TestHelpers do
  @moduledoc "Shared test helpers: temp workspaces, sessions with a Fake, event waits."

  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Troupe.LLM.Fake

  @doc "Creates an empty temporary workspace, removed on exit."
  def tmp_workspace(files \\ %{}) do
    dir = Path.join(System.tmp_dir!(), "troupe-ws-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    for {rel, content} <- files do
      path = Path.join(dir, rel)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)
    end

    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  @doc "Initializes a git repo with one commit in `dir`."
  def git_init!(dir) do
    run_git!(dir, ["init", "-q", "-b", "main"])
    run_git!(dir, ["config", "user.email", "test@test"])
    run_git!(dir, ["config", "user.name", "test"])
    File.write!(Path.join(dir, "README.md"), "# fixture\n")
    run_git!(dir, ["add", "-A"])
    run_git!(dir, ["commit", "-q", "-m", "init"])
    dir
  end

  def run_git!(dir, args) do
    {out, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    out
  end

  @doc "Starts a session with a Fake provider and subscribes the caller. Returns `{sid, fake, ws}`."
  def start_session!(opts \\ []) do
    ws = Keyword.get_lazy(opts, :workspace, fn -> tmp_workspace() end)

    fake =
      Keyword.get_lazy(opts, :fake, fn ->
        Fake.start!(Keyword.get(opts, :script, []), Keyword.take(opts, [:scripts, :fallback]))
      end)

    session_opts =
      opts
      |> Keyword.drop([:workspace, :fake, :script, :scripts, :fallback])
      |> Keyword.merge(workspace: ws, provider: {Fake, fake})

    # Every temp workspace lacks a brief, so a session would dispatch a librarian
    # into the Fake's script. Tests that want one pass `auto_refresh: true`.
    session_opts =
      Keyword.update(session_opts, :config, %{memory: %{auto_refresh: false}}, &no_auto_refresh/1)

    {:ok, sid} = Troupe.start_session(session_opts)
    :ok = Troupe.subscribe(sid)
    on_exit(fn -> Troupe.stop_session(sid) end)
    {sid, fake, ws}
  end

  defp no_auto_refresh(config) do
    config
    |> Map.new()
    |> Map.update(:memory, %{auto_refresh: false}, &Map.put_new(&1, :auto_refresh, false))
  end

  @doc "Waits for the window `path` to publish `branch_state` = `state`."
  def await_state(path, state, timeout \\ 5_000)

  def await_state(path, :failed_unread, timeout) do
    assert_receive {:troupe_event, %{type: :branch_failed, agent_path: ^path}}, timeout
  end

  def await_state(path, state, timeout) do
    assert_receive {:troupe_event,
                    %{type: :branch_state, agent_path: ^path, data: %{state: ^state}}},
                   timeout
  end

  @doc "Waits for any event of `type` for `path`; returns it."
  def await_event(path, type, timeout \\ 5_000) do
    assert_receive {:troupe_event, %{type: ^type, agent_path: ^path} = event}, timeout
    event
  end

  @doc "Waits until `fun` returns truthy, polling; fails after timeout."
  def eventually(fun, timeout \\ 5_000, step \\ 20) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_eventually(fun, deadline, step)
  end

  defp do_eventually(fun, deadline, step) do
    case fun.() do
      falsy when falsy in [false, nil] ->
        if System.monotonic_time(:millisecond) > deadline do
          flunk("condition not met within timeout")
        else
          receive do
          after
            step -> :ok
          end

          do_eventually(fun, deadline, step)
        end

      value ->
        value
    end
  end

  def window(sid, path), do: sid |> Troupe.windows() |> Enum.find(&(&1.agent_path == path))

  def events_of(sid, path, type),
    do: sid |> Troupe.events() |> Enum.filter(&(&1.agent_path == path and &1.type == type))

  def flush_events do
    receive do
      {:troupe_event, _} -> flush_events()
    after
      0 -> :ok
    end
  end

  @doc """
  Sends every copy to a file this test owns rather than to the machine's
  clipboard — which is also how a user redirects it (a tmux buffer, an OSC-52
  helper over ssh). Returns the path, which is created on the first copy.
  """
  def capture_clipboard_to(path) do
    previous = Application.get_env(:troupe, :clipboard_command)
    Application.put_env(:troupe, :clipboard_command, "cat > '#{path}'")
    on_exit(fn -> Application.put_env(:troupe, :clipboard_command, previous) end)
    path
  end

  @doc "A fresh path in the temp dir for a captured clipboard, removed when the test ends."
  def clipboard_path do
    path = Path.join(System.tmp_dir!(), "clip-#{:erlang.unique_integer([:positive])}")
    on_exit(fn -> File.rm(path) end)
    capture_clipboard_to(path)
  end
end
