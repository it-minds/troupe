defmodule Troupe.Loop do
  @moduledoc """
  A loop towards the session's goal, as data (issue #59, Decision 681).

  `/loop [n]` runs the root agent through up to `n` iterations towards the goal `/goal`
  set. What a loop is doing is a fold over its own durable events, all written under the
  root agent's path by `Troupe.Session.Loop`:

  | event | data |
  | --- | --- |
  | `loop_started` | `loop_id`, `max_iterations`, `max_failures`, `goal`, `command_id` |
  | `loop_iteration_started` | `loop_id`, `iteration`, `command_id` (the iteration's input) |
  | `loop_iteration_finished` | `loop_id`, `iteration`, `outcome`, `detail` |
  | `loop_stopped` | `loop_id`, `reason`, `iterations`, `detail`, `summary`, `command_id` |

  So a loop can be replayed and inspected from the log alone, and the process that runs
  one holds nothing a restart could lose: it folds these same events on its way up.

  The decisions between iterations are here as well, as functions from a loop to the
  events that would record them. The process writes what they return and folds what it
  wrote with `fold_event/2`, the function a replay uses, so a live loop and a replayed one
  cannot disagree about where they are:

      (none) --start--> running, 0 --iterate--> running, n in flight
      running, n in flight --finish(continue)--> iterate, or stop(max_iterations)
      running, n in flight --finish(failed)----> iterate, or stop(failures | max_iterations)
      running, n in flight --finish(complete)--> stop(goal_complete)
      running --stop(reason)--> stopped   (an iteration in flight finishes `stopped`)

  An iteration's `outcome` is `continue` (the turn ended and the goal is not met),
  `complete` (the agent called `goal_complete`), `failed` (the turn ended in an error:
  the model request failed, the agent ended short or crashed) or `stopped` (the loop
  stopped around it). A loop's `reason` is one of `reasons/0`.
  """

  alias Troupe.Protocol.Event

  @reasons ~w(goal_complete max_iterations failures budget requested cancelled goal_cleared
              interrupted agent_done)

  @enforce_keys [:id, :max_iterations, :max_failures]
  defstruct [
    :id,
    :max_iterations,
    :max_failures,
    :goal,
    :started_by,
    :started_at,
    # The command id of the input the iteration in flight was given, which is what the
    # root agent's `input_accepted` echoes; `nil` between iterations.
    :in_flight,
    :reason,
    :detail,
    :summary,
    status: :running,
    iteration: 0,
    # Failed iterations in a row: one that is not a failure starts the count again.
    failures: 0
  ]

  @type outcome :: :continue | :complete | :failed | :stopped
  @type reason ::
          :goal_complete
          | :max_iterations
          | :failures
          | :budget
          | :requested
          | :cancelled
          | :goal_cleared
          | :interrupted
          | :agent_done
  @type event :: {atom(), map()}
  @type t :: %__MODULE__{
          id: String.t(),
          max_iterations: pos_integer(),
          max_failures: pos_integer(),
          goal: String.t() | nil,
          started_by: String.t() | nil,
          started_at: String.t() | nil,
          in_flight: String.t() | nil,
          reason: String.t() | nil,
          detail: String.t() | nil,
          summary: String.t() | nil,
          status: :running | :stopped,
          iteration: non_neg_integer(),
          failures: non_neg_integer()
        }

  @doc "Every reason a loop stops for, as the log spells them."
  @spec reasons() :: [String.t()]
  def reasons, do: @reasons

  @doc "Whether the loop is still running."
  @spec running?(t() | nil) :: boolean()
  def running?(%__MODULE__{status: :running}), do: true
  def running?(_loop), do: false

  @doc """
  The id the next loop in a session gets: `loop-1`, `loop-2`, …, counted from the loops
  its log already has, so ids read in order and never repeat within a session.
  """
  @spec next_id([Event.t()]) :: String.t()
  def next_id(events) do
    "loop-#{Enum.count(events, &(&1.type == "loop_started")) + 1}"
  end

  @doc "The command id an iteration's input carries: the loop's id and the iteration."
  @spec input_id(String.t(), pos_integer()) :: String.t()
  def input_id(loop_id, iteration), do: "#{loop_id}.#{iteration}"

  # -- decisions --------------------------------------------------------------

  @doc """
  The event that starts a loop. `opts`: `:max_iterations`, `:max_failures` and `:goal`,
  all required, and `:command_id`, the protocol command that asked.
  """
  @spec start(String.t(), keyword()) :: [event()]
  def start(id, opts) do
    data =
      %{
        "loop_id" => id,
        "max_iterations" => Keyword.fetch!(opts, :max_iterations),
        "max_failures" => Keyword.fetch!(opts, :max_failures),
        "goal" => Keyword.fetch!(opts, :goal)
      }
      |> put_present("command_id", Keyword.get(opts, :command_id))

    [{:loop_started, data}]
  end

  @doc """
  What happens between iterations: the next one starts, or the loop stops because the
  cap is reached or the root agent will take no more input. `root_done` is the reason the
  root agent last ended with, `nil` while it is not done: a root that `finished` is woken
  by the next input, and one that ended any other way is not (Decision 635).
  """
  @spec next(t(), String.t() | nil) :: [event()]
  def next(%__MODULE__{status: :running} = loop, root_done) do
    cond do
      loop.iteration >= loop.max_iterations -> stop(loop, :max_iterations)
      root_done == "budget_exhausted" -> stop(loop, :budget)
      root_done not in [nil, "finished"] -> stop(loop, :agent_done, detail: root_done)
      true -> iterate(loop)
    end
  end

  def next(%__MODULE__{}, _root_done), do: []

  @doc "Start the next iteration."
  @spec iterate(t()) :: [event()]
  def iterate(%__MODULE__{status: :running, in_flight: nil} = loop) do
    n = loop.iteration + 1

    [
      {:loop_iteration_started,
       %{"loop_id" => loop.id, "iteration" => n, "command_id" => input_id(loop.id, n)}}
    ]
  end

  @doc """
  Close the iteration in flight with its outcome, and stop the loop when that outcome
  ends it: the goal is complete, or this is one failure too many. Whether another
  iteration follows is `next/2`'s question, asked once this has been written.

  `opts`: `:detail`, a sentence saying what went wrong; `:summary`, the evidence a
  `goal_complete` call gave.
  """
  @spec finish(t(), outcome(), keyword()) :: [event()]
  def finish(%__MODULE__{status: :running, in_flight: id} = loop, outcome, opts \\ [])
      when is_binary(id) do
    detail = Keyword.get(opts, :detail)
    finished = {:loop_iteration_finished, iteration_data(loop, outcome, detail)}

    cond do
      outcome == :complete ->
        [finished | stopped(loop, :goal_complete, summary: Keyword.get(opts, :summary))]

      outcome == :failed and loop.failures + 1 >= loop.max_failures ->
        [finished | stopped(loop, :failures, detail: detail)]

      true ->
        [finished]
    end
  end

  @doc """
  Stop the loop for `reason`. An iteration in flight is closed as `stopped` first, so
  every `loop_iteration_started` in a log has its `loop_iteration_finished`.

  `opts`: `:detail`, `:command_id` (the `session.loop.stop` that asked).
  """
  @spec stop(t(), reason(), keyword()) :: [event()]
  def stop(%__MODULE__{status: :running} = loop, reason, opts \\ []) do
    case loop.in_flight do
      nil -> stopped(loop, reason, opts)
      _id -> [{:loop_iteration_finished, iteration_data(loop, :stopped, nil)} | stopped(loop, reason, opts)]
    end
  end

  defp stopped(loop, reason, opts) when is_atom(reason) do
    data =
      %{"loop_id" => loop.id, "reason" => Atom.to_string(reason), "iterations" => loop.iteration}
      |> put_present("detail", Keyword.get(opts, :detail))
      |> put_present("summary", Keyword.get(opts, :summary))
      |> put_present("command_id", Keyword.get(opts, :command_id))

    [{:loop_stopped, data}]
  end

  defp iteration_data(loop, outcome, detail) do
    %{"loop_id" => loop.id, "iteration" => loop.iteration, "outcome" => Atom.to_string(outcome)}
    |> put_present("detail", detail)
  end

  defp put_present(data, _key, nil), do: data
  defp put_present(data, key, value), do: Map.put(data, key, value)

  # -- the fold ---------------------------------------------------------------

  @doc """
  The session's latest loop, folded from its events, or `nil` if it never had one. Only
  the root agent's events are read, because that is where a loop writes.
  """
  @spec fold([Event.t()]) :: t() | nil
  def fold(events) do
    root = Troupe.Session.root_path()

    events
    |> Enum.filter(&(&1.agent == root))
    |> Enum.reduce(nil, &fold_event(&2, &1))
  end

  @doc """
  One event folded into a loop. `loop_started` begins a new one; the rest apply only to
  the loop they name, and anything that is not a loop event leaves it as it was.
  """
  @spec fold_event(t() | nil, Event.t()) :: t() | nil
  def fold_event(_loop, %Event{type: "loop_started", data: data} = event) do
    %__MODULE__{
      id: data["loop_id"],
      max_iterations: data["max_iterations"],
      max_failures: data["max_failures"],
      goal: data["goal"],
      started_by: event.actor && event.actor.subject,
      started_at: event.ts
    }
  end

  def fold_event(%__MODULE__{id: id} = loop, %Event{type: "loop_" <> _, data: %{"loop_id" => id}} = event) do
    fold_own(loop, event.type, event.data)
  end

  def fold_event(loop, _event), do: loop

  defp fold_own(loop, "loop_iteration_started", data) do
    %{loop | iteration: data["iteration"], in_flight: data["command_id"]}
  end

  defp fold_own(loop, "loop_iteration_finished", data) do
    failures =
      case data["outcome"] do
        "failed" -> loop.failures + 1
        "stopped" -> loop.failures
        _continue_or_complete -> 0
      end

    %{loop | in_flight: nil, failures: failures}
  end

  defp fold_own(loop, "loop_stopped", data) do
    %{
      loop
      | status: :stopped,
        in_flight: nil,
        reason: data["reason"],
        detail: data["detail"],
        summary: data["summary"]
    }
  end

  defp fold_own(loop, _type, _data), do: loop

  @doc """
  The loop as `session.loop.get` answers it. `live?` is whether the session's tree is
  running: a loop the log says is running in a session that is not was interrupted, and
  is reported the way the log will record it when the session is next activated.
  """
  @spec to_json(t(), boolean()) :: map()
  def to_json(%__MODULE__{} = loop, live? \\ true) do
    {state, reason} =
      if running?(loop) and not live?,
        do: {"stopped", "interrupted"},
        else: {Atom.to_string(loop.status), loop.reason}

    %{
      "loop_id" => loop.id,
      "state" => state,
      "iteration" => loop.iteration,
      "max_iterations" => loop.max_iterations,
      "failures" => loop.failures,
      "reason" => reason,
      "detail" => loop.detail,
      "summary" => loop.summary,
      "goal" => loop.goal,
      "started_by" => loop.started_by,
      "started_at" => loop.started_at
    }
  end
end
