defmodule Troupe.RecordedCheckpointsTest do
  @moduledoc """
  The terminal's fold against the checkpoints sessions wrote (#1181), in the logs under
  `test/fixtures/checkpoints/` at the repository's root, read through
  `Troupe.Remote.Translate` as a daemon's worker hands them over.

  Two things hold for each checkpoint. Its facts are what this fold says at its `through`
  on the fields both keep: the window's usage, its goal, the root's task list, and what
  waits on a person. And this fold started from the checkpoint, its facts given to it as
  the events they stand for, then the tail, says what the fold from seq 1 says on those
  fields: the history before `through` aside, nothing is lost by starting there.
  """

  use ExUnit.Case, async: true

  alias Troupe.Remote.{Branch, Translate}
  alias Troupe.UI.TUI.Model

  @recorded Path.expand(Path.join([File.cwd!(), "..", "..", "test", "fixtures", "checkpoints"]))

  for name <- ~w(manual threshold overflow background_approval) do
    test "#{name}: each checkpoint is the fold at its through, and from it the fold of the whole" do
      log = recorded(unquote(name))
      checkpoints = Enum.filter(log, &(&1["type"] == "checkpoint"))
      assert checkpoints != []
      whole = shared(log)

      for checkpoint <- checkpoints do
        through = checkpoint["data"]["through"]

        assert facts_shared(checkpoint["data"]["facts"]) ==
                 shared(Enum.filter(log, &(&1["seq"] <= through))),
               "the facts at #{through}"

        tail = Enum.filter(log, &(&1["seq"] > through))
        assert shared(seeded(checkpoint) ++ tail) == whole, "from #{checkpoint["seq"]}"
      end
    end
  end

  # The window a subscription from a checkpoint opens (#1183): `Translate.checkpoint/3` in
  # place of the history, then the tail, says what the fold from seq 1 says, and its
  # transcript starts with the summary.
  for name <- ~w(manual threshold overflow background_approval) do
    test "#{name}: a window opened from each checkpoint says what the whole log does" do
      log = recorded(unquote(name))
      whole = shared(log)

      for checkpoint <- Enum.filter(log, &(&1["type"] == "checkpoint")) do
        through = checkpoint["data"]["through"]
        {:ok, seed, memory} = Translate.checkpoint("s-1", checkpoint, Translate.memory())
        assert seed |> Enum.map(&(&1.seq || 0)) |> Enum.max() == through

        {tail, _memory} =
          log
          |> Enum.filter(&(&1["seq"] > through))
          |> Enum.flat_map_reduce(memory, &Translate.durable("s-1", &1, &2))

        [window] = "s-1" |> Model.rebuild("/w", seed ++ tail) |> Model.windows()
        assert local_shared(window) == whole, "from #{checkpoint["seq"]}"

        assert [{:earlier, %{lines: [_ | _]}} | _] = window.agents["root"].transcript
      end
    end
  end

  # What the side box says the session cost (#1196): the root's turns before the
  # checkpoint, which its facts carry, and the tail's after it, as the fold from seq 1 says.
  for name <- ~w(manual threshold overflow background_approval) do
    test "#{name}: a window opened from each checkpoint counts the calls and money before it" do
      log = recorded(unquote(name))
      [whole] = windows(log)

      for checkpoint <- Enum.filter(log, &(&1["type"] == "checkpoint")) do
        assert opened(log, checkpoint).cost == whole.cost, "from #{checkpoint["seq"]}"
      end
    end
  end

  test "a checkpoint written before calls were counted gives the tail's turns alone" do
    log = recorded("manual")
    checkpoint = log |> Enum.filter(&(&1["type"] == "checkpoint")) |> List.last()
    through = checkpoint["data"]["through"]
    old = update_in(checkpoint, ["data", "facts"], &Map.drop(&1, ["calls", "turns_cost_micros"]))

    tail_turns =
      for %{"type" => "turn_ended", "agent" => ["root"], "seq" => seq, "data" => %{"turn" => t}} <-
            log,
          seq > through,
          do: t

    assert opened(log, old).cost == %{
             calls: tail_turns |> Enum.map(& &1["calls"]) |> Enum.sum(),
             cost_micros: tail_turns |> Enum.map(& &1["cost_micros"]) |> Enum.sum(),
             unpriced: 0
           }
  end

  # A child its root sent off in the background before the checkpoint and that ended
  # after it (#1196): named, begun when its delegation was, and ended when its end
  # came; and once the history is paged in, the call it was waiting on is closed by the
  # end the tail brought, never drawn as running.
  test "background_approval: a delegation open across the checkpoint is drawn closed" do
    log = recorded("background_approval")
    [checkpoint] = Enum.filter(log, &(&1["type"] == "checkpoint"))
    through = checkpoint["data"]["through"]
    child = "root/general#1"
    began = Enum.find(log, &(&1["type"] == "delegation_started"))["ts"]
    {:ok, at, _} = DateTime.from_iso8601(began)

    model = open_model(log, checkpoint)
    agent = model.windows["root"].agents[child]
    assert agent.name == "general"
    assert agent.started_at == DateTime.to_unix(at, :millisecond)
    assert is_integer(agent.ended_at)

    row = %{window: model.windows["root"], path: child, agent: agent, root?: false}
    assert Model.agent_state(row) == :done

    paged = Model.prepend(model, "root", history(log, 1, through), false, 1)
    tools = for {:tool, t} <- paged.windows["root"].agents[child].transcript, do: t.status
    assert tools != [] and Enum.all?(tools, &(&1 == :ok))
  end

  # A subagent the tail never named, its start in a page older than the one that first
  # drew it (#1196): the later page names it.
  test "background_approval: a paged-in agent takes the name an older page brings" do
    log = recorded("background_approval")
    [checkpoint] = Enum.filter(log, &(&1["type"] == "checkpoint"))
    through = checkpoint["data"]["through"]
    child = "root/general#1"
    unnamed = update_in(checkpoint, ["data", "facts"], &Map.put(&1, "running", []))

    started =
      Enum.find(log, &(&1["type"] == "agent_started" and &1["agent"] == ["root", "general#1"]))

    model = open_model(log, unnamed)
    assert model.windows["root"].agents[child].name == nil

    model =
      Model.prepend(
        model,
        "root",
        history(log, started["seq"] + 1, through),
        true,
        started["seq"] + 1
      )

    assert model.windows["root"].agents[child].name == nil

    model = Model.prepend(model, "root", history(log, 1, started["seq"]), false, 1)
    assert model.windows["root"].agents[child].name == "general"
  end

  test "a branch's window pages its own history, and the session's own window keeps its own" do
    log = recorded("manual")
    checkpoint = log |> Enum.filter(&(&1["type"] == "checkpoint")) |> List.last()
    through = checkpoint["data"]["through"]

    as_branch = fn events ->
      Enum.map(
        events,
        &%{&1 | session_id: "s-1", agent_path: Branch.rewrite(&1.agent_path, "code-1")}
      )
    end

    {:ok, seed, memory} = Translate.checkpoint("s-1", checkpoint, Translate.memory())
    {:ok, branch_seed, _} = Translate.checkpoint("b-1", checkpoint, Translate.memory())

    opened = %Troupe.Event{
      session_id: "s-1",
      agent_path: "code-1",
      type: :branch_spawned,
      ts: 0,
      data: %{name: "code", isolation: :shared, prompt: "", session_id: "b-1"}
    }

    {tail, _} = translate(Enum.filter(log, &(&1["seq"] > through)), memory)
    branch_seed = Enum.reject(branch_seed, &(&1.type == :branch_spawned))
    model = Model.rebuild("s-1", "/w", seed ++ tail ++ [opened] ++ as_branch.(branch_seed))

    assert %{session_id: "s-1", before: before} = Model.earlier(model, "root")
    assert before == through + 1
    assert %{session_id: "b-1", before: ^before} = Model.earlier(model, "code-1")

    {page, _} = translate(Enum.filter(log, &(&1["seq"] <= through)), Translate.memory())
    paged = Model.prepend(model, "code-1", as_branch.(page), false, 1)

    assert Model.earlier(paged, "code-1").more == false
    assert Model.earlier(paged, "root") == Model.earlier(model, "root")
    assert paged.windows["root"] == model.windows["root"]
    assert {:user, "first"} in paged.windows["code-1"].agents["code-1"].transcript
  end

  test "a checkpoint in a shape this client does not read is not started from" do
    [checkpoint | _] = "manual" |> recorded() |> Enum.filter(&(&1["type"] == "checkpoint"))
    unknown = put_in(checkpoint, ["data", "shape"], "session/9")
    assert Translate.checkpoint("s-1", unknown, Translate.memory()) == :unknown
  end

  test "a checkpoint draws nothing in the window" do
    log = recorded("manual")
    without = Enum.reject(log, &(&1["type"] == "checkpoint"))
    assert transcript(log) == transcript(without)
  end

  # What both folds keep, as this one keeps it.
  defp shared(events) do
    [window] = windows(events)
    local_shared(window)
  end

  defp local_shared(window) do
    %{
      usage: window.usage,
      goal: window.goal,
      todos: Enum.map(window.agents["root"].todos, & &1.text),
      pending: window.pending |> Enum.map(& &1.call_id) |> Enum.sort()
    }
  end

  # The same fields, as the checkpoint says them.
  defp facts_shared(facts) do
    usage = facts["usage"]

    %{
      usage: %{
        input: usage["input_tokens"],
        output: usage["output_tokens"],
        cache_read: usage["cache_read"],
        cache_write: usage["cache_write"]
      },
      goal: facts["goal"],
      todos: Enum.map(facts["todos"], & &1["content"]),
      pending:
        (facts["open_approvals"] ++ facts["open_questions"])
        |> Enum.map(& &1["call_id"])
        |> Enum.sort()
    }
  end

  # The checkpoint's facts as events this fold reads, at seqs below its `through`: what a
  # reader starting there begins from.
  defp seeded(checkpoint) do
    facts = checkpoint["data"]["facts"]
    root = ["root"]

    usage = %{
      "message" => %{"role" => "assistant", "content" => []},
      "usage" => facts["usage"]
    }

    open =
      Enum.map(facts["open_approvals"], &{"approval_requested", &1["agent"], &1["data"]}) ++
        Enum.map(facts["open_questions"], &{"question_asked", &1["agent"], &1["data"]})

    goal = if facts["goal"], do: [{"goal_set", root, %{"text" => facts["goal"]}}], else: []

    ([{"agent_started", root, %{"profile" => facts["agent"]}}, {"llm_response", root, usage}] ++
       goal ++ [{"todo_updated", root, %{"items" => facts["todos"]}}] ++ open)
    |> Enum.with_index(1)
    |> Enum.map(fn {{type, agent, data}, seq} ->
      %{
        "seq" => seq,
        "type" => type,
        "agent" => agent,
        "data" => data,
        "actor" => %{"kind" => "system"}
      }
    end)
  end

  # The window a subscription from `checkpoint` opens, the tail folded on.
  defp opened(log, checkpoint) do
    [window] = log |> open_model(checkpoint) |> Model.windows()
    window
  end

  defp open_model(log, checkpoint) do
    {:ok, seed, memory} = Translate.checkpoint("s-1", checkpoint, Translate.memory())

    {tail, _memory} =
      translate(Enum.filter(log, &(&1["seq"] > checkpoint["data"]["through"])), memory)

    Model.rebuild("s-1", "/w", seed ++ tail)
  end

  # A page of the history from seq `from` to `to`, as the worker translates one.
  defp history(log, from, to) do
    {page, _memory} = translate(Enum.filter(log, &(&1["seq"] in from..to)), Translate.memory())
    page
  end

  defp translate(events, memory),
    do: Enum.flat_map_reduce(events, memory, &Translate.durable("s-1", &1, &2))

  defp windows(recorded) do
    "s-1" |> Model.rebuild("/w", translated(recorded)) |> Model.windows()
  end

  defp transcript(recorded) do
    [window] = windows(recorded)
    window.agents["root"].transcript
  end

  defp translated(recorded) do
    {events, _memory} =
      Enum.flat_map_reduce(recorded, Translate.memory(), &Translate.durable("s-1", &1, &2))

    events
  end

  defp recorded(name) do
    [@recorded, name <> ".jsonl"]
    |> Path.join()
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end
end
