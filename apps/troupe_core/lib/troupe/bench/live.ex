defmodule Troupe.Bench.Live do
  @moduledoc """
  `troupe bench --live`: the live scenarios (`Troupe.Bench.LiveScenarios`) against the
  person's own provider and model (issue #390, Decision 773).

  `plan/1` says what a run will do and the most it can spend, before anything starts:
  the model, read with its provider settings from the person's own configuration; each
  run's limits; the model's price; and the cap, which is a run's limits at that price
  times the number of runs. The provider settings, the key among them, are handed to each
  run in memory and never written or printed.

  `run/2` then runs each scenario `repeat` times. A run is what the offline suite's is: its
  own workspace, config and state directories, and a session of the harness this VM
  carries, with every tool allowed so no turn waits on a person. Beside that it has the
  run's limits (model calls, tokens each way, a wall clock), its share of the cap, and a
  deadline of the runner's own; whichever ends the run, the session is stopped, and with
  it everything the run started. Each run is appended to the history
  (`Troupe.Bench.History`) as it ends, so a run cut short by Ctrl-C keeps what it did.

  What a run records is read as it happens: the session's events give each model call's
  latency (its `llm_request` to its `llm_response`) and time to first token (the first
  streamed delta), each tool call's time, and the call's usage and cost as the log has
  them; telemetry gives the provider's retries, which the log never sees.

  A bench is a suite of scenarios, `smoke` unless the plan names another or names the
  scenarios themselves (Decision 775). Beside each scenario's measures the report has a
  `summary` of every run: how many succeeded, with a 95% interval, since three runs of a
  model are not a rate; what they cost in all and per success; and their tokens.
  """

  alias Troupe.Bench.{History, LiveScenarios, Prefix, Runner, Scenario}
  alias Troupe.Config
  alias Troupe.LLM.Catalog
  alias Troupe.Protocol.Event
  alias Troupe.Session.Blobs

  defmodule Plan do
    @moduledoc """
    What a live bench will do (`Troupe.Bench.Live.plan/1`). `settings` carries the
    person's provider settings, their key among them, and is left out of `inspect/1`.
    """

    @derive {Inspect, except: [:settings]}
    defstruct [
      :model,
      :version,
      :repeat,
      :limits,
      :price,
      :run_cap_micros,
      :cap_micros,
      :history,
      :suite,
      :keep,
      scenarios: [],
      skipped: [],
      settings: []
    ]

    @type t :: %__MODULE__{}
  end

  # A run's limits: `scripts/live-check`'s, well above what any of the tasks needs and far
  # below the defaults (Decision 773).
  @limits [
    max_turns: 12,
    max_input_tokens: 200_000,
    max_output_tokens: 24_000,
    wall_clock_ms: 240_000
  ]

  # What a person's configuration says about where a model call goes, and nothing else:
  # the budgets, approvals, agents, skills and instruction files a run has are the bench's.
  # Beside it, issue #465's two experiments, so a bench can be run with either on
  # (`TROUPE_THINKING_BINDING`, `TROUPE_SYSTEM_PROMPT`) and say which it ran with
  # (Decision 815).
  @provider_settings [
    :provider,
    :small_model,
    :expensive_model,
    :base_url,
    :api_key,
    :auth,
    :providers,
    :windows,
    :prices,
    :catalog,
    :fake_script,
    :llm_timeout_ms,
    :thinking_binding,
    :system_prompt
  ]

  @doc """
  What a live bench of `opts` will do, or why it cannot.

  Options: `:repeat` (1), the runs of each scenario; `:model`, instead of the configured
  default, as `troupe` addresses one (`<provider>/<model>`, a bare id, or an alias);
  `:suite` (`"smoke"`), or `:only`, the names of the scenarios to run whatever suite they
  are in (`Troupe.Bench.LiveScenarios.select/2`); `:keep`, a directory to leave each
  run's workspace and session log in rather than remove them; `:limits`, over a run's
  own; and, for a test, `:scenarios` themselves, `:config`, the person's configuration,
  and `:history`, its file, `nil` for none. A scenario whose outcome is a command that is
  not on the PATH is left out, and `skipped` says why: nothing is spent on a run nobody
  can check.
  """
  @spec plan(keyword()) :: {:ok, Plan.t()} | {:error, String.t()}
  def plan(opts \\ []) do
    with {:ok, chosen} <- chosen(opts),
         {:ok, config} <- person(opts),
         model = Config.resolve_model(config, Keyword.get(opts, :model) || config.model),
         config = %{config | model: model},
         :ok <- reachable(config, model) do
      limits = Keyword.merge(@limits, Keyword.get(opts, :limits, []))
      repeat = Keyword.get(opts, :repeat, 1)
      {scenarios, skipped} = checkable(chosen)
      price = price(config, model)
      run_cap = price && run_cap(price.entry, limits)

      {:ok,
       %Plan{
         model: label(config, model),
         version: :troupe_core |> Application.spec(:vsn) |> to_string(),
         repeat: repeat,
         limits: limits,
         price: price,
         run_cap_micros: run_cap,
         cap_micros: run_cap && run_cap * repeat * length(scenarios),
         history: Keyword.get_lazy(opts, :history, fn -> History.path(config.state_dir) end),
         suite: suite_name(opts),
         keep: opts[:keep] && Path.expand(opts[:keep]),
         scenarios: scenarios,
         skipped: skipped,
         settings: settings(config, model)
       }}
    end
  end

  defp chosen(opts) do
    case Keyword.fetch(opts, :scenarios) do
      {:ok, scenarios} -> {:ok, scenarios}
      :error -> LiveScenarios.select(opts[:suite], opts[:only])
    end
  end

  # What the report calls the set that ran: the suite's name, or `only` for scenarios named
  # one by one.
  defp suite_name(opts) do
    cond do
      Keyword.has_key?(opts, :scenarios) -> nil
      match?([_ | _], opts[:only]) -> "only"
      true -> opts[:suite] || "smoke"
    end
  end

  defp person(opts) do
    case Keyword.fetch(opts, :config) do
      {:ok, %Config{} = config} ->
        {:ok, config}

      :error ->
        case Config.resolve(nil) do
          {:ok, config, _layers} -> {:ok, config}
          {:error, error} -> {:error, Exception.message(error)}
        end
    end
  end

  defp reachable(config, model) do
    case Config.key_problem(config) do
      nil ->
        :ok

      {:no_key, provider} ->
        {:error, "#{provider}, which #{model} is on, has no key: `troupe config` sets one up"}

      {:refused, why} ->
        {:error, why}
    end
  end

  # A scenario checked by a program this machine does not have would spend money on a run
  # whose outcome nobody can tell.
  defp checkable(scenarios) do
    {kept, missing} = Enum.split_with(scenarios, &(missing_program(&1) == nil))

    skipped =
      Enum.map(missing, fn scenario ->
        %{
          "name" => scenario.name,
          "why" =>
            "its outcome is checked with `#{missing_program(scenario)}`, which is not on the PATH"
        }
      end)

    {kept, skipped}
  end

  defp missing_program(%Scenario{outcome: {:command, [program | _args]}}) do
    if System.find_executable(program), do: nil, else: program
  end

  defp missing_program(_scenario), do: nil

  # Priced as the harness prices a call (Decision 689): the catalog, else `models.prices`,
  # under the name the person addressed the model by and the one that goes on the wire.
  defp price(config, model) do
    case Config.price(config, [model, Config.target(config, model).model]) do
      {%Catalog{} = entry, source} -> %{entry: entry, source: source}
      nil -> nil
    end
  end

  # The most one run can cost: its input at the dearer of the input and cache-write prices,
  # since the budget counts both, and its output. Cache reads are not in the budget, and
  # are held by the run's share of the cap instead.
  defp run_cap(%Catalog{} = entry, limits) do
    input = max(entry.input, entry.cache_write || entry.input)

    round(
      (limits[:max_input_tokens] * input + limits[:max_output_tokens] * entry.output) * 1_000_000
    )
  end

  defp label(config, model) do
    case Config.split_model(config, model) do
      {nil, bare} -> "#{config.provider}/#{bare}"
      {_provider, _bare} -> model
    end
  end

  defp settings(config, model) do
    @provider_settings
    |> Enum.map(&{&1, Map.fetch!(config, &1)})
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Kernel.++(model: model)
  end

  # -- what is said before anything starts --------------------------------------------

  @doc "The plan in words: what will run, against what, under what limits, at what cost at most."
  @spec describe(Plan.t()) :: String.t()
  def describe(%Plan{} = plan) do
    runs = length(plan.scenarios) * plan.repeat
    limits = plan.limits

    [
      "troupe bench --live: #{plural(length(plan.scenarios), "scenario")}, #{plural(plan.repeat, "run")} each, against #{plan.model}.",
      suite_line(plan),
      "Each run has a scratch directory and a session of its own, with every tool allowed, " <>
        "the shell among them, " <>
        "and may make #{limits[:max_turns]} model calls, send #{thousands(limits[:max_input_tokens])} tokens " <>
        "and receive #{thousands(limits[:max_output_tokens])}, in #{div(limits[:wall_clock_ms], 1000)} s.",
      cost(plan, runs),
      experiment_line(plan)
    ]
    |> Kernel.++(Enum.map(plan.skipped, &"#{&1["name"]} is left out: #{&1["why"]}."))
    |> Kernel.++(if plan.history, do: ["Each run is added to #{plan.history}."], else: [])
    |> Kernel.++(
      if plan.keep,
        do: ["Each run's workspace and session log are kept under #{plan.keep}."],
        else: []
    )
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  # Issue #465's experiments, said only when one is on (Decision 815).
  defp experiment_line(%Plan{} = plan) do
    case experiment(plan) do
      %{"thinking_binding" => "default", "system_prompt" => "per_turn"} ->
        nil

      %{"thinking_binding" => binding, "system_prompt" => system} ->
        "With issue #465's experiments: thinking_binding #{binding}, system_prompt #{system}."
    end
  end

  @doc """
  Issue #465's two settings a plan's runs have (Decision 815): `thinking_binding` and
  `system_prompt`, as the person's configuration or the environment set them.
  """
  @spec experiment(Plan.t()) :: map()
  def experiment(%Plan{settings: settings}) do
    %{
      "thinking_binding" => Keyword.get(settings, :thinking_binding, "default"),
      "system_prompt" => Keyword.get(settings, :system_prompt, "per_turn")
    }
  end

  defp suite_line(%Plan{suite: nil}), do: nil

  defp suite_line(%Plan{suite: "only"} = plan),
    do: "The scenarios asked for: #{Enum.map_join(plan.scenarios, ", ", & &1.name)}."

  defp suite_line(%Plan{} = plan),
    do: "The #{plan.suite} suite: #{Enum.map_join(plan.scenarios, ", ", & &1.name)}."

  defp cost(%Plan{price: nil} = plan, runs) do
    "Nothing prices #{plan.model} (the provider's catalog does not, nor does models.prices), " <>
      "so what it may spend is said in tokens: at most #{thousands(plan.limits[:max_input_tokens] * runs)} sent " <>
      "and #{thousands(plan.limits[:max_output_tokens] * runs)} received in all."
  end

  defp cost(%Plan{price: %{entry: entry}} = plan, _runs) do
    "At #{Catalog.describe_price(entry)} a million tokens, a run costs at most #{money(plan.run_cap_micros)}, " <>
      "so this costs at most #{money(plan.cap_micros)} in all."
  end

  @doc "What a person is asked before a live bench starts."
  @spec question(Plan.t()) :: String.t()
  def question(%Plan{cap_micros: nil} = plan),
    do: "Run it against #{plan.model}, with no price to hold it to? [y/N] "

  def question(%Plan{} = plan),
    do: "Spend up to #{money(plan.cap_micros)} on #{plan.model}? [y/N] "

  # -- running it ---------------------------------------------------------------------

  @doc """
  Run the plan and answer its report, schema 1 with `mode: "live"`.

  Options: `:progress`, a function given a line as each run ends.
  """
  @spec run(Plan.t(), keyword()) :: map()
  def run(%Plan{} = plan, opts \\ []) do
    progress = Keyword.get(opts, :progress, fn _line -> :ok end)
    now = DateTime.utc_now()
    started = DateTime.to_iso8601(now)

    # Kept runs go under a directory of this bench's own, so a second bench beside the
    # first never seeds its workspaces with what the first left.
    base =
      if plan.keep,
        do: Path.join(plan.keep, Calendar.strftime(now, "%Y%m%dT%H%M%SZ")),
        else:
          Path.join(System.tmp_dir!(), "troupe-bench-live-#{System.unique_integer([:positive])}")

    try do
      entries =
        Enum.map(plan.scenarios, fn scenario ->
          runs =
            Enum.map(1..plan.repeat, fn n ->
              run = run_one(scenario, n, plan, base)
              History.append(plan.history, history_line(plan, started, scenario, n, run))
              progress.(progress_line(scenario, n, plan, run))
              run
            end)

          entry(scenario, runs)
        end)

      %{
        "schema" => 1,
        "suite" => "troupe bench",
        "mode" => "live",
        "version" => plan.version,
        "model" => plan.model,
        "repeat" => plan.repeat,
        "live_suite" => plan.suite,
        "kept_in" => plan.keep && base,
        "cap_micros" => plan.cap_micros,
        "started_at" => started,
        "experiment" => experiment(plan),
        "skipped" => plan.skipped,
        "passed" => Enum.all?(entries, & &1["passed"]),
        "summary" => summary(Enum.flat_map(entries, & &1["runs"]), length(entries)),
        "scenarios" => entries
      }
    after
      unless plan.keep, do: File.rm_rf(base)
    end
  end

  defp history_line(plan, started, scenario, n, run) do
    Map.merge(run, %{
      "schema" => 1,
      "bench" => started,
      "version" => plan.version,
      "scenario" => scenario.name,
      "run" => n,
      "experiment" => experiment(plan)
    })
  end

  defp progress_line(scenario, n, plan, run) do
    how =
      if run["succeeded"],
        do: "succeeded",
        else: "FAILED" <> if(run["error"], do: " (#{run["error"]})", else: "")

    "#{scenario.name} #{n}/#{plan.repeat}: #{how}, #{run["model_calls"]} model calls, " <>
      "#{money(run["cost_micros"])}, #{seconds(run["wall_ms"])}"
  end

  # One run, in directories of its own, in a process of its own so that what the session
  # sent it goes with it.
  defp run_one(%Scenario{} = scenario, n, plan, base) do
    dir = Path.join(base, "#{scenario.name}-#{n}")
    work = Path.join(dir, "work")
    Enum.each(["work", "config", "state"], &File.mkdir_p!(Path.join(dir, &1)))
    Scenario.seed(scenario, work)

    Runner.with_env(Runner.isolation(dir), fn ->
      fn -> attempt(scenario, work, Path.join(dir, "state"), plan) end
      |> Task.async()
      |> Task.await(:infinity)
    end)
  end

  defp attempt(scenario, work, state_dir, plan) do
    measured(scenario, work, state_dir, plan)
  rescue
    error -> failed(plan, Exception.message(error))
  catch
    :exit, reason -> failed(plan, "exited: " <> inspect(reason))
  end

  defp measured(scenario, work, state_dir, plan) do
    {:ok, workspace} = Troupe.Workspace.new(work)
    root = workspace.root_real

    # The bench's settings over the person's provider: every tool allowed, so no turn waits
    # on a person; no brief, which a librarian would be started to write; a budget that
    # stops rather than asks; and the run's limits.
    overrides =
      plan.settings ++
        [
          state_dir: state_dir,
          auto_approve: true,
          memory: false,
          memory_auto_refresh: false,
          budget_asks: false
        ] ++ plan.limits ++ scenario.config

    handler = "troupe-bench-live-#{System.unique_integer([:positive])}"
    :ok = :telemetry.attach(handler, [:troupe, :llm, :retry], &__MODULE__.retried/4, self())

    try do
      {sid, ending, acc, wall, events} = in_session(scenario, root, overrides, plan)
      ctx = %{scenario: scenario, workspace: root, events: events, marks: %{}}
      ctx = Map.put(ctx, :outcome, Scenario.outcome(scenario, root))
      {_metrics, checks} = scenario.measure.(ctx)
      tool_calls = tool_calls(events, acc.tool_ms, &Blobs.resolve(sid, root, &1))
      record(plan, ctx, acc, wall, error(ending, events, plan), checks, tool_calls)
    after
      :telemetry.detach(handler)
    end
  end

  @doc false
  def retried(_event, _measurements, _metadata, runner), do: send(runner, :bench_retry)

  defp in_session(scenario, root, overrides, plan) do
    {:ok, session} = Troupe.start_session(workspace: root, config_overrides: overrides)
    sid = session.id
    Troupe.subscribe(sid)

    try do
      started = now()
      prompts = [scenario.prompt | scenario.follow_ups]
      deadline = started + deadline(plan.limits)
      {ending, acc} = turns(sid, prompts, deadline, plan.run_cap_micros, new_acc())
      {sid, ending, acc, now() - started, Troupe.events(sid)}
    after
      Troupe.unsubscribe(sid)
      Troupe.stop_session(sid)
    end
  end

  # Each prompt once the turn before it has ended by itself: a scenario of more than one
  # turn is how a run shows what changes between turns (issue #465, Decision 815). The
  # first turn that ends any other way ends the run, under the run's one deadline and cap.
  defp turns(sid, [prompt | rest], deadline, cap, acc) do
    :ok = Troupe.send_input(sid, prompt)

    case watch(sid, deadline, cap, acc) do
      {{:ended, %Event{type: "turn_ended", data: data}}, acc} = ending when rest != [] ->
        if data["reason"], do: ending, else: turns(sid, rest, deadline, cap, acc)

      ending ->
        ending
    end
  end

  # The harness checks its wall clock before each model call; a call that hangs is the
  # runner's to stop, a little after.
  defp deadline(limits), do: limits[:wall_clock_ms] + min(div(limits[:wall_clock_ms], 4), 30_000)

  defp now, do: System.monotonic_time(:millisecond)

  defp new_acc, do: %{pending: %{}, calls: %{}, tools_at: %{}, tool_ms: %{}, cost: 0, retries: 0}

  # Until the root agent's turn ends, the deadline passes, or the run's cost reaches its
  # share of the cap.
  defp watch(sid, deadline, cap, acc) do
    receive do
      {:troupe_event, ^sid, %Event{} = event} ->
        acc = note(acc, event, now())

        cond do
          ended?(event) -> {{:ended, event}, acc}
          is_integer(cap) and acc.cost >= cap -> {:over_cap, acc}
          true -> watch(sid, deadline, cap, acc)
        end

      :bench_retry ->
        watch(sid, deadline, cap, %{acc | retries: acc.retries + 1})
    after
      max(deadline - now(), 0) -> {:timeout, acc}
    end
  end

  defp ended?(%Event{agent: ["root"], ephemeral?: false, type: type}),
    do: type in ["turn_ended", "agent_done"]

  defp ended?(_event), do: false

  # Times are taken as each event arrives: an agent's calls are one after another, so its
  # request, first delta and response pair up by the agent alone. The request says what
  # its prompt was made of (Decision 769).
  defp note(acc, %Event{type: "llm_request", agent: agent, ephemeral?: false, data: data}, at),
    do: put_in(acc, [:pending, agent], %{at: at, first: nil, bytes: data["prompt_bytes"]})

  defp note(acc, %Event{type: "llm_delta", agent: agent}, at) do
    case acc.pending do
      %{^agent => %{first: nil} = call} -> put_in(acc, [:pending, agent], %{call | first: at})
      _other -> acc
    end
  end

  defp note(acc, %Event{type: "llm_response", agent: agent, seq: seq, data: data}, at) do
    {call, pending} = Map.pop(acc.pending, agent)

    timing =
      if call,
        do: %{latency: at - call.at, first: call.first && call.first - call.at, bytes: call.bytes},
        else: %{latency: nil, first: nil, bytes: nil}

    spent(%{acc | pending: pending, calls: Map.put(acc.calls, seq, timing)}, data)
  end

  # The call that writes a compaction's summary is on the `compacted` that takes its answer
  # (Decision 769), and costs what any other does.
  defp note(acc, %Event{type: "compacted", data: data}, _at), do: spent(acc, data)

  # A call the agent gave up on costs what it had reported (Decision 788).
  defp note(acc, %Event{type: "llm_error", agent: agent, data: data}, _at),
    do: spent(%{acc | pending: Map.delete(acc.pending, agent)}, data["stopped"] || %{})

  # A tool call by its agent as well as its id: a provider that gives no ids gets
  # `call_0`, `call_1`, ... from the harness, in every agent alike.
  defp note(acc, %Event{type: "tool_call_started", agent: agent, data: %{"call_id" => id}}, at),
    do: put_in(acc, [:tools_at, {agent, id}], at)

  defp note(acc, %Event{type: "tool_call_completed", agent: agent, data: %{"call_id" => id}}, at) do
    case Map.fetch(acc.tools_at, {agent, id}) do
      {:ok, started} -> put_in(acc, [:tool_ms, {agent, id}], at - started)
      :error -> acc
    end
  end

  defp note(acc, _event, _at), do: acc

  defp spent(acc, data) do
    case get_in(data, ["gateway", "cost_micros"]) do
      cost when is_integer(cost) -> %{acc | cost: acc.cost + cost}
      _unpriced -> acc
    end
  end

  # Why the run did not end by itself, or `nil` when it did.
  defp error({:ended, %Event{type: "turn_ended", data: data}}, _events, _plan) do
    if reason = data["reason"], do: "the harness ended the turn (#{reason})"
  end

  # A budget that stops rather than asks is checked again when a turn ends, so a turn that
  # answered on its last allowed call ends the agent as `budget_exhausted` too (issue
  # #405): the root's last reply says which it was.
  defp error(
         {:ended, %Event{type: "agent_done", data: %{"reason" => "budget_exhausted"} = data}},
         events,
         _plan
       ) do
    unless stop_reason(events) == "end_turn",
      do: "the run's budget stopped it (#{data["limit"]})"
  end

  defp error({:ended, %Event{type: "agent_done", data: data}}, _events, _plan),
    do: "the agent stopped (#{data["reason"]})"

  defp error(:timeout, _events, plan),
    do: "it had not ended #{seconds(deadline(plan.limits))} after it started, and was stopped"

  defp error(:over_cap, _events, plan),
    do: "it reached its share of the cap, #{money(plan.run_cap_micros)}, and was stopped"

  # -- what a run recorded -------------------------------------------------------------

  # Schema 1's run (Decision 772), filled: what the log counts, what the runner timed, and
  # what a live run adds, why it did not end by itself, its checks and whether it
  # succeeded: no error, the outcome held, every check held.
  defp record(plan, ctx, acc, wall, error, checks, tool_calls) do
    events = ctx.events
    calls = calls(events, acc.calls)
    costs = numbers(calls, "cost_micros")

    checks =
      Enum.map(checks, fn {name, label, passed} ->
        %{"name" => name, "label" => label, "passed" => passed}
      end)

    %{
      "model" => plan.model,
      "outcome" => ctx.outcome,
      "stop_reason" => stop_reason(events),
      "turns" => count(events, "user_input"),
      "model_calls" => length(calls),
      "input_tokens" => sum(calls, "input_tokens"),
      "cached_tokens" => sum(calls, "cached_tokens"),
      "output_tokens" => sum(calls, "output_tokens"),
      "cost_micros" => if(costs == [], do: nil, else: Enum.sum(costs)),
      "wall_ms" => wall,
      "retries" => acc.retries,
      "compactions" => count(events, "compacted"),
      "approvals" => count(events, "approval_requested"),
      "tools" => tools(events, acc.tool_ms),
      "tool_calls" => tool_calls,
      "largest_tool_result_bytes" => largest(tool_calls),
      "calls" => calls,
      # How often the prompt changed in front of what the run had sent, and what became
      # of the thinking handed back (issue #465, Decision 815).
      "prefix" => Prefix.count(events),
      "error" => error,
      "checks" => checks,
      "succeeded" => error == nil and ctx.outcome != false and Enum.all?(checks, & &1["passed"])
    }
  end

  defp largest(tool_calls),
    do: tool_calls |> Enum.map(& &1["result_bytes"]) |> Enum.max(fn -> 0 end)

  # A run that never got going: nothing counted, and why.
  defp failed(plan, error) do
    %{
      "model" => plan.model,
      "outcome" => nil,
      "stop_reason" => nil,
      "turns" => 0,
      "model_calls" => 0,
      "input_tokens" => 0,
      "cached_tokens" => 0,
      "output_tokens" => 0,
      "cost_micros" => nil,
      "wall_ms" => nil,
      "retries" => 0,
      "compactions" => 0,
      "approvals" => 0,
      "tools" => [],
      "tool_calls" => [],
      "largest_tool_result_bytes" => 0,
      "calls" => [],
      "prefix" => Prefix.zero(),
      "error" => error,
      "checks" => [],
      "succeeded" => false
    }
  end

  @doc """
  Every model call a run's events record, in the order they were answered, with the times
  `timings` holds for each, by its `llm_response`'s seq: an agent's replies, and a
  compaction's summary, whose call the `compacted` that takes its answer carries
  (Decision 769).
  """
  @spec calls([Event.t()], %{pos_integer() => map()}) :: [map()]
  def calls(events, timings) do
    events
    |> Enum.filter(&model_call?/1)
    |> Enum.map(&call(&1, timings))
  end

  defp model_call?(%Event{type: "llm_response"}), do: true
  defp model_call?(%Event{type: "compacted", data: %{"usage" => usage}}), do: is_map(usage)
  defp model_call?(_event), do: false

  # Each model call as the log has it, with the times the runner took and what its prompt
  # was made of, as `llm_request.prompt_bytes` (or the `compacted`) says (Decision 769): the
  # measure the offline suite takes of a request. A summary's call has no request event,
  # so no times.
  defp call(%Event{} = event, timings) do
    usage = event.data["usage"] || %{}
    summariser = event.type == "compacted"
    timing = Map.get(timings, event.seq, %{latency: nil, first: nil, bytes: nil})
    bytes = if(summariser, do: event.data["prompt_bytes"], else: timing.bytes) || %{}

    %{
      "agent" => Enum.join(event.agent || [], "/"),
      "summariser" => summariser,
      "prompt_bytes" => bytes["total"],
      "system_bytes" => bytes["system"],
      "tool_definition_bytes" => bytes["tools"],
      "conversation_bytes" => bytes["conversation"],
      "tool_result_bytes" => bytes["tool_results"],
      "input_tokens" => (usage["input_tokens"] || 0) + (usage["cache_write"] || 0),
      "cached_tokens" => usage["cache_read"] || 0,
      "output_tokens" => usage["output_tokens"] || 0,
      "cost_micros" => get_in(event.data, ["gateway", "cost_micros"]),
      "latency_ms" => timing.latency,
      "first_token_ms" => timing.first
    }
  end

  defp stop_reason(events) do
    events
    |> Enum.filter(&(&1.type == "llm_response" and &1.agent == ["root"]))
    |> List.last()
    |> case do
      nil -> nil
      event -> event.data["stop_reason"]
    end
  end

  # Per tool: how often it was called, how often it failed, and the time its calls took
  # together.
  defp tools(events, tool_ms) do
    events
    |> Enum.filter(&(&1.type == "tool_call_completed"))
    |> Enum.group_by(& &1.data["name"])
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {name, completed} ->
      %{
        "name" => name,
        "calls" => length(completed),
        "failures" => Enum.count(completed, &(&1.data["ok"] == false)),
        "ms" =>
          completed
          |> Enum.map(&Map.get(tool_ms, {&1.agent, &1.data["call_id"]}))
          |> Enum.filter(&is_integer/1)
          |> Enum.sum()
      }
    end)
  end

  @doc """
  Every tool call of a run, in the order each ended (issue #406): its agent, the tool, how
  long it took, whether it succeeded, the bytes of its result as the model was given it,
  and whether that result says part of it was left out (cut at `tool_output_limit`, or a
  read that stopped short). Never its input or its output. `resolve` turns a result the
  log keeps as a blob back into its text, which is how a large one is measured.
  """
  @spec tool_calls([Event.t()], map(), (term() -> String.t())) :: [map()]
  def tool_calls(events, tool_ms, resolve) do
    for %Event{type: "tool_call_completed", agent: agent, data: data} <- events do
      text = result_text(data["content"], resolve)

      %{
        "agent" => Enum.join(agent || [], "/"),
        "name" => data["name"],
        "ok" => data["ok"] != false,
        "ms" => Map.get(tool_ms, {agent, data["call_id"]}),
        "result_bytes" => byte_size(text),
        "cut" => cut?(text)
      }
    end
  end

  defp result_text(content, _resolve) when is_binary(content), do: content

  defp result_text(%{"blob" => _} = reference, resolve) do
    resolve.(reference)
  rescue
    _unreadable -> reference["preview"] || ""
  end

  defp result_text(nil, _resolve), do: ""
  defp result_text(other, _resolve), do: Jason.encode!(other)

  # The markers `Troupe.Tools.Output`, `read_output` and `read_file` put in a result that
  # is not the whole of what was asked for.
  @cut ~r/\[truncated: \d+ |\[full output kept\. Call read_output|lines \d+–\d+ of \d+ omitted\.|\A\(lines \d+-\d+ of \d+\)/u

  defp cut?(text), do: Regex.match?(@cut, text)

  defp count(events, type), do: Enum.count(events, &(&1.type == type))
  defp sum(calls, key), do: calls |> Enum.map(&(&1[key] || 0)) |> Enum.sum()

  # -- a scenario's runs together ------------------------------------------------------

  # The report's entry: the offline one's fields, with the measures taken over the runs
  # rather than held to budgets (a model's variance is not a regression), the outcome and
  # each check held only when every run held it, and every run's own record.
  defp entry(%Scenario{} = scenario, runs) do
    errors =
      runs
      |> Enum.with_index(1)
      |> Enum.filter(fn {run, _n} -> run["error"] end)
      |> Enum.map(fn {run, n} -> "run #{n}: #{run["error"]}" end)

    outcome =
      if scenario.outcome do
        %{
          "what" => Scenario.describe_outcome(scenario),
          "held" => Enum.count(runs, &(&1["outcome"] == true)),
          "passed" => Enum.all?(runs, &(&1["outcome"] == true))
        }
      end

    %{
      "name" => scenario.name,
      "title" => scenario.title,
      "error" => if(errors == [], do: nil, else: Enum.join(errors, "; ")),
      "outcome" => outcome,
      "runs" => runs,
      "metrics" => Enum.map(metrics(runs), &metric/1),
      "checks" => checks(runs),
      "passed" => Enum.all?(runs, & &1["succeeded"])
    }
  end

  defp metric({name, label, unit, value}) do
    %{
      "name" => name,
      "label" => label,
      "unit" => unit,
      "value" => value,
      "budget" => nil,
      "passed" => true
    }
  end

  @doc """
  What a scenario's runs come to, as `{name, label, unit, value}`: the success rate and
  its 95% interval (`wilson/2`), the median and worst cost and the cost per success, the
  medians of the wall clock, a model call's latency and time to first token, the model
  calls and the tokens each way, and the median of each run's largest tool result. A cost
  is in dollars; a measure nothing recorded is `nil`. The report's metrics, and what
  `--compare` compares.
  """
  @spec metrics([map()]) :: [{String.t(), String.t(), String.t(), number() | nil}]
  def metrics(runs) do
    calls = Enum.flat_map(runs, &(&1["calls"] || []))
    costs = numbers(runs, "cost_micros")
    succeeded = Enum.count(runs, & &1["succeeded"])
    {low, high} = wilson(succeeded, length(runs))

    [
      {"success_rate", "runs that succeeded", "share",
       Float.round(succeeded / max(length(runs), 1), 3)},
      {"success_low", "runs that succeeded, 95% interval from", "share", low},
      {"success_high", "runs that succeeded, 95% interval to", "share", high},
      {"median_cost", "median cost", "$", dollars(median(costs))},
      {"worst_cost", "worst cost", "$", dollars(Enum.max(costs, fn -> nil end))},
      {"cost_per_success", "cost per success", "$", dollars(per_success(costs, succeeded))},
      {"median_wall_ms", "median wall clock", "ms", median(numbers(runs, "wall_ms"))},
      {"median_call_ms", "median model call", "ms", median(numbers(calls, "latency_ms"))},
      {"median_first_token_ms", "median time to first token", "ms",
       median(numbers(calls, "first_token_ms"))},
      {"median_model_calls", "median model calls", "calls", median(numbers(runs, "model_calls"))},
      {"median_input_tokens", "median input tokens", "tokens",
       median(numbers(runs, "input_tokens"))},
      {"median_cached_tokens", "median cached input tokens", "tokens",
       median(numbers(runs, "cached_tokens"))},
      {"median_output_tokens", "median output tokens", "tokens",
       median(numbers(runs, "output_tokens"))},
      {"median_largest_tool_result", "median largest tool result", "bytes",
       median(numbers(runs, "largest_tool_result_bytes"))}
    ]
  end

  @doc """
  The 95% Wilson interval of `successes` in `runs`, rounded to three places: where the
  success rate of the model on this task probably lies. Three runs that all succeeded put
  it only above 0.43; thirty, above 0.88. `{0.0, 1.0}` for no runs.
  """
  @spec wilson(non_neg_integer(), non_neg_integer()) :: {float(), float()}
  def wilson(_successes, 0), do: {0.0, 1.0}

  def wilson(successes, runs) do
    z = 1.96
    p = successes / runs
    denominator = 1 + z * z / runs
    centre = (p + z * z / (2 * runs)) / denominator
    half = z * :math.sqrt(p * (1 - p) / runs + z * z / (4 * runs * runs)) / denominator
    {Float.round(max(centre - half, 0.0), 3), Float.round(min(centre + half, 1.0), 3)}
  end

  # What the runs cost in all, over the runs that succeeded: the price of getting the work
  # done once, failures included, which is how two models compare (issue #390).
  defp per_success([], _succeeded), do: nil
  defp per_success(_costs, 0), do: nil
  defp per_success(costs, succeeded), do: round(Enum.sum(costs) / succeeded)

  @doc """
  Every run of a bench together, for the report's `summary`: how many there were and
  succeeded, with the interval; what they cost in all, per run and per success; their
  tokens, model calls and wall clock in all; and the median run's wall clock. Costs are in
  micro-dollars, `nil` when nothing was priced.
  """
  @spec summary([map()], non_neg_integer()) :: map()
  def summary(runs, scenarios) do
    succeeded = Enum.count(runs, & &1["succeeded"])
    costs = numbers(runs, "cost_micros")
    {low, high} = wilson(succeeded, length(runs))
    tokens = Enum.sum(Enum.map(~w(input_tokens cached_tokens output_tokens), &sum(runs, &1)))

    %{
      "scenarios" => scenarios,
      "runs" => length(runs),
      "succeeded" => succeeded,
      "success_rate" => Float.round(succeeded / max(length(runs), 1), 3),
      "success_low" => low,
      "success_high" => high,
      "cost_micros" => if(costs == [], do: nil, else: Enum.sum(costs)),
      "cost_per_run_micros" => if(costs == [], do: nil, else: round(Enum.sum(costs) / length(runs))),
      "cost_per_success_micros" => per_success(costs, succeeded),
      "model_calls" => sum(runs, "model_calls"),
      "input_tokens" => sum(runs, "input_tokens"),
      "cached_tokens" => sum(runs, "cached_tokens"),
      "output_tokens" => sum(runs, "output_tokens"),
      "tokens_per_success" => if(succeeded == 0, do: nil, else: round(tokens / succeeded)),
      "wall_ms" => runs |> numbers("wall_ms") |> Enum.sum(),
      "median_wall_ms" => median(numbers(runs, "wall_ms")),
      "prefix" => Enum.reduce(runs, Prefix.zero(), &Prefix.add(&2, &1["prefix"] || Prefix.zero()))
    }
  end

  @doc """
  What `--compare` sets beside each other for a bench's runs together, over the scenarios
  both benches ran: measures that hold whatever the number of runs, so a bench of three
  runs a scenario compares with one of one.
  """
  @spec overall([map()]) :: [{String.t(), String.t(), String.t(), number() | nil}]
  def overall(runs) do
    s = summary(runs, 0)

    [
      {"success_rate", "runs that succeeded", "share", s["success_rate"]},
      {"cost_per_success", "cost per success", "$", dollars(s["cost_per_success_micros"])},
      {"cost_per_run", "cost per run", "$", dollars(s["cost_per_run_micros"])},
      {"median_wall_ms", "median run's wall clock", "ms", s["median_wall_ms"]},
      {"tokens_per_success", "tokens per success", "tokens", s["tokens_per_success"]}
    ]
  end

  defp numbers(maps, key), do: maps |> Enum.map(& &1[key]) |> Enum.filter(&is_integer/1)

  defp median([]), do: nil

  defp median(values) do
    sorted = Enum.sort(values)
    half = div(length(sorted), 2)

    if rem(length(sorted), 2) == 1,
      do: Enum.at(sorted, half),
      else: round((Enum.at(sorted, half - 1) + Enum.at(sorted, half)) / 2)
  end

  defp dollars(nil), do: nil
  defp dollars(micros), do: Float.round(micros / 1_000_000, 6)

  # A check holds when it held in every run; its label says in how many it did. A run that
  # never got going has none, and counts as one where none held.
  defp checks(runs) do
    runs
    |> Enum.flat_map(& &1["checks"])
    |> Enum.uniq_by(& &1["name"])
    |> Enum.map(fn %{"name" => name, "label" => label} ->
      held =
        Enum.count(runs, fn run ->
          Enum.any?(run["checks"], &(&1["name"] == name and &1["passed"]))
        end)

      %{
        "name" => name,
        "label" => "#{label} (#{held} of #{length(runs)})",
        "passed" => held == length(runs)
      }
    end)
  end

  # -- words ---------------------------------------------------------------------------

  @doc false
  @spec money(non_neg_integer() | nil) :: String.t()
  def money(nil), do: "no price"

  def money(micros) when micros >= 10_000,
    do: "$" <> :erlang.float_to_binary(micros / 1_000_000, decimals: 2)

  def money(micros), do: "$" <> :erlang.float_to_binary(micros / 1_000_000, decimals: 4)

  defp seconds(nil), do: "no time"
  defp seconds(ms), do: "#{Float.round(ms / 1000, 1)} s"

  defp plural(1, noun), do: "1 #{noun}"
  defp plural(n, noun), do: "#{n} #{noun}s"

  defp thousands(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end
end
