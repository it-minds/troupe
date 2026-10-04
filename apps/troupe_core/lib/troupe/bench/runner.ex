defmodule Troupe.Bench.Runner do
  @moduledoc """
  Runs one scenario offline (Decision 772): its own workspace, config and state
  directories, a session of the harness this VM carries, and `Troupe.Bench.Model`
  answering it, then the run's record and what the scenario measured.

  Not the machine's daemon. The bench measures the harness of the build it ships in, and
  a daemon of another version would answer for itself; the session runs here, under the
  same applications a daemon runs, and is stopped when the scenario ends.

  While a scenario runs, `TROUPE_CONFIG_HOME` and `TROUPE_STATE_HOME` name its own
  directories, and opencode's two files name none, so nothing of the person's (their
  config, keys, agents, skills, instruction files, sessions) reaches the prompt being
  measured, and nothing the run writes lands among theirs. They are put back afterwards.
  That is process-wide, so scenarios run one at a time.
  """

  alias Troupe.Bench.{Model, Scenario}
  alias Troupe.Protocol.Event

  # Long enough for a slow machine, short enough that a hung scenario fails the bench
  # rather than the job's own timeout.
  @turn_timeout_ms 60_000

  @doc """
  Run a scenario under `base`, answering `%{record, metrics, checks, error}`.

  The record is what the run did (`record/1`); metrics and checks are the scenario's
  own. A scenario that raised, or whose turn never ended, answers its error and no
  metrics, which the report counts as a failure.
  """
  @spec run(Scenario.t(), Path.t()) :: map()
  def run(%Scenario{} = scenario, base) do
    dir = Path.join(base, scenario.name)
    work = Path.join(dir, "work")
    Enum.each(["work", "config", "state"], &File.mkdir_p!(Path.join(dir, &1)))
    Scenario.seed(scenario, work)

    # opencode's files too, which a config reads for providers when it has no key of its
    # own: they name files that are not there.
    env = %{
      "TROUPE_CONFIG_HOME" => Path.join(dir, "config"),
      "TROUPE_STATE_HOME" => Path.join(dir, "state"),
      "TROUPE_OPENCODE_CONFIG" => Path.join(dir, "no-opencode.jsonc"),
      "TROUPE_OPENCODE_AUTH" => Path.join(dir, "no-opencode-auth.json")
    }

    # In a process of its own, so the session's events and the model's notes die with
    # it rather than waiting in the caller's mailbox.
    with_env(env, fn ->
      fn -> attempt(scenario, work, Path.join(dir, "state")) end
      |> Task.async()
      |> Task.await(:infinity)
    end)
  end

  defp attempt(scenario, work, state_dir) do
    measured(scenario, work, state_dir)
  rescue
    error -> %{record: nil, metrics: [], checks: [], error: Exception.message(error)}
  catch
    :exit, reason -> %{record: nil, metrics: [], checks: [], error: "exited: " <> inspect(reason)}
  end

  defp measured(scenario, work, state_dir) do
    {:ok, workspace} = Troupe.Workspace.new(work)
    root = workspace.root_real

    {:ok, model} =
      GenServer.start(Model, steps: scenario.script, workspace: root, observer: self())

    try do
      in_session(scenario, root, model, overrides(state_dir) ++ scenario.config)
    after
      GenServer.stop(model)
    end
  end

  defp in_session(scenario, root, model, overrides) do
    config = Troupe.Config.load(root, overrides)

    {:ok, session} =
      Troupe.start_session(workspace: root, fake: model, config_overrides: overrides)

    Troupe.subscribe(session.id)

    ctx = %{
      scenario: scenario,
      session_id: session.id,
      workspace: root,
      model: model,
      config: config,
      overrides: overrides,
      marks: %{}
    }

    try do
      ctx = (scenario.drive || (&type_and_wait/1)).(ctx)
      ctx = collect(ctx)
      {metrics, checks} = scenario.measure.(ctx)
      %{record: record(ctx), metrics: metrics, checks: checks, error: nil}
    after
      Troupe.unsubscribe(session.id)
      Troupe.stop_session(session.id)
    end
  end

  # The bench's own settings, under whatever a scenario adds: the scripted model, every
  # tool allowed so no turn waits on a person, and no brief, which a librarian would be
  # started to write. The rest are the defaults, which are what is being measured.
  defp overrides(state_dir) do
    [
      provider: "fake",
      model: "fake-model",
      state_dir: state_dir,
      auto_approve: true,
      memory: false,
      memory_auto_refresh: false
    ]
  end

  @doc "Type the scenario's prompt and wait until the root's turn has ended."
  @spec type_and_wait(map()) :: map()
  def type_and_wait(ctx) do
    :ok = Troupe.send_input(ctx.session_id, ctx.scenario.prompt)
    await(ctx, "turn_ended")
    ctx
  end

  @doc "Wait for the root agent's next durable event of `type`, raising if none comes."
  @spec await(map(), String.t(), pos_integer()) :: Event.t()
  def await(%{session_id: sid}, type, timeout \\ @turn_timeout_ms) do
    receive do
      {:troupe_event, ^sid, %Event{type: ^type, agent: ["root"], ephemeral?: false} = event} ->
        event
    after
      timeout -> raise "no #{type} from the root agent within #{div(timeout, 1000)} s"
    end
  end

  # What the run left behind: every request with what its prompt was made of, and the
  # session's log.
  defp collect(ctx) do
    requests = Model.requests(ctx.model)

    calls =
      Enum.map(requests, fn {request, _task, usage} ->
        request
        |> Model.measure(ctx.workspace)
        |> Map.merge(%{
          summariser: request.tools == [],
          input_tokens: usage.input_tokens,
          output_tokens: usage.output_tokens
        })
      end)

    Map.merge(ctx, %{
      requests: requests,
      calls: calls,
      events: Troupe.events(ctx.session_id),
      outcome: Scenario.outcome(ctx.scenario, ctx.workspace)
    })
  end

  @doc """
  What one run did, in the report's shape (Decision 772): the fields a run against a real
  model fills as well, so the two are one format. The calls are every one the model
  answered, the summariser's included. A run here has no clock, since what it measures is
  the harness's shape and a time would make two runs differ, so its times are `nil`; nor
  a cost, since nothing priced the bench's model; nor retries, which a provider makes
  inside its own call and the log does not record.
  """
  @spec record(map()) :: map()
  def record(ctx) do
    events = ctx.events

    %{
      "model" => "fake/" <> ctx.config.model,
      "outcome" => ctx.outcome,
      "stop_reason" => stop_reason(events),
      "turns" => count(events, "user_input"),
      "model_calls" => length(ctx.calls),
      "input_tokens" => ctx.calls |> Enum.map(& &1.input_tokens) |> Enum.sum(),
      "cached_tokens" => 0,
      "output_tokens" => ctx.calls |> Enum.map(& &1.output_tokens) |> Enum.sum(),
      "cost_micros" => nil,
      "wall_ms" => nil,
      "retries" => nil,
      "compactions" => count(events, "compacted"),
      "approvals" => count(events, "approval_requested"),
      "tools" => tools(events),
      "calls" => Enum.map(ctx.calls, &call_record/1)
    }
  end

  defp call_record(call) do
    %{
      "summariser" => call.summariser,
      "prompt_bytes" => call.total,
      "system_bytes" => call.system,
      "tool_definition_bytes" => call.tools,
      "conversation_bytes" => call.conversation,
      "tool_result_bytes" => call.tool_results,
      "input_tokens" => call.input_tokens,
      "output_tokens" => call.output_tokens,
      "latency_ms" => nil,
      "first_token_ms" => nil
    }
  end

  defp count(events, type), do: Enum.count(events, &(&1.type == type))

  defp stop_reason(events) do
    events
    |> Enum.filter(&(&1.type == "llm_response" and &1.agent == ["root"]))
    |> List.last()
    |> case do
      nil -> nil
      event -> event.data["stop_reason"]
    end
  end

  # Per tool: how often it was called and how often it failed. Durations need a clock.
  defp tools(events) do
    events
    |> Enum.filter(&(&1.type == "tool_call_completed"))
    |> Enum.group_by(& &1.data["name"])
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {name, completed} ->
      %{
        "name" => name,
        "calls" => length(completed),
        "failures" => Enum.count(completed, &(&1.data["ok"] == false)),
        "ms" => nil
      }
    end)
  end

  defp with_env(env, fun) do
    previous = Map.new(env, fn {key, _value} -> {key, System.get_env(key)} end)
    Enum.each(env, fn {key, value} -> System.put_env(key, value) end)

    try do
      fun.()
    after
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end
  end
end
