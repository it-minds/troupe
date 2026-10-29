defmodule Troupe.Agent.FirstByteTest do
  @moduledoc """
  A model call nothing comes from is given up on at `llm_first_byte_ms`, well before
  `llm_timeout_ms`, with a sentence naming the host; a call whose first byte came is held
  only to the whole call's limit. And the daemon's log follows a turn in four lines a
  person can find when a client shows nothing. The model is the fake, stalling on cue.
  """

  use Troupe.SessionCase, async: true

  import ExUnit.CaptureLog

  alias Troupe.Agent.Server

  @overflow {:error, {:http_status, 400, "prompt is too long: 250000 tokens > 200000 maximum"}}

  describe "the first-byte limit" do
    test "a call that sends nothing within llm_first_byte_ms fails the turn with the sentence", context do
      sid =
        run(context,
          steps: [{:delay, 30_000, {:text, "late"}}],
          config_overrides: [llm_first_byte_ms: 300, llm_timeout_ms: 20_000]
        )

      error = await_event(sid, :llm_error, 5_000)
      ended = await_event(sid, :turn_ended, 5_000)

      assert error.data["reason"] ==
               "the model at fake sent nothing for 300 ms: the address, the key or a proxy " <>
                 "between here and there is the usual reason; `troupe doctor` tries a small request"

      # Stopped as a call that outlasts llm_timeout_ms is: ended, and counted as a call
      # nobody priced.
      assert eventually(fn -> streams(sid) == [] end), "the stream is still running"
      assert error.data["stopped"] == %{"model" => "fake-model"}
      assert %{"calls" => 1, "unpriced" => 1} = ended.data["turn"]
    end

    test "a call whose first byte came is held to llm_timeout_ms alone", context do
      sid =
        run(context,
          steps: [{:endless, 100}],
          config_overrides: [llm_first_byte_ms: 300, llm_timeout_ms: 1_000]
        )

      error = await_event(sid, :llm_error, 5_000)
      assert error.data["reason"] =~ "did not answer in time"
      refute error.data["reason"] =~ "sent nothing"
    end

    test "a summary nothing comes from is given up on too, and changes nothing", context do
      steps =
        List.duplicate({:tools, [{"todo_read", %{}}]}, 4) ++
          [@overflow, {:delay, 30_000, {:text, "too late"}}, {:text, "done"}]

      sid = run(context, steps: steps, config_overrides: [llm_first_byte_ms: 300, llm_timeout_ms: 20_000])
      await_state(sid, [:compacting], 5_000)
      await_state(sid, [:idle], 5_000)

      assert events_of_type(sid, :compacted) == []
      assert eventually(fn -> streams(sid) == [] end), "the summariser's stream is still running"
    end
  end

  describe "the daemon's log" do
    setup do
      # The suite logs nothing below `critical`; the agent's four lines are at `info`, the
      # daemon's level, and are let through for this module alone.
      Logger.put_module_level(Server, :info)
      on_exit(fn -> Logger.delete_module_level(Server) end)
      :ok
    end

    test "says a turn is preparing, asking, has its first byte, and how it ended", context do
      log =
        capture_log(fn ->
          sid = run(context, steps: [{:text, "hello"}])
          await_event(sid, :turn_ended, 5_000)
          send(self(), {:sid, sid})
        end)

      assert_received {:sid, sid}
      prefix = "troupe: #{sid} root turn 1 "

      lines =
        log
        |> String.split("\n")
        |> Enum.filter(&String.contains?(&1, prefix))
        |> Enum.map(&(&1 |> String.split(prefix) |> List.last()))

      assert ["preparing", "asking fake-model at fake", first, ended] = lines
      assert first =~ ~r/^first byte after \d+ ms$/
      assert ended =~ ~r/^answered after \d+ ms: end_turn$/
      assert log =~ "[info] " <> prefix
    end

    test "a call given up on says so, with the sentence", context do
      log =
        capture_log(fn ->
          sid =
            run(context,
              steps: [{:delay, 30_000, {:text, "late"}}],
              config_overrides: [llm_first_byte_ms: 200]
            )

          await_event(sid, :turn_ended, 5_000)
          send(self(), {:sid, sid})
        end)

      # Other tests' sessions log into the same capture; only this one's lines count.
      assert_received {:sid, sid}
      lines = log |> String.split("\n") |> Enum.filter(&String.contains?(&1, "troupe: #{sid} "))

      assert Enum.any?(lines, &(&1 =~ ~r/root turn 1 failed after \d+ ms: the model at fake sent nothing for 200 ms/))
      refute Enum.any?(lines, &(&1 =~ "first byte after"))
    end
  end

  defp run(context, opts) do
    %{session: session} = start_session(context, opts)
    :ok = Troupe.subscribe(session.id)
    Troupe.send_input(session.id, "go")
    session.id
  end

  defp streams(sid), do: Task.Supervisor.children(Registry.tasks(sid, ["root"]))

  defp eventually(fun, tries \\ 50) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true ->
        Process.sleep(20)
        eventually(fun, tries - 1)
    end
  end
end
