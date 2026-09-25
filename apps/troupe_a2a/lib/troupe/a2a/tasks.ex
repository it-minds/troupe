defmodule Troupe.A2A.Tasks do
  @moduledoc """
  The task methods: `message/send`, `tasks/get`, `tasks/cancel`.

  A task is a session and the task id is the session id. `message/send` without a task
  is `session.create` as the caller's principal, with `origin.kind: a2a` on the row so
  the plane can list what other agents asked for; with a task it is `input.send` on the
  worker socket, or `approval.respond` when the task is waiting and the message carries
  a decision. `tasks/get` is the plane's row, and a reader over the log when the row
  cannot say enough. `tasks/cancel` is `turn.cancel` and then `session.archive`.

  Nothing is stored here. A restarted facade answers `tasks/get` the same way, because
  the row and the log are the plane's and the pod's.
  """

  alias Troupe.A2A.{Error, Events, Plane, Stream, Worker}
  alias Troupe.Protocol.{Canonical, Client, Origin, Principal, SessionId}
  alias Troupe.Protocol.Error, as: PlaneError

  @type action :: {:input, String.t()} | {:decision, String.t(), String.t()}
  @type intent :: {:create, map()} | {:continue, map(), action()}

  # -- message/send -------------------------------------------------------------

  @doc "`message/send`. Blocking when the configuration says so; a `submitted` task otherwise."
  @spec send(Plane.caller(), String.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def send(caller, profile, params) do
    history_length = history_length(params)
    blocking? = get_in(params, ["configuration", "blocking"]) == true

    with {:ok, message} <- message_of(params),
         {:ok, intent} <- intent(caller, profile, message, params) do
      case intent do
        {:create, create_params} ->
          create(caller, create_params, message, blocking?, history_length)

        {:continue, row, action} ->
          continue(caller, row, action, blocking?, history_length)
      end
    end
  end

  @doc "The message a `message/send` or `message/stream` carries, checked for shape."
  @spec message_of(map()) :: {:ok, map()} | {:error, Error.t()}
  def message_of(%{"message" => %{"parts" => parts} = message}) when is_list(parts),
    do: {:ok, message}

  def message_of(_params), do: {:error, Error.invalid_params("message.parts is required")}

  @doc """
  What a message asks for: a new task, or an action on one that exists.

  A message names its task with `taskId`; one that names only a `contextId` is a
  follow-up in the same conversation, and here a conversation is a session, so it is
  the same thing. A message on a task that has finished continues its session — the
  log has `input_after_done` for exactly this — rather than being refused, because a
  follow-up that started a fresh session would have lost everything the first one knew.
  """
  @spec intent(Plane.caller(), String.t(), map(), map()) :: {:ok, intent()} | {:error, Error.t()}
  def intent(caller, profile, message, params) do
    case message["taskId"] || message["contextId"] do
      nil -> create_intent(caller, profile, message, params)
      task_id -> continue_intent(caller, task_id, message)
    end
  end

  defp create_intent(caller, profile, message, params) do
    case Events.text_of_parts(message["parts"]) do
      "" ->
        {:error, Error.invalid_params("a new task needs a text part to start from")}

      prompt ->
        id = generate_id()
        metadata = Map.get(params, "metadata") || %{}

        create_params =
          %{
            "profile" => profile,
            "prompt" => prompt,
            "visibility" => Troupe.A2A.visibility(),
            "session_id" => id,
            # The same block a trigger's firing writes, so that a session started from
            # outside and one started by a schedule are one shape in the log and one row
            # in a listing. The facade stays what it is — an agent that is not ours, with
            # its own card — and what it produces is not a second-class run.
            "origin" =>
              Origin.integration(
                caller: caller.subject,
                task: id,
                payload_digest: Canonical.hash(message),
                principal: Principal.of(caller.subject)
              ),
            "title" => metadata["title"] || title_of(prompt)
          }
          |> maybe_put("agent", metadata["agent"])

        {:ok, {:create, create_params}}
    end
  end

  defp continue_intent(caller, task_id, message) do
    with {:ok, row} <- fetch_task(caller, task_id) do
      waiting? = Events.state_of_row(row) == "input-required"

      case Events.decision_of(message["parts"]) do
        {:ok, decision, call_id} ->
          decision_intent(row, decision, call_id, waiting?)

        {:error, reason} ->
          {:error, Error.invalid_params(reason)}

        :none ->
          text_intent(row, Events.text_of_parts(message["parts"]), waiting?)
      end
    end
  end

  defp decision_intent(_row, _decision, _call_id, false) do
    {:error, Error.invalid_params("no approval is pending on this task; send text instead")}
  end

  defp decision_intent(row, decision, call_id, true) do
    case call_id || single_pending(row) do
      nil ->
        {:error,
         Error.invalid_params(
           "call_id is required: the task's input-required status names the call to decide"
         )}

      call_id ->
        {:ok, {:continue, row, {:decision, decision, call_id}}}
    end
  end

  defp text_intent(_row, "", _waiting?) do
    {:error, Error.invalid_params("message has no text part and no decision")}
  end

  # Text cannot answer a yes or no the log will record as a decision, so a waiting
  # task refuses it and says what it wants instead.
  defp text_intent(_row, _text, true) do
    {:error,
     Error.invalid_params(
       "this task is waiting for an approval; answer with a data part " <>
         ~s({"decision": "allow" | "deny" | "allow_session", "call_id": "..."}) <>
         " rather than text"
     )}
  end

  defp text_intent(row, text, false), do: {:ok, {:continue, row, {:input, text}}}

  defp single_pending(row) do
    case Events.pending_call_ids(row) do
      [only] -> only
      _other -> nil
    end
  end

  defp create(caller, create_params, message, blocking?, history_length) do
    with {:ok, grant} <- plane(Plane.create_session(caller, create_params), nil) do
      task_id = grant["session_id"] || create_params["session_id"]

      if blocking?,
        do: await(caller, grant, task_id, history_length),
        else: {:ok, submitted(task_id, message, history_length)}
    end
  end

  # The task as it stands the moment the row exists: `submitted`, with the caller's own
  # message as its history when history was asked for.
  defp submitted(task_id, message, history_length) do
    text = Events.text_of_parts(message["parts"])
    user = Events.user_message(task_id, text, message["messageId"] || "#{task_id}-0")
    Events.task(%{Events.new(task_id) | history: [user]}, history_length: history_length)
  end

  # A blocking send on a new task: the socket is held from the first event until the
  # task is at rest, and the answer comes back in the response.
  defp await(caller, grant, task_id, history_length) do
    case Worker.connect(grant) do
      {:ok, client} ->
        try do
          acc = Stream.collect(client, caller, task_id, from_seq: 0)
          {:ok, Events.task(acc, history_length: history_length)}
        after
          Client.close(client)
        end

      {:error, error} ->
        {:error, Error.from_plane(error, task_id)}
    end
  end

  defp continue(caller, row, action, blocking?, history_length) do
    task_id = row["id"]

    result =
      Worker.with_session(caller, task_id, "activate", fn client, _grant ->
        if blocking?,
          do: awaited(client, caller, task_id, action, history_length),
          else: acknowledged(client, row, action)
      end)

    plane(result, task_id)
  end

  # Blocking: the action lands once the subscription is up, and the socket is held
  # until the task is at rest.
  defp awaited(client, caller, task_id, action, history_length) do
    acc =
      Stream.collect(client, caller, task_id,
        after_subscribe: fn client -> perform(client, task_id, action) end
      )

    {:ok, Events.task(acc, history_length: history_length)}
  end

  # Not blocking: the action is acknowledged, and the task is reported as `working`
  # from the row alone.
  defp acknowledged(client, row, action) do
    with {:ok, _ack} <- perform(client, row["id"], action) do
      task = Events.task_from_row(row)
      {:ok, put_in(task, ["status", "state"], "working")}
    end
  end

  @doc "Carry out an action on an open socket. The acknowledgement is not the effect."
  @spec perform(pid(), String.t(), action()) :: {:ok, map()} | {:error, PlaneError.t()}
  def perform(client, task_id, {:input, text}), do: Worker.send_input(client, task_id, text)

  def perform(client, task_id, {:decision, decision, call_id}),
    do: Worker.respond(client, task_id, call_id, decision)

  # -- tasks/get ----------------------------------------------------------------

  @doc """
  `tasks/get`.

  From the row alone while the task is being worked on and no history is asked for:
  that is the cheap poll. A task at rest — finished, failed, or waiting on the caller —
  is rendered from the log through a reader, because the row cannot say what the
  answer was or which tool is waiting, and that is what the caller came for.
  """
  @spec get(Plane.caller(), map()) :: {:ok, map()} | {:error, Error.t()}
  def get(caller, params) do
    task_id = params["id"]

    history_length =
      case params["historyLength"] do
        length when is_integer(length) and length > 0 -> length
        _other -> 0
      end

    with {:ok, row} <- fetch_task(caller, task_id) do
      state = Events.state_of_row(row)

      if history_length > 0 or state in ~w(completed failed canceled input-required) do
        render(caller, row, state, history_length)
      else
        {:ok, Events.task_from_row(row)}
      end
    end
  end

  defp render(caller, row, row_state, history_length) do
    case Stream.replay(caller, row["id"]) do
      {:ok, acc} ->
        # The log's word when it has one; the row's when the log is mid-turn, which is
        # what a `working` task with history asked for looks like.
        state = if Events.at_rest?(acc), do: acc.state, else: row_state

        {:ok,
         Events.task(%{acc | state: state},
           history_length: history_length,
           timestamp: row["last_active_at"]
         )}

      {:error, error} ->
        {:error, Error.from_plane(error, row["id"])}
    end
  end

  # -- tasks/cancel -------------------------------------------------------------

  @doc "`tasks/cancel`: stop the turn, then archive the session."
  @spec cancel(Plane.caller(), map()) :: {:ok, map()} | {:error, Error.t()}
  def cancel(caller, params) do
    task_id = params["id"]

    with {:ok, row} <- fetch_task(caller, task_id),
         :ok <- cancelable(row),
         {:ok, _ack} <-
           plane(
             Worker.with_session(caller, task_id, "activate", fn client, _grant ->
               Worker.cancel(client, task_id)
             end),
             task_id
           ),
         {:ok, _archived} <- plane(Plane.archive_session(caller, task_id), task_id) do
      task = Events.task_from_row(row)
      {:ok, put_in(task, ["status", "state"], "canceled")}
    end
  end

  defp cancelable(row) do
    if Events.state_of_row(row) in ~w(completed failed canceled),
      do: {:error, Error.not_cancelable(row["id"])},
      else: :ok
  end

  # -- finding a task -----------------------------------------------------------

  @doc """
  The row for a task the caller may see, or `Task not found`.

  A session the plane will not show this principal and a session no A2A call created
  are the same answer. The second matters less for safety than for meaning: a person's
  own session is not a task, and a caller that guessed its id should not be told about
  it here.
  """
  @spec fetch_task(Plane.caller(), String.t() | nil) :: {:ok, map()} | {:error, Error.t()}
  def fetch_task(_caller, nil), do: {:error, Error.invalid_params("id is required")}

  def fetch_task(caller, task_id) do
    with {:ok, row} <- plane(Plane.get_session(caller, task_id), task_id) do
      if get_in(row, ["origin", "kind"]) == "a2a",
        do: {:ok, row},
        else: {:error, Error.task_not_found(task_id)}
    end
  end

  defp plane({:ok, value}, _task_id), do: {:ok, value}

  defp plane({:error, %PlaneError{} = error}, task_id),
    do: {:error, Error.from_plane(error, task_id)}

  defp plane({:error, %{"code" => _} = error}, _task_id), do: {:error, error}

  defp history_length(params) do
    case get_in(params, ["configuration", "historyLength"]) do
      length when is_integer(length) and length > 0 -> length
      _other -> 0
    end
  end

  # A title is a courtesy to whoever reads the review queue; the first line of the
  # prompt, cut short, is what a person would have typed.
  defp title_of(prompt) do
    prompt
    |> String.split("\n", parts: 2)
    |> hd()
    |> String.slice(0, 80)
  end

  # A session id, which is what the task id is called in the request that made it and
  # what the plane keeps as the session id. The plane and every pod refuse any other
  # shape, so it is generated the way the plane generates its own.
  defp generate_id, do: SessionId.generate()

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
