defmodule Troupe.Sessions.Unseen do
  @moduledoc """
  What happened in a session while no client was reading it, for its listing (#119).

  A person who closed the app, or walked away from a session, comes back to a row that
  says what they missed: a turn that ended, an approval or a question raised, with nobody
  there to see it. That is the "while you were away" the desktop app's notification and
  its marker are drawn from, and the row is the whole contract: `session.list` and
  `session.get` carry it as `unseen`, and nothing else does.

  The mark is a file beside the log, `seen`, holding the head `seq` as of the last moment
  a client was attached (`Troupe.Events.attach/1`): written when one attaches and reads,
  and again when it leaves. Unseen is what the root agent did after it, since that is what
  the session did: each `turn_ended`, and each approval and question once, however often a
  wake asks it again under the same id. Nothing is unseen while a client is attached, and
  nothing in a session no client has ever read, which has no mark to count from; that is
  also what keeps every session from before this existed from lighting up at once.

  A file rather than an event, on purpose. A reader's progress is not something the session
  did, reading a dormant session must write nothing to a log it has not opened, and a mark
  in the log would reach every other subscriber as an event about somebody else's screen.
  """

  alias Troupe.{Events, Session}
  alias Troupe.Protocol.Event
  alias Troupe.Session.Log

  @seen "seen"
  @noted ~w(turn_ended approval_requested question_asked)

  @typedoc "The row's value: counts, and the time of the first of them."
  @type t :: %{
          turns: non_neg_integer(),
          approvals: non_neg_integer(),
          questions: non_neg_integer(),
          since: String.t() | nil
        }

  @doc "Nothing unseen."
  @spec none() :: t()
  def none, do: %{turns: 0, approvals: 0, questions: 0, since: nil}

  @doc """
  Record that a client has read the session up to its head, running or not.

  `state_dir` is where a dormant session's log is looked for; `nil` is the daemon's own.
  A session with no log yet, or none any more, has nothing to mark.
  """
  @spec seen(String.t(), Path.t() | nil) :: :ok
  def seen(session_id, state_dir \\ nil) do
    case log(session_id, state_dir) do
      nil ->
        :ok

      path ->
        _ =
          File.write(
            Path.join(Path.dirname(path), @seen),
            Integer.to_string(head(session_id, path))
          )

        :ok
    end
  end

  @doc """
  What nobody has seen of a session whose log is in `dir`: `events` reads the log, and is
  only called when there is a mark to count from and nobody attached.
  """
  @spec of(String.t(), Path.t(), (-> [Event.t()])) :: t()
  def of(session_id, dir, events) do
    mark = mark(dir)

    cond do
      Events.attached?(session_id) -> none()
      mark == nil -> none()
      true -> count(events.(), mark)
    end
  end

  defp count(events, mark) do
    root = Session.root_path()

    noted =
      Enum.filter(events, fn %Event{agent: agent, seq: seq, type: type} ->
        agent == root and is_integer(seq) and seq > mark and type in @noted
      end)

    %{
      turns: Enum.count(noted, &(&1.type == "turn_ended")),
      approvals: distinct(noted, "approval_requested"),
      questions: distinct(noted, "question_asked"),
      since: noted |> List.first() |> then(&(&1 && &1.ts))
    }
  end

  # A request asked again on a wake carries the id it was asked under, and is one request.
  defp distinct(events, type) do
    events
    |> Enum.filter(&(&1.type == type))
    |> Enum.map(& &1.data["call_id"])
    |> Enum.uniq()
    |> length()
  end

  defp mark(dir) do
    with {:ok, contents} <- File.read(Path.join(dir, @seen)),
         {seq, _rest} <- Integer.parse(String.trim(contents)) do
      seq
    else
      _ -> nil
    end
  end

  # The running log's own path, else the file on disk.
  defp log(session_id, state_dir) do
    Log.path(session_id)
  catch
    :exit, _ -> Log.locate(session_id, state_dir)
  end

  defp head(session_id, path) do
    Log.head_seq(session_id)
  catch
    :exit, _ ->
      case Log.read_file(path) do
        [] -> 0
        events -> List.last(events).seq || 0
      end
  end
end
