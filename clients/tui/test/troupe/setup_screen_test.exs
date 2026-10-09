defmodule Troupe.SetupScreenTest do
  @moduledoc """
  `troupe setup`'s screen (TUI Decision 153, root Decision 817) with a person at the keys
  and the daemon played by a function holding a flow the way `Troupe.Gateway.Setup` does:
  what each key sends, that nothing that writes is sent before the summary, that Esc
  leaves with nothing sent that writes, that a typed key is never drawn, and that going
  back is the daemon's `{"back": true}` for a step it holds. `setup_screen_daemon_test.exs`
  runs the same screen against the daemon itself.
  """

  use ExUnit.Case, async: true

  import Troupe.TestHelpers, only: [eventually: 1, tmp_workspace: 0]
  import Troupe.TUIHelpers, only: [press: 2, type: 2, screen: 2, screen_text: 2]

  alias ExRatatui.CellSession
  alias Troupe.UI.Setup

  test "a first run top to bottom: what writes waits for the summary, and back works on both sides" do
    ws = tmp_workspace()
    {pid, session} = start(workspace: ws, offer_fake: true)
    assert screen_text(pid, session) =~ "Where does the work run?"

    enter(pid)
    assert answers() == [{"where", %{"choice" => "local"}}]
    assert screen_text(pid, session) =~ "Which model provider?"

    # The fake provider is offered last, where a script for it is set up.
    to_choice(pid, session, "The fake provider")
    enter(pid)
    assert answers() == [{"provider", %{"provider" => "fake"}}]

    # It needs no key, and that is the answer under the cursor.
    assert selected(pid, session) =~ "The fake provider needs no key"
    enter(pid)
    assert answers() == [{"key", %{}}]

    # What the provider listed, the suggestion under the cursor, the daemon's word above.
    text = screen_text(pid, session)
    assert text =~ "The provider accepted the key."
    assert selected(pid, session) =~ "m-big · suggested"
    assert step(pid) == {"models", :main}

    # Back from the models is the daemon's: it forgets the key, which is asked again.
    press(pid, "back_tab")
    settle(pid)
    assert answers() == [{"key", %{"back" => true}}]
    assert step(pid) == {"key", :main}
    enter(pid)
    assert answers() == [{"key", %{}}]

    # The other model, then the small one: the same as the main model.
    press(pid, "down")
    press(pid, "enter")
    assert step(pid) == {"models", :small}
    to_choice(pid, session, "the same as the main model")
    press(pid, "enter")
    assert step(pid) == {"workspace", :main}

    # Where troupe was started is the first project offered; asking first is the default.
    assert screen_text(pid, session) =~ ws
    assert selected(pid, session) =~ "Ask me first"
    press(pid, "enter")
    assert step(pid) == {"daemon", :main}
    assert selected(pid, session) =~ "Only when an app needs it"
    press(pid, "enter")
    assert step(pid) == {"finish", :main}

    text = screen_text(pid, session)
    assert text =~ "Nothing is written yet."
    assert text =~ "m-small"
    assert text =~ "the record that the first run is done"

    # Back from the summary is this screen's: the daemon hears nothing.
    press(pid, "back_tab")
    assert step(pid) == {"daemon", :main}
    press(pid, "enter")
    assert calls() == []

    press(pid, "enter")
    assert_receive {:done, {:session, "s-1", ^ws}}, 5_000

    assert answers() == [
             {"models", %{"default" => "m-small", "cheap" => nil}},
             {"workspace", %{"workspace" => ws, "approvals" => "ask"}},
             {"daemon", %{"at_login" => false}},
             {"finish", %{"start" => true}}
           ]
  end

  test "Esc leaves with nothing written, and the daemon forgets the key it was given" do
    {pid, session} = start()
    enter(pid)
    to_choice(pid, session, "Anthropic")
    enter(pid)

    # A typed key is drawn as dots, never as itself.
    type(pid, "sk-ant-secret")
    text = screen_text(pid, session)
    refute text =~ "sk-ant-secret"
    assert text =~ String.duplicate("•", 13)

    enter(pid)
    assert {"key", %{"api_key" => "sk-ant-secret"}} in answers()
    refute inspect(:sys.get_state(pid).user_state) =~ "sk-ant-secret"

    press(pid, "esc")
    assert_receive {:done, {:left, false}}, 5_000
    assert answers() == [{"where", %{"back" => true}}]
  end

  test "Esc before anything was answered asks the daemon nothing" do
    {pid, _session} = start()
    press(pid, "esc")
    assert_receive {:done, {:left, false}}, 5_000
    assert answers() == []
  end

  test "a refused key keeps the step and says why" do
    {pid, session} = start()
    enter(pid)
    to_choice(pid, session, "Anthropic")
    enter(pid)

    type(pid, "bad-key")
    enter(pid)

    assert step(pid) == {"key", :main}
    assert screen_text(pid, session) =~ "The provider refused the key: 401 unauthorized"
  end

  test "a refusal after the summary goes back to that step; leaving then says what stays" do
    {pid, session} = start(refuse: "daemon")
    walk_to_summary(pid, session)
    _ = calls()

    enter(pid)
    assert step(pid) == {"daemon", :main}
    text = screen_text(pid, session)
    assert text =~ "there is nothing to start at login"
    assert text =~ "what is saved stays"
    assert Enum.map(answers(), &elem(&1, 0)) == ~w(models workspace daemon)

    press(pid, "esc")
    assert_receive {:done, {:left, true}}, 5_000
  end

  # As the installers do (root Decision 818): an entry that is there is kept, said where,
  # and not asked about; the answer is the state, so it is sent as it is.
  test "a login entry already there is kept and not asked about" do
    daemon = %{flow()["daemon"] | "at_login" => true}
    {pid, session} = start(flow: %{flow() | "daemon" => daemon})
    walk_to_summary(pid, session, 3)

    assert step(pid) == {"daemon", :main}
    text = screen_text(pid, session)
    assert text =~ "Troupe starts when you log in"
    assert text =~ "From /c/unit. troupe daemon login off takes it back"
    refute text =~ "Only when an app needs it"

    press(pid, "enter")
    assert step(pid) == {"finish", :main}
    assert screen_text(pid, session) =~ "the login entry /c/unit again, as it is"
    _ = calls()

    press(pid, "enter")
    assert_receive {:done, {:session, "s-1", _workspace}}, 5_000
    assert {"daemon", %{"at_login" => true}} in answers()
  end

  test "a plane needs its address, and finishing records the choice for the sign-in" do
    {pid, session} = start()
    press(pid, "down")
    press(pid, "enter")
    assert screen_text(pid, session) =~ "the plane's address is needed"
    assert answers() == []

    type(pid, "https://plane.example")
    enter(pid)
    assert answers() == [{"where", %{"choice" => "plane", "plane_url" => "https://plane.example"}}]
    assert screen_text(pid, session) =~ "Sign in next"

    press(pid, "enter")
    assert_receive {:done, {:plane, "https://plane.example"}}, 5_000
    assert answers() == [{"finish", %{}}]
  end

  test "a flow another client left half-way starts again at the top" do
    left = %{flow() | "step" => "key", "answers" => %{"where" => %{"choice" => "local"}}}
    {pid, session} = start(flow: left)

    assert answers() == [{"where", %{"back" => true}}]
    assert step(pid) == {"where", :main}
    assert screen_text(pid, session) =~ "Where does the work run?"
  end

  test "what is already on the machine is offered first, and keeping a config.yaml is answered at once" do
    detected = %{
      flow()["detected"]
      | "env" => ["ANTHROPIC_API_KEY"],
        "config" => %{"usable" => true, "provider" => "openai", "path" => "/c/config.yaml"}
    }

    {pid, session} = start(flow: %{flow() | "detected" => detected})
    enter(pid)

    rows = screen(pid, session)
    at = fn text -> Enum.find_index(rows, &String.contains?(&1, text)) end

    assert at.("ANTHROPIC_API_KEY is set on this computer") <
             at.("A working config.yaml (openai)")

    assert at.("A working config.yaml (openai)") < at.("Claude, at Anthropic's own endpoint")

    to_choice(pid, session, "A working config.yaml")
    _ = calls()
    enter(pid)
    assert answers() == [{"provider", %{"reuse" => "config"}}]
    assert step(pid) == {"workspace", :main}
  end

  # -- a person and a daemon, played --------------------------------------------------

  defp start(opts \\ []) do
    test = self()
    {:ok, daemon} = Agent.start_link(fn -> Keyword.get(opts, :flow, flow()) end)
    refuse = Keyword.get(opts, :refuse)

    call = fn method, params ->
      send(test, {:call, method, params})
      Agent.get_and_update(daemon, &answer(&1, method, params, refuse))
    end

    session = CellSession.new(120, 40)

    {:ok, pid} =
      ExRatatui.Server.start_link(
        mod: Setup,
        transport: {:cell_session, session, fn _ -> :ok end},
        name: nil,
        call: call,
        workspace: Keyword.get(opts, :workspace, tmp_workspace()),
        offer_fake: Keyword.get(opts, :offer_fake, false),
        on_done: fn outcome -> send(test, {:done, outcome}) end
      )

    {pid, session}
  end

  defp flow do
    %{
      "needed" => true,
      "step" => "where",
      "answers" => %{},
      "detected" => %{
        "env" => [],
        "opencode" => %{"providers" => [], "default" => nil},
        "config" => %{"usable" => false, "path" => "/c/config.yaml"},
        "plane" => %{"url" => nil}
      },
      "key_storage" => %{"path" => "/c/config.yaml"},
      "offered" => [],
      "suggested" => %{"default" => nil, "cheap" => nil},
      "check" => nil,
      "daemon" => %{
        "at_login" => false,
        "kind" => "systemd",
        "path" => "/c/unit",
        "command" => "/bin/troupe-daemon"
      },
      "session" => nil
    }
  end

  defp answer(flow, "setup.get", _params, _refuse), do: {{:ok, flow}, flow}

  defp answer(flow, "setup.answer", %{"step" => step, "answer" => %{"back" => true}}, _refuse) do
    flow = back_to(flow, step)
    {{:ok, flow}, flow}
  end

  defp answer(flow, "setup.answer", %{"step" => step}, step) do
    reason =
      "invalid_params: troupe-daemon is not on the PATH, so there is nothing to start at login"

    {{:error, reason}, flow}
  end

  defp answer(flow, "setup.answer", %{"step" => "key", "answer" => answer}, _refuse) do
    flow = back_to(flow, "key")

    flow =
      if String.starts_with?(answer["api_key"] || "", "bad"),
        do: %{
          flow
          | "check" => %{"state" => "refused", "reason" => "401 unauthorized: the key was refused"}
        },
        else: %{
          flow
          | "step" => "models",
            "answers" => Map.put(flow["answers"], "key", %{"source" => "typed"}),
            "offered" => [
              %{"id" => "m-big", "context" => 200_000},
              %{"id" => "m-small", "input" => 1.0, "output" => 5.0}
            ],
            "suggested" => %{"default" => "m-big", "cheap" => "m-small"},
            "check" => %{"state" => "ok", "reason" => nil}
        }

    {{:ok, flow}, flow}
  end

  # A finished flow is answered, and a fresh one takes its place.
  defp answer(flow, "setup.answer", %{"step" => "finish", "answer" => answer}, _refuse) do
    workspace = get_in(flow, ["answers", "workspace", "workspace"])
    session = if workspace, do: %{"session_id" => "s-1", "workspace" => workspace}
    answers = Map.put(flow["answers"], "finish", answer)
    {{:ok, %{flow | "step" => "done", "answers" => answers, "session" => session}}, flow()}
  end

  defp answer(flow, "setup.answer", %{"step" => step, "answer" => answer}, _refuse) do
    flow = back_to(flow, step)

    next =
      case {step, answer} do
        {"where", %{"choice" => "plane"}} -> "finish"
        {"where", _} -> "provider"
        {"provider", %{"reuse" => _}} -> "workspace"
        {"provider", _} -> "key"
        {"models", _} -> "workspace"
        {"workspace", _} -> "daemon"
        {"daemon", _} -> "finish"
      end

    accepted =
      if step == "provider" and answer["provider"],
        do: Map.put_new(answer, "base_url", nil),
        else: answer

    flow = %{flow | "step" => next, "answers" => Map.put(flow["answers"], step, accepted)}
    {{:ok, flow}, flow}
  end

  defp back_to(flow, step) do
    steps = ~w(where provider key models workspace daemon finish)
    index = Enum.find_index(steps, &(&1 == step))
    %{flow | "step" => step, "answers" => Map.take(flow["answers"], Enum.take(steps, index))}
  end

  # -- keys and what they sent --------------------------------------------------------

  defp enter(pid) do
    press(pid, "enter")
    settle(pid)
  end

  defp settle(pid), do: eventually(fn -> :sys.get_state(pid).user_state.busy == nil end)

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

  # Anthropic with a typed key, then Enter at the main model, the small one, the project
  # and at login (`presses` of those four): the summary, or the step short of it.
  defp walk_to_summary(pid, session, presses \\ 4) do
    enter(pid)
    to_choice(pid, session, "Anthropic")
    enter(pid)
    type(pid, "sk-ant-x")
    enter(pid)
    for _ <- 1..presses, do: press(pid, "enter")
    if presses == 4, do: assert(step(pid) == {"finish", :main})
  end

  # Every daemon call made since the last look, in order.
  defp calls(acc \\ []) do
    receive do
      {:call, method, params} -> calls([{method, params} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp answers do
    for {"setup.answer", %{"step" => step, "answer" => answer}} <- calls(), do: {step, answer}
  end
end
