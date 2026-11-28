defmodule Troupe.Session.Proposals do
  @moduledoc """
  What the harness offers a session's owner (#1208): `proposal_made`, written when the root
  comes to rest, and `proposal_answered`, written once, at the first answer.

  A proposal is not a question. Nothing waits for it: the agent is at rest when it is made,
  it is in no `pending_*` and in no "Waiting for you", and a turn goes on while it is open.
  Only the session's owner answers it, which the gateway and the plane check: `later` and
  `never` here (`answer/4`), a yes on the plane, which does what the proposal drafted and
  tells the pod (`decided/3`). The first answer wins; a second is refused, saying so.

  A projection like `Session.Checkpoints`, after it in the tree: it subscribes, folds the
  log (`Proposals.TriggerRule` for the one kind there is), and at the root's rest, never
  during a turn, asks the host (`Troupe.Proposals`) whether to propose what the rule
  drafted, which on a pod is the plane, holding the team's switch, the owner's `never`s and
  what reruns already. Once per session per kind. Where the host installed nothing, as on
  a person's machine, it does not start: nothing there schedules.

  A crash here restarts nothing else, and a fold that raises makes no proposal from then on
  in this tree.
  """

  use GenServer

  alias Troupe.Events
  alias Troupe.Protocol.Event
  alias Troupe.Session.{Checkpoint, Log, Sensitive}
  alias Troupe.Session.Proposals.TriggerRule

  require Logger

  @options ~w(accepted later never)

  defstruct session_id: nil,
            rule: nil,
            last_seq: 0,
            n: 0,
            made: MapSet.new(),
            checked: MapSet.new(),
            open: %{},
            answered: %{},
            reruns: []

  @doc "The answers a proposal offers."
  @spec options() :: [String.t()]
  def options, do: @options

  @spec start_link(keyword()) :: GenServer.on_start() | :ignore
  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)

    if Troupe.Proposals.proposes?(),
      do: GenServer.start_link(__MODULE__, opts, name: Troupe.Registry.proposals(session_id)),
      else: :ignore
  end

  @doc """
  The owner's `later` or `never` to an open proposal: `proposal_answered` with `actor`. A
  `never` is kept by the host first, so a refusal there leaves the proposal open and says
  why. A yes is not answered here: it is the plane's, which tells the pod (`decided/3`).
  """
  @spec answer(String.t(), String.t(), String.t(), map() | nil) :: :ok | {:error, String.t()}
  def answer(session_id, id, decision, actor \\ nil) do
    GenServer.call(Troupe.Registry.proposals(session_id), {:answer, id, decision, actor}, 30_000)
  catch
    :exit, _ -> {:error, "this session makes no proposals"}
  end

  @doc """
  What the plane did with the owner's yes: `proposal_answered` with `decision: accepted`,
  the fields they changed (`edited`) and what was made (`result`), once. The same yes heard
  twice writes nothing more.
  """
  @spec decided(String.t(), String.t(), map()) :: :ok | {:error, String.t()}
  def decided(session_id, id, %{} = data) do
    GenServer.call(Troupe.Registry.proposals(session_id), {:decided, id, data}, 15_000)
  catch
    :exit, _ -> {:error, "this session makes no proposals"}
  end

  @doc "The open proposals, each as `proposal_made` carries it."
  @spec open(String.t()) :: [map()]
  def open(session_id) do
    GenServer.call(Troupe.Registry.proposals(session_id), :open)
  catch
    :exit, _ -> []
  end

  @doc """
  The triggers a yes in this session made, each `%{"name", "schedule", "title"}`, for the
  root's next turn to be told, so it does not offer in prose what already reruns.
  """
  @spec reruns(String.t()) :: [map()]
  def reruns(session_id) do
    GenServer.call(Troupe.Registry.proposals(session_id), :reruns, 1_000)
  catch
    :exit, _ -> []
  end

  # -- server -------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    Process.set_label("troupe proposals #{session_id}")
    Events.subscribe(session_id, :internal)

    state = %__MODULE__{session_id: session_id, rule: TriggerRule.new()}

    # A rest read back from the log ended a turn this projection was there for, or not: the
    # root's first turn on a pod can begin before the tree reaches this child and end before
    # it has read the log, which then holds the rest and nothing after it. That last rest, the
    # root still resting, is owed a look as the live one would have had (`:owed`); any
    # earlier one ended a turn the root has worked past.
    {state, owed} =
      Enum.reduce(Log.replay_from(session_id, 0), {state, nil}, fn event, {state, owed} ->
        state = step(state, event)

        cond do
          is_nil(state.rule) -> {state, nil}
          Checkpoint.rest?(event) -> {%{state | rule: TriggerRule.rested(state.rule)}, state.rule}
          works?(event) -> {state, nil}
          true -> {state, owed}
        end
      end)

    {:ok, state, {:continue, {:owed, owed}}}
  end

  @impl GenServer
  def handle_continue({:owed, nil}, state), do: {:noreply, state}
  def handle_continue({:owed, rule}, state), do: {:noreply, rest(%{state | rule: rule})}

  @impl GenServer
  def handle_call(:open, _from, state), do: {:reply, Map.values(state.open), state}
  def handle_call(:reruns, _from, state), do: {:reply, state.reruns, state}

  def handle_call({:answer, id, decision, actor}, _from, state)
      when decision in ["later", "never"] do
    with {:ok, proposal} <- closed(state, id),
         :ok <- keep_never(state.session_id, proposal, decision) do
      {:reply, :ok, write_answer(state, id, %{"id" => id, "decision" => decision}, actor)}
    else
      {:error, _reason} = refused -> {:reply, refused, state}
    end
  end

  def handle_call({:answer, _id, "accepted", _actor}, _from, state),
    do:
      {:reply, {:error, "a yes is the plane's: session.proposal.accept makes what it drafted"},
       state}

  def handle_call({:answer, _id, _decision, _actor}, _from, state),
    do: {:reply, {:error, "the answer is later or never"}, state}

  def handle_call({:decided, id, data}, _from, state) do
    case {state.open[id], state.answered[id]} do
      {nil, "accepted"} ->
        {:reply, :ok, state}

      {nil, nil} ->
        {:reply, {:error, "there is no proposal #{id} in this session"}, state}

      {nil, decision} ->
        {:reply, {:error, "the proposal #{id} was already answered: #{decision}"}, state}

      {_open, nil} ->
        answer =
          %{"id" => id, "decision" => "accepted"}
          |> put_present("edited", data["edited"])
          |> put_present("result", data["result"])
          |> put_present("by_name", data["by_name"])

        {:reply, :ok, write_answer(state, id, answer, data["actor"])}
    end
  end

  @impl GenServer
  def handle_info(
        {:troupe_event, _session_id, %Event{ephemeral?: false, seq: seq} = event},
        state
      )
      when is_integer(seq) do
    if seq <= state.last_seq do
      {:noreply, state}
    else
      event = normal(event)
      state = step(state, event)
      {:noreply, if(Checkpoint.rest?(event), do: rest(state), else: state)}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  # -- the fold -----------------------------------------------------------------

  defp step(%{rule: nil} = state, %Event{seq: seq}),
    do: %{state | last_seq: max(state.last_seq, seq || 0)}

  defp step(state, %Event{} = event) do
    state = %{
      state
      | rule: TriggerRule.fold(state.rule, event),
        last_seq: max(state.last_seq, event.seq || 0)
    }

    own(state, event)
  rescue
    error ->
      Logger.warning(
        "troupe: #{state.session_id} makes no proposals: #{Exception.message(error)} at seq #{event.seq}"
      )

      %{state | rule: nil, last_seq: max(state.last_seq, event.seq || 0)}
  end

  # Each is folded once, whether it is heard from the log or from the write that made it.
  defp own(state, %Event{type: "proposal_made", data: %{"id" => id}})
       when is_map_key(state.open, id) or is_map_key(state.answered, id),
       do: state

  defp own(state, %Event{type: "proposal_made", data: data}) do
    %{
      state
      | n: state.n + 1,
        made: MapSet.put(state.made, data["kind"]),
        checked: MapSet.put(state.checked, data["key"]),
        open: Map.put(state.open, data["id"], data)
    }
  end

  defp own(state, %Event{type: "proposal_answered", data: %{"id" => id}})
       when is_map_key(state.answered, id),
       do: state

  defp own(state, %Event{type: "proposal_answered", data: %{"id" => id} = data}) do
    proposal = state.open[id]

    reruns =
      case {data["decision"], proposal} do
        {"accepted", %{"kind" => "trigger", "draft" => draft}} ->
          name = get_in(data, ["result", "name"]) || draft["name"]

          state.reruns ++
            [
              %{
                "name" => name,
                "schedule" => draft["schedule"],
                "title" => get_in(draft, ["artifact", "title"])
              }
            ]

        _ ->
          state.reruns
      end

    %{
      state
      | open: Map.delete(state.open, id),
        answered: Map.put(state.answered, id, data["decision"]),
        reruns: reruns
    }
  end

  defp own(state, _event), do: state

  # The root at work again after a rest: its turn is past being proposed about.
  @works ~w(input_accepted user_input agent_woken llm_request tool_call_started compacted)
  defp works?(%Event{agent: ["root"], type: type}), do: type in @works
  defp works?(_event), do: false

  # -- at rest ------------------------------------------------------------------

  defp rest(%{rule: nil} = state), do: state

  defp rest(state) do
    draft = TriggerRule.draft(state.rule)
    state = %{state | rule: TriggerRule.rested(state.rule)}

    cond do
      is_nil(draft) -> state
      # A sensitive session proposes nothing: a trigger made from it would rerun what read
      # the data, and publish where it may not.
      Sensitive.mark_of(state.session_id) -> state
      MapSet.member?(state.made, draft["kind"]) -> state
      MapSet.member?(state.checked, draft["key"]) -> state
      true -> propose(%{state | checked: MapSet.put(state.checked, draft["key"])}, draft)
    end
  end

  defp propose(state, draft) do
    case Troupe.Proposals.check(state.session_id, draft) do
      {:ok, %{"propose" => true} = answer} ->
        data =
          draft
          |> Map.put("id", "proposal-#{state.n + 1}")
          |> Map.put("options", options_for(answer["mode"]))
          |> Map.put("mode", answer["mode"] || "direct")
          |> Map.update!("draft", &Map.merge(&1, answer["draft"] || %{}))
          |> put_present("reason", answer["reason"])

        {:ok, _seq} = Log.append(state.session_id, ["root"], :proposal_made, data)
        own(state, %Event{type: "proposal_made", data: normal_data(data)})

      {:ok, _not_now} ->
        state

      {:error, reason} ->
        Logger.info("troupe: #{state.session_id} proposes nothing: #{inspect(reason)}")
        state
    end
  catch
    :exit, reason ->
      Logger.warning("troupe: #{state.session_id} could not make a proposal: #{inspect(reason)}")
      state
  end

  # A proposal that cannot be carried out here is still said, with why, and only waved off.
  defp options_for("unavailable"), do: ["later", "never"]
  defp options_for(_mode), do: @options

  defp closed(state, id) do
    case {state.open[id], state.answered[id]} do
      {%{} = proposal, _} -> {:ok, proposal}
      {nil, nil} -> {:error, "there is no proposal #{id} in this session"}
      {nil, decision} -> {:error, "the proposal #{id} was already answered: #{decision}"}
    end
  end

  defp keep_never(session_id, proposal, "never") do
    case Troupe.Proposals.never(session_id, proposal["kind"], proposal["key"]) do
      :ok -> :ok
      {:error, reason} when is_binary(reason) -> {:error, "not kept: " <> reason}
      {:error, reason} -> {:error, "not kept: #{inspect(reason)}"}
    end
  end

  defp keep_never(_session_id, _proposal, _later), do: :ok

  defp write_answer(state, id, data, actor) do
    {:ok, _seq} = Log.append(state.session_id, ["root"], :proposal_answered, data, actor)
    own(state, %Event{type: "proposal_answered", data: normal_data(Map.put(data, "id", id))})
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp normal(%Event{data: data} = event), do: %{event | data: normal_data(data)}
  defp normal_data(data), do: data |> Jason.encode!() |> Jason.decode!()
end
