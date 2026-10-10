defmodule Troupe.SetupScreenDaemonTest do
  @moduledoc """
  `troupe setup`'s screen against the daemon this VM embeds (TUI Decision 153, root
  Decision 817), with its own `setup.get` and `setup.answer`: the fake provider chosen, a
  model picked, back once, the summary confirmed, and the first session working in the
  project it set up; the file written is the one `troupe config`'s questions write for the
  same answers, a gateway's typed key included, those questions run against the same
  daemon; and Esc on a fresh machine writes nothing at all.

  `async: false`: each test swaps the machine's config and state homes for scratch ones,
  and the daemon holds one first run at a time. The login entry goes to the suite's
  scratch home (`test_helper.exs`).
  """

  use ExUnit.Case, async: false

  import Troupe.TestHelpers, only: [eventually: 2]

  import Troupe.TUIHelpers,
    only: [press: 2, type: 2, screen: 2, screen_text: 2, start_tui: 1, user_state: 1]

  alias ExRatatui.CellSession
  alias Troupe.CLI.ConfigSetup
  alias Troupe.Client
  alias Troupe.Client.Daemon.Link
  alias Troupe.UI.Setup

  @vars ~w(TROUPE_CONFIG_HOME TROUPE_STATE_HOME)

  setup do
    # The daemon is found, or embedded, with the suite's own homes before they are swapped.
    {:ok, _endpoint} = Link.ensure()
    previous = Map.new(@vars, &{&1, System.get_env(&1)})
    base = Path.join(System.tmp_dir!(), "troupe-setup-screen-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(base, "project"))

    on_exit(fn ->
      Enum.each(previous, fn
        {var, nil} -> System.delete_env(var)
        {var, value} -> System.put_env(var, value)
      end)

      File.rm_rf!(base)
    end)

    %{base: base, project: Path.join(base, "project")}
  end

  test "the fake provider, a model picked, back once: the first session works in the project",
       ctx do
    config = machine(ctx.base, "screen")
    {pid, session} = start(ctx.project, offer_fake: true)

    enter(pid)
    to_choice(pid, session, "The fake provider")
    enter(pid)
    # The fake needs no key; the daemon checks it and lists its two models.
    enter(pid)
    assert step(pid) == {"models", :main}
    assert screen_text(pid, session) =~ "The provider accepted the key."

    # Back once: the daemon forgets the key, and asks for it again.
    press(pid, "back_tab")
    settle(pid)
    assert step(pid) == {"key", :main}
    assert {:ok, %{"step" => "key"}} = Link.call("setup.get", %{})
    enter(pid)

    # The suggested main model, and the small one the same as it.
    assert selected(pid, session) =~ "fake-model · suggested"
    press(pid, "enter")
    to_choice(pid, session, "the same as the main model")
    press(pid, "enter")
    press(pid, "enter")
    press(pid, "enter")
    assert step(pid) == {"finish", :main}
    refute File.exists?(config), "nothing is written before the summary"

    press(pid, "enter")
    assert_receive {:done, {:session, sid, workspace}}, 15_000
    assert workspace == ctx.project

    # Open, as `troupe setup` opens it, and working on the question the daemon suggested.
    assert {:ok, ^sid} = Client.open_session({:local, workspace}, sid)
    on_exit(fn -> Client.stop_session(sid) end)
    {tui, tui_session} = start_tui(sid)

    # The session's own agent has the question, so it is listed, and its window opens on it
    # (TUI Decision 155).
    eventually(fn -> Map.has_key?(user_state(tui).model.windows, "root") end, 10_000)
    eventually(fn -> user_state(tui).model.windows["root"].started end, 10_000)
    press(tui, "1")
    eventually(fn -> screen_text(tui, tui_session) =~ "Look around this directory" end, 10_000)

    assert {:ok, %{"needed" => false, "completed" => %{"choice" => "local"}}} =
             Link.call("setup.get", %{})

    # `troupe config`'s questions save the same answers through `config.set`; they never
    # offer the fake, so its call is spelled out here as `ConfigSetup.save/3` makes it.
    written = File.read!(config)
    line_by_line = machine(ctx.base, "line")

    {:ok, _saved} =
      Link.call("config.set", %{
        "command_id" => "c-line-by-line",
        "provider" => "fake",
        "models" => %{"default" => "fake-model"}
      })

    assert File.read!(line_by_line) == written
  end

  test "a gateway with a typed key: the same file troupe config's questions write", ctx do
    {_server, url} =
      Troupe.TestHTTP.start(fn
        "/v1/models" ->
          {200, "application/json", ~s({"data": [{"id": "gw-big"}, {"id": "gw-small"}]})}

        _other ->
          {404, "application/json", "{}"}
      end)

    gateway = url <> "/v1"

    config = machine(ctx.base, "screen")
    {pid, session} = start(ctx.project)
    enter(pid)
    to_choice(pid, session, "An OpenAI-compatible gateway")
    type(pid, gateway)
    enter(pid)
    assert step(pid) == {"key", :main}
    type(pid, "sk-gw-typed")
    enter(pid)
    assert step(pid) == {"models", :main}
    refute screen_text(pid, session) =~ "sk-gw-typed"

    press(pid, "enter")
    to_choice(pid, session, "the same as the main model")
    for _ <- 1..4, do: press(pid, "enter")
    assert_receive {:done, {:session, sid, workspace}}, 15_000
    assert {:ok, ^sid} = Client.open_session({:local, workspace}, sid)
    on_exit(fn -> Client.stop_session(sid) end)
    from_screen = File.read!(config)
    assert from_screen =~ gateway

    # The same answers, typed into `troupe config`'s questions against the same daemon:
    # set up here, the gateway, its URL, the key, the first model listed, the same one
    # for small work, and yes.
    line_by_line = machine(ctx.base, "line")
    answers = ["1", "2", gateway, "sk-gw-typed", "1", "", ""]
    assert ConfigSetup.run(ctx.project, typed(ctx.project, answers)) == 0
    assert File.read!(line_by_line) == from_screen
  end

  test "Esc on a fresh machine writes nothing, and the daemon forgets what it was told", ctx do
    machine(ctx.base, "esc")
    {pid, session} = start(ctx.project, offer_fake: true)
    enter(pid)
    to_choice(pid, session, "The fake provider")
    enter(pid)
    enter(pid)
    assert step(pid) == {"models", :main}

    press(pid, "esc")
    assert_receive {:done, {:left, false}}, 5_000

    assert {:ok, %{"step" => "where", "answers" => answers, "needed" => true}} =
             Link.call("setup.get", %{})

    assert answers == %{}
    files = ctx.base |> Path.join("esc/**/*") |> Path.wildcard() |> Enum.filter(&File.regular?/1)
    assert files == []
  end

  # -- the machine, the screen and a person ----------------------------------------------

  # Fresh config and state homes, as on a machine Troupe has never run on; the config
  # file's path.
  defp machine(base, name) do
    System.put_env("TROUPE_CONFIG_HOME", Path.join([base, name, "config"]))
    System.put_env("TROUPE_STATE_HOME", Path.join([base, name, "state"]))
    Path.join([base, name, "config", "config.yaml"])
  end

  defp start(workspace, opts \\ []) do
    test = self()
    session = CellSession.new(120, 40)

    {:ok, pid} =
      ExRatatui.Server.start_link(
        mod: Setup,
        transport: {:cell_session, session, fn _ -> :ok end},
        name: nil,
        call: &Link.call/2,
        workspace: workspace,
        offer_fake: Keyword.get(opts, :offer_fake, false),
        on_done: fn outcome -> send(test, {:done, outcome}) end
      )

    {pid, session}
  end

  # `troupe config`'s questions with the answers typed in order, and nothing to start at
  # login; everything else is the real thing.
  defp typed(workspace, answers) do
    {:ok, script} = Agent.start_link(fn -> answers end)

    next = fn _prompt ->
      Agent.get_and_update(script, fn
        [a | rest] -> {a, rest}
        [] -> {nil, []}
      end)
    end

    %{
      ConfigSetup.io(workspace)
      | interactive?: true,
        say: fn _line -> :ok end,
        ask: next,
        secret: next,
        troupe_daemon?: fn -> false end
    }
  end

  defp enter(pid) do
    press(pid, "enter")
    settle(pid)
  end

  defp settle(pid), do: eventually(fn -> :sys.get_state(pid).user_state.busy == nil end, 15_000)

  defp step(pid) do
    state = :sys.get_state(pid).user_state
    {state.step, state.part}
  end

  defp selected(pid, session), do: pid |> screen(session) |> Enum.find("", &(&1 =~ "▸ "))

  # From the top, down to the choice whose label says so, as a person would press it.
  defp to_choice(pid, session, label) do
    for _ <- 1..:sys.get_state(pid).user_state.cursor//1, do: press(pid, "up")
    down_to(pid, session, label, 12)
  end

  defp down_to(pid, session, label, 0),
    do: flunk("no choice #{inspect(label)}:\n" <> screen_text(pid, session))

  defp down_to(pid, session, label, tries) do
    unless selected(pid, session) =~ label do
      press(pid, "down")
      down_to(pid, session, label, tries - 1)
    end
  end
end
