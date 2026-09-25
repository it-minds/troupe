defmodule Troupe.TestHelpers do
  @moduledoc """
  Shared test helpers: temp workspaces, daemon sessions with a scripted model, event
  waits.

  A session is the daemon's — the one this VM embeds (`Troupe.Client.Daemon.Link`) — and
  the test reaches it exactly as the TUI does, through `Troupe.Client`. The model is
  deterministic because the *workspace* says so: `start_session!/1` writes
  `provider: fake` and a JSON script into the workspace's `.troupe/config.yaml`, which the
  daemon reads when it creates the session. A test never hands the harness a fake process,
  because a client cannot.

  Events reach the test as the TUI sees them: `{:troupe_event, %Troupe.Event{}}`, the
  protocol's events translated at the edge (`Troupe.Remote.Translate`). A session's one
  agent is the window `"root"`.
  """

  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Troupe.Client

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

  @doc """
  Starts a daemon session in a workspace whose model answers from a script, and
  subscribes the caller. Returns `{sid, :fake, ws}` — the middle element is a placeholder
  where the in-process fake used to be, so call sites read the same.

  Options: `:workspace`; `:script` (steps for the root agent) or `:scripts` (a map of
  agent name → steps, `"root"` for the root; the old `"code-1"` spelling is read as the
  root); `:auto_approve` (default true, because most tests are about the transcript, not
  the gate); `:profile`; `:prompt`; `:config` (extra YAML keys as a map).

  Steps are the old spellings: `{:text, t}`, `{:tool, name, input}`, `{:tools, [{n, i}]}`,
  `{:finish, summary}`, `{:error, reason}`, plus `{:text_and_tools, t, calls}`, or a map
  written into the script as it is (`%{"stop" => "refusal", "text" => t}`).
  """
  def start_session!(opts \\ []) do
    ws = Keyword.get_lazy(opts, :workspace, fn -> tmp_workspace() end)
    routes = routes(Keyword.get(opts, :script), Keyword.get(opts, :scripts))

    write_fake_config!(
      ws,
      routes,
      Keyword.get(opts, :auto_approve, true),
      Keyword.get(opts, :config, %{})
    )

    params =
      %{worktree: "never"}
      |> put_present(:profile, Keyword.get(opts, :profile))
      |> put_present(:prompt, Keyword.get(opts, :prompt))

    {:ok, sid} = Client.create_session({:local, ws}, params)
    :ok = Client.subscribe(sid)
    on_exit(fn -> Client.stop_session(sid) end)
    {sid, :fake, ws}
  end

  @doc "Sends input to the session's agent, as typing in its window does."
  def say!(sid, text), do: :ok = Client.send_input(sid, "root", text)

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp routes(nil, nil), do: %{"root" => []}
  defp routes(script, nil) when is_list(script), do: %{"root" => script}

  defp routes(_script, scripts) when is_map(scripts) do
    Map.new(scripts, fn {agent, steps} -> {route_name(agent), steps} end)
  end

  # The old fake read a text-only step as an implicit finish; the daemon's model ends the
  # turn on one and waits for input. So a text step becomes text plus `finish` — with the
  # summary of a `{:finish, _}` that follows it, when one does — and a test that wants a
  # reply *without* the agent finishing spells `{:text_and_tools, text, []}`.
  defp finishing([{:text, text}, {:finish, summary} | rest]),
    do: [{:text_and_tools, text, [{"finish", %{"summary" => summary}}]} | finishing(rest)]

  defp finishing([{:text, text} | rest]),
    do: [{:text_and_tools, text, [{"finish", %{"summary" => text}}]} | finishing(rest)]

  defp finishing([step | rest]), do: [step | finishing(rest)]
  defp finishing([]), do: []

  # `code-1` was the first branch of the `code` profile; there is one agent per session
  # now and it is the root. A subagent keeps its own name.
  defp route_name(agent) do
    cond do
      agent == "root" -> "root"
      Regex.match?(~r/^[a-z_]+-1$/, agent) -> "root"
      true -> String.replace(agent, ~r/-\d+$/, "")
    end
  end

  defp write_fake_config!(ws, routes, auto_approve?, extra) do
    File.mkdir_p!(Path.join(ws, ".troupe"))
    script = Path.join(ws, ".troupe/fake.json")

    File.write!(
      script,
      Jason.encode!(%{
        "routes" =>
          Map.new(routes, fn {a, steps} -> {a, steps |> finishing() |> Enum.map(&json_step/1)} end)
      })
    )

    yaml =
      Map.merge(
        %{
          "provider" => "fake",
          "model" => "fake-model",
          "auto_approve" => auto_approve?,
          # A test's session must not start a librarian of its own; the one test about
          # the refresh turns it back on through `:config`.
          "memory_auto_refresh" => false,
          "fake_script" => script
        },
        Map.new(extra, fn {k, v} -> {to_string(k), v} end)
      )

    File.write!(Path.join(ws, ".troupe/config.yaml"), Troupe.Settings.encode_yaml(yaml))
  end

  defp json_step({:text, text}), do: %{"text" => text}
  defp json_step({:tool, name, input}), do: %{"tools" => [%{"name" => name, "input" => input}]}

  defp json_step({:tools, calls}),
    do: %{"tools" => Enum.map(calls, fn {n, i} -> %{"name" => n, "input" => i} end)}

  defp json_step({:text_and_tools, text, calls}),
    do: Map.put(json_step({:tools, calls}), "text", text)

  defp json_step({:finish, summary}),
    do: %{"tools" => [%{"name" => "finish", "input" => %{"summary" => summary}}]}

  defp json_step({:error, reason}), do: %{"error" => to_string(reason)}
  # The JSON the daemon reads, as it is: for what the tuples do not spell, such as `stop`.
  defp json_step(%{} = step), do: step

  @doc "Waits for the window `path` to reach `state`: `:done`, `:thinking`, `:idle`, `:acting`."
  def await_state(path, state, timeout \\ 5_000) do
    assert_receive {:troupe_event, %{type: :agent_state, agent_path: ^path, data: %{to: ^state}}},
                   timeout
  end

  @doc "Waits for the root agent to be done."
  def await_done(timeout \\ 10_000), do: await_state("root", :done, timeout)

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

  @doc "The translated events of one type for a window, from the client's journal."
  def events_of(sid, path, type),
    do: sid |> Client.events() |> Enum.filter(&(&1.agent_path == path and &1.type == type))

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
