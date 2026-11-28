defmodule Troupe.RemoteCheckpointTest do
  @moduledoc """
  A session opened from its latest checkpoint (#1183), against a fake
  server that holds a log the session tree wrote (`test/fixtures/checkpoints/manual.jsonl`,
  checkpoints at 33 and 46, the latest standing for 45): the window starts with the
  summary and the events after it, PgUp or Home at the top pages the history in above it,
  and a reattach resumes from the journal without the history.
  """

  use ExUnit.Case, async: false

  import Troupe.RemoteHelpers
  import Troupe.TestHelpers, only: [eventually: 1]
  import Troupe.TUIHelpers

  alias Troupe.Client
  alias Troupe.FakeRemote
  alias Troupe.Remote.Translate
  alias Troupe.UI.TUI.{Model, View}

  @moduletag :remote

  @recorded Path.expand(Path.join([File.cwd!(), "..", "..", "test", "fixtures", "checkpoints"]))
  @checkpoints %{"checkpoints" => true}
  @through 45

  test "the window opens on the summary and the events after the checkpoint, and nothing before" do
    {remote, url} = start_remote!(sessions: [fixture()], capabilities: @checkpoints)
    sid = attach!(connect!(remote, url), "s-cp")
    eventually(fn -> held(sid) |> Enum.member?(51) end)

    assert [subscribe] = subscribes(remote)
    assert subscribe["from"] == "checkpoint"
    refute Map.has_key?(subscribe, "from_seq")

    # The checkpoint's facts, at its `through`, and the five events after the checkpoint
    # that draw anything; nothing of the 44 before.
    assert held(sid) == [@through, 47, 48, 49, 50, 51]

    {pid, screen} = start_tui(sid)
    eventually(fn -> user_state(pid).model.windows["root"] != nil end)
    press(pid, "1")

    text = screen_text(pid, screen)
    assert text =~ "Earlier · summarised at"
    assert text =~ "summary two"
    assert text =~ "seventh"
    assert text =~ "PgUp loads earlier"
    refute text =~ "sixth"
    refute text =~ "fourth"

    [entry | _] = transcript(pid)
    assert {:earlier, _} = entry
    assert user_state(pid).model.windows["root"].goal == "keep the tests green"

    GenServer.stop(pid, :normal)
  end

  test "PgUp at the top draws the history above the summary in order, keeps the row, and stops" do
    {remote, url} =
      start_remote!(sessions: [fixture()], capabilities: @checkpoints, events_page: 20)

    sid = attach!(connect!(remote, url), "s-cp")
    eventually(fn -> held(sid) |> Enum.member?(51) end)

    # A pane shorter than the tail, so the view has somewhere to stay.
    {pid, screen} = start_tui(sid, height: 16)
    eventually(fn -> user_state(pid).model.windows["root"] != nil end)
    press(pid, "1")
    tail = transcript(pid)

    # Home goes to the top and asks for nothing: it was not at the top yet.
    press(pid, "home")
    assert %{offset: 0, max_off: max_off} = View.pane_geometry(user_state(pid))
    assert max_off > 0
    assert pages(remote) == []
    assert screen_text(pid, screen) =~ "PgUp loads earlier"

    # At the top, PgUp asks for the page before the checkpoint: the twenty before it, as
    # the one before those, 25, is the root's rest.
    press(pid, "page_up")
    eventually(fn -> earlier(pid).before == 26 end)
    assert pages(remote) == [46]

    # The row the reader was on, the summary's header, is still the one at the top, with
    # the page above it.
    assert top_line(pid) =~ "Earlier"
    assert {:user, "sixth"} in transcript(pid)
    refute screen_text(pid, screen) =~ "PgUp loads earlier"

    # Home goes to the top; at the top it asks for the next page, until there is none. The
    # twenty before 26 begin mid-turn, so that page starts after the rest at 9, and the
    # last is the first turn, from seq 1.
    for before <- [10, 1] do
      press(pid, "home")
      press(pid, "home")
      eventually(fn -> earlier(pid).before == before end)
    end

    assert pages(remote) == [46, 26, 10]
    assert earlier(pid).more == false

    press(pid, "home")
    press(pid, "page_up")
    _ = user_state(pid)
    assert pages(remote) == [46, 26, 10]
    refute screen_text(pid, screen) =~ "loads earlier"

    # Above the summary, the history as one fold of seqs 1 to 45 draws it; below it, the
    # tail as it was.
    {history, [{:earlier, _} | after_summary]} =
      Enum.split_while(transcript(pid), &(not match?({:earlier, _}, &1)))

    assert history == whole_history()
    assert [{:earlier, _} | ^after_summary] = tail

    GenServer.stop(pid, :normal)
  end

  # A page of three, cut at a turn as the plane cuts it: the page after the compaction's
  # rests is two events, the turn from 10 to 20 comes whole at eleven, and each says there
  # is more until the first turn, from seq 1.
  test "pages shorter and longer than asked draw the whole history and stop at seq 1" do
    {remote, url} =
      start_remote!(sessions: [fixture()], capabilities: @checkpoints, events_page: 3)

    sid = attach!(connect!(remote, url), "s-cp")
    eventually(fn -> held(sid) |> Enum.member?(51) end)

    {pid, _screen} = start_tui(sid, height: 16)
    eventually(fn -> user_state(pid).model.windows["root"] != nil end)
    press(pid, "1")

    for before <- [44, 39, 33, 31, 26, 21, 10, 1] do
      assert earlier(pid).more == true
      press(pid, "home")
      press(pid, "home")
      eventually(fn -> earlier(pid).before == before end)
    end

    assert pages(remote) == [46, 44, 39, 33, 31, 26, 21, 10]
    assert earlier(pid).more == false

    {history, [{:earlier, _} | _]} =
      Enum.split_while(transcript(pid), &(not match?({:earlier, _}, &1)))

    assert history == whole_history()

    GenServer.stop(pid, :normal)
  end

  # The side box's session totals (#1196): the calls and money of the turns before the
  # checkpoint and those after it, what the session cost from seq 1.
  test "the side box counts the calls and money of the whole session, not the tail's alone" do
    {remote, url} = start_remote!(sessions: [fixture()], capabilities: @checkpoints)
    sid = attach!(connect!(remote, url), "s-cp")
    eventually(fn -> held(sid) |> Enum.member?(51) end)

    {pid, screen} = start_tui(sid, width: 120)
    eventually(fn -> user_state(pid).model.windows["root"] != nil end)
    press(pid, "1")

    whole = whole_window()
    last = whole.last_turn
    assert whole.cost.calls > last.calls
    session = "#{whole.cost.calls} calls · #{Model.cost(whole)}"

    assert screen_text(pid, screen) =~ "│  " <> session
    assert user_state(pid).model.windows["root"].cost == whole.cost

    GenServer.stop(pid, :normal)
  end

  # The wheel at the top (#1196): a notch up with the pane at its top pages back as PgUp
  # does, and a second notch while the page is on its way asks nothing more.
  test "the wheel at the top pages the history in once" do
    {remote, url} =
      start_remote!(sessions: [fixture()], capabilities: @checkpoints, events_page: 20)

    sid = attach!(connect!(remote, url), "s-cp")
    eventually(fn -> held(sid) |> Enum.member?(51) end)

    {pid, _screen} = start_tui(sid, height: 16)
    eventually(fn -> user_state(pid).model.windows["root"] != nil end)
    press(pid, "1")

    # Short of the top the wheel scrolls and asks nothing.
    press(pid, "end")
    assert View.pane_geometry(user_state(pid)).offset > 0
    wheel(pid, :up)
    _ = user_state(pid)
    assert pages(remote) == []

    # Two notches at the top: the first asks, and the second either finds the page on its
    # way or, once it landed, a view kept on its row below it, which it scrolls.
    press(pid, "home")
    wheel(pid, :up)
    wheel(pid, :up)
    eventually(fn -> earlier(pid).before == 26 end)
    _ = user_state(pid)
    assert pages(remote) == [46]
    assert {:user, "sixth"} in transcript(pid)

    GenServer.stop(pid, :normal)
  end

  test "a reattach resumes from the journal's cursor and draws the summary and tail without the history" do
    {remote, url} = start_remote!(sessions: [fixture()], capabilities: @checkpoints)
    origin = connect!(remote, url)
    sid = attach!(origin, "s-cp")
    eventually(fn -> held(sid) |> Enum.member?(51) end)

    # The session's worker and journal go, as at a restart; the plane's connection stays.
    for {_id, child, _type, _modules} <- DynamicSupervisor.which_children(Troupe.Remote.Sessions),
        is_pid(child),
        do: DynamicSupervisor.terminate_child(Troupe.Remote.Sessions, child)

    FakeRemote.emit(remote, "s-cp", "llm_response", FakeRemote.said("while away"), agent: ["root"])
    sid = attach!(origin, "s-cp")
    eventually(fn -> held(sid) |> Enum.member?(52) end)

    assert [%{"from" => "checkpoint"}, again] = subscribes(remote)
    assert again["from_seq"] == 51
    refute Map.has_key?(again, "from")
    assert pages(remote) == []

    {pid, screen} = start_tui(sid)
    eventually(fn -> user_state(pid).model.windows["root"] != nil end)
    press(pid, "1")

    text = screen_text(pid, screen)
    assert text =~ "summary two"
    assert text =~ "while away"
    refute text =~ "sixth"
    assert earlier(pid).before == @through + 1

    GenServer.stop(pid, :normal)
  end

  test "a log with no checkpoint opens from seq 1 and draws what it drew without the capability" do
    log = recorded() |> Enum.take(30)

    {remote, url} =
      start_remote!(
        sessions: [fixture(id: "s-cp", events: log), fixture(id: "s-old", events: log)],
        capabilities: @checkpoints
      )

    origin = connect!(remote, url)
    sid = attach!(origin, "s-cp")
    eventually(fn -> held(sid) |> Enum.member?(30) end)

    assert [%{"from" => "checkpoint"}] = subscribes(remote)
    assert held(sid) |> Enum.min() == 1

    plain = Translate.memory(:remote, "code")
    {events, _} = Enum.flat_map_reduce(log, plain, &Translate.durable("s-cp", &1, &2))
    expected = Model.rebuild("s-cp", "remote", events).windows["root"].agents["root"].transcript
    model = Model.rebuild(sid, "remote", Client.events(sid))
    assert model.windows["root"].agents["root"].transcript == expected
    assert Model.earlier(model, "root") == nil
  end

  test "a checkpoint in a shape this client does not read is replayed past from seq 1" do
    log =
      Enum.map(recorded(), fn
        %{"type" => "checkpoint"} = event -> put_in(event, ["data", "shape"], "session/9")
        event -> event
      end)

    {remote, url} = start_remote!(sessions: [fixture(events: log)], capabilities: @checkpoints)
    sid = attach!(connect!(remote, url), "s-cp")
    eventually(fn -> held(sid) |> Enum.member?(51) end)

    assert [%{"from" => "checkpoint"}, %{"from_seq" => 0}] = subscribes(remote)
    assert held(sid) |> Enum.min() == 1
    assert sid |> Model.rebuild("remote", Client.events(sid)) |> Model.earlier("root") == nil
  end

  # Live events and a page: the page goes above the summary, whatever arrived meanwhile
  # after the tail, where it arrived.
  test "a live event that lands while a page loads stays after the tail" do
    log = recorded()
    [checkpoint] = Enum.filter(log, &(&1["seq"] == 46))
    {:ok, seed, memory} = Translate.checkpoint("s-1", checkpoint, Translate.memory())
    {tail, memory} = translate(Enum.filter(log, &(&1["seq"] > @through)), memory)

    live = %{
      "seq" => 52,
      "type" => "user_input",
      "agent" => ["root"],
      "data" => %{"text" => "arrived meanwhile"}
    }

    {live, _memory} = translate([live], memory)
    {page, _memory} = translate(Enum.filter(log, &(&1["seq"] <= @through)), Translate.memory())

    model =
      "s-1"
      |> Model.rebuild("/w", seed ++ tail)
      |> Model.loading_earlier("root")
      |> then(&Enum.reduce(live, &1, fn e, m -> Model.apply(m, e) end))
      |> Model.prepend("root", page, false, 1)

    transcript = model.windows["root"].agents["root"].transcript
    assert List.last(transcript) == {:user, "arrived meanwhile"}
    {history, [{:earlier, _} | _]} = Enum.split_while(transcript, &(not match?({:earlier, _}, &1)))
    assert {:user, "first"} in history
    earlier = Model.earlier(model, "root")
    assert earlier == %{earlier | before: 1, more: false, loading: false}
  end

  defp fixture(fields \\ []) do
    FakeRemote.session(Keyword.merge([id: "s-cp", profile: "code", events: recorded()], fields))
  end

  defp recorded do
    [@recorded, "manual.jsonl"]
    |> Path.join()
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  defp translate(events, memory),
    do: Enum.flat_map_reduce(events, memory, &Translate.durable("s-1", &1, &2))

  # The root's entries a fold of seqs 1 to the checkpoint's `through` draws, as one page.
  defp whole_history do
    {events, _} =
      recorded()
      |> Enum.filter(&(&1["seq"] <= @through))
      |> Enum.flat_map_reduce(Translate.memory(:remote, "code"), &Translate.durable("s-cp", &1, &2))

    Model.rebuild("s-cp", "remote", events).windows["root"].agents["root"].transcript
  end

  # The root window the fold of the whole log draws.
  defp whole_window do
    {events, _} =
      Enum.flat_map_reduce(
        recorded(),
        Translate.memory(:remote, "code"),
        &Translate.durable("s-cp", &1, &2)
      )

    Model.rebuild("s-cp", "remote", events).windows["root"]
  end

  defp held(sid),
    do: sid |> Client.events() |> Enum.map(& &1.seq) |> Enum.reject(&is_nil/1) |> Enum.uniq()

  defp transcript(pid), do: user_state(pid).model.windows["root"].agents["root"].transcript

  defp earlier(pid), do: Model.earlier(user_state(pid).model, "root")

  # The first line drawn at the top of the pane's view.
  defp top_line(pid) do
    g = View.pane_geometry(user_state(pid))
    {idx, row} = View.block_at(g.heights, g.offset)
    assert row == 0
    {_kind, line} = g.blocks |> Enum.at(idx) |> hd()
    if is_binary(line), do: line, else: Enum.map_join(line, &elem(&1, 1))
  end

  defp subscribes(remote) do
    for {"subscribe", %{"topic" => "session:s-cp"} = params} <- FakeRemote.calls(remote),
        do: params
  end

  defp pages(remote) do
    for {"session.events", %{"session_id" => "s-cp", "before" => before}} <-
          FakeRemote.calls(remote),
        do: before
  end
end
