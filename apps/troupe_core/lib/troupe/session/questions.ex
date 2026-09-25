defmodule Troupe.Session.Questions do
  @moduledoc """
  Questions an agent asks a person, and the answers.

  The other half of `Troupe.Session.Approvals`: an approval is a yes or no about a tool
  call the agent already decided on, a question is the agent handing the decision over.
  `ask_user` blocks its tool task here until somebody answers over the wire
  (`question.answer`), or until the session says nobody will (`approvals: :deny`, the
  unattended mode), and the answer becomes the tool's result.

  Durable on both sides — `question_asked`, `question_answered` — because a question
  outlives dormancy exactly as an approval does: a person may come back to it days
  later, and a tool re-run after a restart must find its answer rather than ask twice.
  """

  use GenServer

  alias Troupe.Session.Log

  @type question :: %{
          call_id: String.t(),
          agent_path: [String.t()],
          question: String.t(),
          options: [%{label: String.t(), description: String.t() | nil}],
          multiple: boolean()
        }

  # `asked` is what the log says was asked and never answered, read back at start-up: the
  # questions a session that slept mid-question asks again when it comes back.
  defstruct [:session_id, mode: :wait, pending: %{}, answered: %{}, asked: %{}]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, opts, name: Troupe.Registry.questions(session_id))
  end

  @doc """
  Ask, and wait for the answer.

  `:infinity`, like an approval: the timeout that matters is the tool's own, enforced by
  the agent killing the task. `{:error, :unattended}` is the answer of a session running
  in `:deny` mode, so the model hears that nobody is there rather than waiting forever.
  """
  @spec ask(String.t(), question()) :: {:ok, String.t()} | {:error, :unattended}
  def ask(session_id, %{call_id: _, question: _} = question) do
    GenServer.call(Troupe.Registry.questions(session_id), {:ask, question}, :infinity)
  catch
    :exit, _ -> {:error, :unattended}
  end

  @doc "Answer an outstanding question. First answer wins."
  @spec answer(String.t(), String.t(), String.t(), Troupe.Protocol.Event.Actor.t() | nil) :: :ok
  def answer(session_id, call_id, text, actor \\ nil) do
    GenServer.cast(Troupe.Registry.questions(session_id), {:answer, call_id, text, actor})
  end

  @doc "Questions waiting for an answer, for a client that asks rather than replays."
  @spec pending(String.t()) :: [question()]
  def pending(session_id), do: GenServer.call(Troupe.Registry.questions(session_id), :pending)

  ## Server

  @impl GenServer
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    Process.set_label("troupe questions #{session_id}")
    state = %__MODULE__{session_id: session_id, mode: Keyword.get(opts, :mode, :wait)}
    {:ok, replay(state)}
  end

  defp replay(state) do
    state.session_id
    |> Log.replay()
    |> Enum.reduce(state, &fold/2)
  rescue
    _exception -> state
  catch
    :exit, _reason -> state
  end

  defp fold(%{type: "question_asked", data: %{"call_id" => id} = data} = event, state),
    do: %{state | asked: Map.put(state.asked, id, data["agent_path"] || event.agent)}

  defp fold(%{type: "question_answered", data: %{"call_id" => id, "text" => text}}, state),
    do: %{state | answered: Map.put(state.answered, id, text), asked: Map.delete(state.asked, id)}

  # A call closed off some other way — timed out, interrupted — is waiting for nobody.
  defp fold(%{type: "tool_call_completed", data: %{"call_id" => id}}, state),
    do: %{state | asked: Map.delete(state.asked, id)}

  defp fold(_event, state), do: state

  @impl GenServer
  def handle_call({:ask, question}, from, state) do
    cond do
      # Already answered, and the tool is only asking again because the session came
      # back and re-dispatched it.
      Map.has_key?(state.answered, question.call_id) ->
        {:reply, {:ok, Map.fetch!(state.answered, question.call_id)}, state}

      # Nobody to ask. The question is still written, so the transcript shows what the
      # agent wanted to know.
      state.mode == :deny ->
        Log.append(state.session_id, question.agent_path, :question_asked, describe(question))
        {:reply, {:error, :unattended}, state}

      true ->
        {caller, _tag} = from
        monitor = Process.monitor(caller)
        pending = Map.put(state.pending, question.call_id, %{from: from, monitor: monitor, question: question})
        Log.append(state.session_id, question.agent_path, :question_asked, describe(question))
        {:noreply, %{state | pending: pending}}
    end
  end

  def handle_call(:pending, _from, state) do
    {:reply, Enum.map(state.pending, fn {_id, entry} -> entry.question end), state}
  end

  @impl GenServer
  def handle_cast({:answer, call_id, text, actor}, state) do
    case Map.pop(state.pending, call_id) do
      {nil, _} ->
        {:noreply, not_pending(state, call_id, text, actor)}

      {entry, pending} ->
        Process.demonitor(entry.monitor, [:flush])
        GenServer.reply(entry.from, {:ok, text})
        state = %{state | pending: pending}
        {:noreply, record(state, call_id, entry.question.agent_path, text, actor)}
    end
  end

  # Asked before this tree started, and not yet asked again. Answering a dormant session's
  # question is what wakes it, so the answer can arrive before the call it answers has gone
  # back out; it is kept, and handed over when that call asks.
  #
  # Anything else is a second answer, or one to a question this session never asked:
  # nothing to do, and not an error — two people watching one session is the normal case.
  defp not_pending(state, call_id, text, actor) do
    case Map.fetch(state.asked, call_id) do
      {:ok, agent_path} -> record(state, call_id, agent_path, text, actor)
      :error -> state
    end
  end

  defp record(state, call_id, agent_path, text, actor) do
    Log.append(
      state.session_id,
      agent_path,
      :question_answered,
      %{"call_id" => call_id, "text" => text},
      actor
    )

    %{
      state
      | answered: Map.put(state.answered, call_id, text),
        asked: Map.delete(state.asked, call_id)
    }
  end

  @impl GenServer
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    {gone, pending} =
      Enum.split_with(state.pending, fn {_id, entry} -> entry.monitor == monitor end)

    # The call that was asking has been closed off, so nothing is waiting for this answer
    # any more, including a call from before the tree started.
    asked = Map.drop(state.asked, Enum.map(gone, &elem(&1, 0)))

    {:noreply, %{state | pending: Map.new(pending), asked: asked}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp describe(question) do
    %{
      "call_id" => question.call_id,
      "agent_path" => question.agent_path,
      "question" => question.question,
      "options" =>
        Enum.map(question.options, fn option ->
          %{"label" => option.label, "description" => option.description}
        end),
      "multiple" => question.multiple
    }
  end
end
