defmodule Troupe.FirstPromptWaitTest do
  @moduledoc """
  A prompt that draws nothing: the curtain line says what is waited
  on from the first second, the facts take the flourish's place once the wait is news,
  the pane draws a box after 45 s saying what was sent, what has happened since and what
  to do, the box goes with the first byte or the turn's end, a failed request leaves the
  window saying the model's sentence, and a headless run prints one line at the same
  thresholds. Most of it is drawn from a fold, the clock driven by hand; the last tests
  run against the daemon's scripted model.
  """

  use ExUnit.Case, async: false

  import Troupe.TestHelpers
  import Troupe.TUIHelpers

  alias ExRatatui.{CellSession, Frame}
  alias Troupe.Event
  alias Troupe.Remote.Translate
  alias Troupe.UI.Headless.Printer
  alias Troupe.UI.TUI.{Model, View}

  # The prompt went at this wall-clock time; the clock is read `ms` after it.
  @t0 1_700_000_000_000
  @host "api.anthropic.com"

  defp at(ms), do: @t0 + ms

  defp event(type, data, ms, opts \\ []) do
    %Event{
      session_id: "s-1",
      agent_path: Keyword.get(opts, :path, "root"),
      type: type,
      data: data,
      ts: at(ms),
      transient?: Keyword.get(opts, :transient?, false)
    }
  end

  defp opened do
    [
      event(:branch_spawned, %{name: "build", isolation: :shared, prompt: ""}, -5_000),
      event(:input, %{source: :user, content: "fix the failing test", command_id: "c1"}, 0)
    ]
  end

  defp thinking(ms),
    do: event(:agent_state, %{to: :thinking, model: "claude"}, ms, transient?: true)

  defp fold(events), do: "s-1" |> Model.rebuild("/w", events) |> Model.with_host(@host)

  defp window(events), do: Model.session_window(fold(events))

  defp line(events, ms), do: Model.curtain_line(window(events), "root", 0, at(ms))

  ## Drawn

  defp draw(model, now) do
    {width, height} = {120, 60}

    state = %{
      session_id: "s-1",
      workspace: "/w",
      model: model,
      focus: {:window, "root"},
      cmd_text: "",
      cmd_pos: 0,
      win_text: "",
      win_pos: 0,
      agents: ["build"],
      commands: [],
      palette: nil,
      tick: 0,
      now: now,
      quit_armed: false,
      win_armed: nil,
      expanded: false,
      detail: :quiet,
      pane: %{agent: nil, scroll: :follow, seen_entries: 0, open: MapSet.new()},
      selection: nil,
      answer: nil,
      size: {width, height},
      theme: %{depth: :truecolor, mode: :dark}
    }

    session = CellSession.new(width, height)
    :ok = CellSession.draw(session, View.render(state, %Frame{width: width, height: height}))

    CellSession.take_cells(session).cells
    |> Enum.group_by(& &1.row)
    |> Enum.sort()
    |> Enum.map_join("\n", fn {_row, cs} ->
      cs |> Enum.sort_by(& &1.col) |> Enum.map_join("", & &1.symbol) |> String.trim_trailing()
    end)
  end

  ## The curtain line

  test "before the request: preparing with the flourish, then the facts alone from 10 s" do
    assert line(opened(), 4_000) == "◐ the house lights go down — preparing (00:04)"
    assert line(opened(), 9_000) == "◐ the house lights go down — preparing (00:09)"
    assert line(opened(), 14_000) == "◐ the daemon has not sent the model request yet (00:14)"

    # A tile says the facts alone, as it always did.
    tile = Model.tile_lines(window(opened()), 0, at(14_000), false)
    assert Enum.any?(tile, &(Model.line_text(&1) =~ "has not sent the model request yet (00:14)"))
    refute Enum.any?(tile, &(Model.line_text(&1) =~ "house lights"))
  end

  test "after the request: thinking as ever, then no answer from the host from 20 s" do
    requested = opened() ++ [thinking(20_000)]

    assert line(requested, 32_000) == "◐ the actors are powdering their nose — thinking (00:12)"
    assert line(requested, 55_000) == "◐ no answer from api.anthropic.com yet (00:35)"

    # Where the host is not known (a pod's configuration is its plane's), it is the model.
    w = %{window(requested) | host: nil}
    assert Model.curtain_line(w, "root", 0, at(55_000)) == "◐ no answer from the model yet (00:35)"

    # The first byte ends the wait, and the flourish comes back to the same place.
    answered = requested ++ [event(:llm_delta, %{text: "On it."}, 56_000, transient?: true)]
    assert line(answered, 60_000) == "◐ the actors are powdering their nose — thinking (00:40)"
    assert Model.waiting(window(answered), "root", at(60_000)) == nil
  end

  test "the next prompt is preparing again, and a queued copy of a line is no turn starting" do
    first =
      opened() ++
        [
          thinking(1_000),
          event(:llm_delta, %{text: "Fixed."}, 2_000, transient?: true),
          event(
            :assistant_message,
            %{content: [Troupe.Client.Message.text_block("Fixed.")]},
            3_000
          ),
          event(:agent_state, %{to: :idle}, 4_000)
        ]

    assert line(first, 30_000) == nil

    second = first ++ [event(:input, %{source: :user, content: "next", command_id: "c2"}, 70_000)]
    assert line(second, 72_000) == "◐ the house lights go down — preparing (00:02)"
    assert line(second, 84_000) == "◐ the daemon has not sent the model request yet (00:14)"

    # A line sent while the agent works is queued, and the request on the wire is still the
    # one waited on.
    queued =
      opened() ++
        [
          thinking(1_000),
          event(:input, %{source: :user, content: "also", command_id: "c3", queued: true}, 2_000)
        ]

    assert line(queued, 30_000) == "◐ no answer from api.anthropic.com yet (00:29)"
  end

  ## The box

  test "from 45 s the pane draws the box: what was sent, what happened, the last event, what to do" do
    quiet = draw(fold(opened()), at(30_000))
    refute quiet =~ "nothing has happened"

    screen = draw(fold(opened()), at(46_000))
    assert screen =~ "the daemon has not sent the model request yet (00:46)"
    assert screen =~ "nothing has happened for 00:46"
    assert screen =~ ~r/your prompt went to the daemon at \d\d:\d\d:\d\d/
    assert screen =~ "the daemon acknowledged it; it has not sent the model request"
    assert screen =~ ~r/the last event here was input, at \d\d:\d\d:\d\d/
    assert screen =~ "Esc cancels the turn"
    assert screen =~ "`troupe doctor` asks the model for a token"
    assert screen =~ "the daemon's log"
    assert screen =~ "daemon.log"
    assert Model.daemon_log() =~ "daemon.log"

    # A prompt the daemon never answered is said to be unacknowledged.
    unanswered = [
      hd(opened()),
      event(:input, %{source: :user, content: "hello", command_id: "c9", optimistic: true}, 0)
    ]

    lines = Model.wait_lines(window(unanswered), "root", at(50_000))
    assert Enum.any?(lines, &(Model.line_text(&1) =~ "the daemon has not acknowledged it"))
  end

  test "after the request the box says where it went, and goes with the first byte or the end" do
    requested = opened() ++ [thinking(50_000)]
    screen = draw(fold(requested), at(96_000))

    assert screen =~ "no answer from api.anthropic.com yet (00:46)"

    assert screen =~
             ~r/the request went to api.anthropic.com at \d\d:\d\d:\d\d; nothing has come back/

    refute screen =~ "it has not sent the model request"
    assert screen =~ ~r/the last event here was agent_state, at \d\d:\d\d:\d\d/

    byte = requested ++ [event(:llm_delta, %{text: "On it."}, 97_000, transient?: true)]
    refute draw(fold(byte), at(150_000)) =~ "nothing has happened"

    ended = requested ++ [event(:agent_state, %{to: :idle, reason: "cancelled"}, 97_000)]
    assert Model.wait_lines(window(ended), "root", at(150_000)) == []
    refute draw(fold(ended), at(150_000)) =~ "nothing has happened"

    # Waiting on a person is not waiting on the model.
    asked =
      requested ++
        [event(:question_asked, %{call_id: "q1", question: "which?", options: []}, 60_000)]

    assert Model.wait_lines(window(asked), "root", at(150_000)) == []
  end

  ## The model's sentence

  test "a failed request leaves the window saying the model's sentence, from the error on" do
    mid = opened() ++ [thinking(1_000), event(:llm_error, %{message: "no key"}, 2_000)]
    assert line(mid, 30_000) == "model error: no key"
    assert Model.waiting(window(mid), "root", at(60_000)) == nil

    ended = mid ++ [event(:agent_state, %{to: :idle}, 3_000)]
    w = window(ended)
    assert w.state == :failed_unread
    assert Model.curtain_line(w, "root", 0, at(60_000)) == "model error: no key"

    screen = draw(fold(ended), at(60_000))
    assert screen =~ "model error: no key"
    refute screen =~ "nothing has happened"

    # The same over the wire, as the daemon's events reach a window.
    wires = [
      wire("root", "user_input", %{"source" => "user", "text" => "go"}),
      wire("root", "llm_request", %{"model" => "claude"}),
      wire("root", "llm_error", %{"reason" => "no API key is configured"}),
      wire("root", "turn_ended", %{"reason" => "llm_error"})
    ]

    {events, _memory} =
      Enum.flat_map_reduce(wires, Translate.memory(:shared), &Translate.durable("s-1", &1, &2))

    w = Model.session_window(Model.rebuild("s-1", "/w", events))
    assert w.state == :failed_unread
    assert Model.curtain_line(w, "root", 0, at(60_000)) == "model error: no API key is configured"
  end

  ## The host

  test "the host is the configuration's base_url, else the provider type's own, never the key" do
    assert Model.host_of(%{
             base_url: "https://gw.example/anthropic/v1",
             provider: "anthropic",
             api_key: "k"
           }) ==
             "gw.example"

    assert Model.host_of(%{base_url: nil, provider: "anthropic", api_key: "k"}) ==
             "api.anthropic.com"

    assert Model.host_of(%{base_url: nil, provider: "ollama"}) == "localhost"
    assert Model.host_of(%{base_url: nil, provider: "fake"}) == nil
    assert Model.host_of(nil) == nil
  end

  ## Through the daemon

  test "against the daemon: the fake failing the request leaves the window on the sentence" do
    {sid, _, _} = start_session!(script: [%{"error" => "no key for this provider"}])
    say!(sid, "hello")
    await_event("root", :llm_error)

    {pid, session} = start_tui(sid)
    press(pid, "1")
    eventually(fn -> match?({:window, "root"}, user_state(pid).focus) end)
    eventually(fn -> screen_text(pid, session) =~ ~s(model error: "no key for this provider") end)
    assert user_state(pid).model.windows["root"].state == :failed_unread
    GenServer.stop(pid)
  end

  test "a headless run prints one line at the prompt and one at the request, and stops at a byte" do
    {sid, _, _} = start_session!(script: [{:text, "done"}])
    {:ok, io} = StringIO.open("")
    {:ok, printer} = Printer.start_link(session_id: sid, target: "root", io: io, stall_ms: 1_000)

    out = fn -> elem(StringIO.contents(io), 1) end
    count = fn text -> out.() |> String.split("\n") |> Enum.count(&(&1 =~ text)) end

    heard = fn type, data ->
      send(
        printer,
        {:troupe_event,
         %Event{
           session_id: sid,
           agent_path: "root",
           type: type,
           data: data,
           ts: System.system_time(:millisecond),
           transient?: true
         }}
      )
    end

    heard.(:input, %{source: :user, content: "go", command_id: "h1"})

    eventually(fn ->
      out.() =~
        "nothing has happened for 1 s: the daemon took the prompt and has not sent the model request"
    end)

    assert out.() =~ "`troupe doctor` asks the model for a token, and the daemon's log is"
    assert out.() =~ "daemon.log"

    heard.(:agent_state, %{to: :thinking})
    eventually(fn -> out.() =~ "no answer from the model for 1 s after the request" end)

    # A second request answered at once arms nothing that fires; the next prompt's line is
    # the one that comes, and the answer's line stayed one.
    heard.(:agent_state, %{to: :acting})
    heard.(:agent_state, %{to: :thinking})
    heard.(:llm_delta, %{text: "On it."})
    heard.(:input, %{source: :user, content: "again", command_id: "h2"})
    eventually(fn -> count.("nothing has happened for 1 s") == 2 end)
    assert count.("no answer from the model") == 1
    GenServer.stop(printer)
  end

  defp wire(agent, type, data) do
    %{
      "actor" => %{"kind" => "system"},
      "agent" => String.split(agent, "/"),
      "data" => data,
      "seq" => System.unique_integer([:positive, :monotonic]),
      "ts" => System.system_time(:millisecond),
      "type" => type,
      "v" => 1
    }
  end
end
