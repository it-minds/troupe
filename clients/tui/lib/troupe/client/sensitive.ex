defmodule Troupe.Client.Sensitive do
  @moduledoc """
  A sensitive session, in the sentences the terminal says (root #1239) and the words both web
  apps say (`@troupe/client`'s `sensitive.ts`). A session becomes sensitive by a tool call its
  worker profile names, or by its owner's hand (`/sensitive`, `/new --sensitive`, `troupe run
  --sensitive`), and nothing clears it: from then on its profile refuses what would take what
  it read out of it, and sharing it beyond the people who read it now follows the profile's
  `sensitive.sharing`. The plane's row carries the mark as `sensitive` (`{at, by, how}`), the
  log as `session_marked_sensitive`, a refused call's `tool_call_completed` as `refused`.
  """

  @doc "The word every client marks a sensitive session with."
  @spec word() :: String.t()
  def word, do: "sensitive"

  @doc "A row's or a checkpoint's mark, `%{at, by, how}` with `name` where it says one, or nil."
  @spec of(map() | nil) :: map() | nil
  def of(%{} = value) do
    at = value["at"] || Map.get(value, :at)
    by = value["by"] || Map.get(value, :by)

    if is_binary(at) and is_binary(by) do
      %{
        at: at,
        by: by,
        how: if((value["how"] || Map.get(value, :how)) == "person", do: "person", else: "call"),
        name: value["display_name"] || value["name"] || Map.get(value, :name)
      }
    end
  end

  def of(_none), do: nil

  @doc "A row's mark: `sensitive`, or empty for a session that is not, which shows nothing."
  @spec mark(map() | nil) :: String.t()
  def mark(value), do: if(of(value), do: word(), else: "")

  @doc """
  The transcript's line where the log says it became sensitive: since when, by what, and that
  nothing clears it. The log does not say which tools its profile refuses, so the line says
  what they are for.
  """
  @spec line(map()) :: String.t()
  def line(data) do
    mark = of(data) || %{at: nil, by: "something", how: "call", name: nil}

    how =
      if mark.how == "person",
        do: "#{mark.name || mark.by} marked it",
        else: "#{mark.by} read from it"

    "This session became sensitive at #{clock(mark.at)}: #{how}. Nothing clears it; its " <>
      "profile refuses what would take what it read out of it."
  end

  @doc "What `/sensitive` asks before it marks a session, since nothing clears the mark."
  @spec ask() :: String.t()
  def ask,
    do:
      "Make this session sensitive? From now on its profile refuses what would take what it " <>
        "read out of it, and sharing it wider follows the profile's rule. Nothing clears it. " <>
        "Press y to mark it, anything else to leave it."

  @doc "The sentence for a session just marked sensitive by hand."
  @spec set(map()) :: String.t()
  def set(row) do
    case of(row["sensitive"]) do
      nil -> "Marked sensitive: nothing clears it."
      mark -> "Sensitive since #{clock(mark.at)}: nothing clears it."
    end
  end

  @doc "What `/sensitive` says of a session already sensitive."
  @spec already(map()) :: String.t()
  def already(mark) do
    mark = of(mark)

    how =
      if mark.how == "person",
        do: "marked by #{mark.name || mark.by}",
        else: "#{mark.by} read from it"

    "This session is sensitive since #{clock(mark.at)}: #{how}; nothing clears it."
  end

  @doc "Why it was not marked: whose it is to mark, the reason given, or a server that cannot."
  @spec refused(term()) :: String.t()
  def refused(%{code: -32_601}), do: not_known()

  def refused(%{message: "forbidden", data: %{"reason" => reason}}) when is_binary(reason),
    do: reason

  def refused(%{message: "forbidden"}), do: "only the session's owner marks it sensitive"
  def refused(%{data: %{"reason" => reason}}) when is_binary(reason), do: reason
  def refused(other), do: "it was not marked sensitive: #{inspect(other)}"

  @doc "What a server from before sensitive sessions is answered with."
  @spec not_known() :: String.t()
  def not_known, do: "this server does not know sensitive sessions yet"

  @doc "Why a session on this computer is not marked here."
  @spec not_here() :: String.t()
  def not_here,
    do: "only a session on the platform is marked sensitive from here: this one is on this computer"

  @doc """
  A share a sensitive session's profile refused (`forbidden`, `setting` `sensitive` or
  `sensitive.sharing`): the plane's own sentence, which names who reads it now; nil for any
  other refusal.
  """
  @spec sharing_refused(term()) :: String.t() | nil
  def sharing_refused(%{
        message: "forbidden",
        data: %{"setting" => "sensitive" <> _, "reason" => why}
      })
      when is_binary(why),
      do: sentence(why)

  def sharing_refused(_error), do: nil

  @doc """
  What a share held for a team administrator answers the owner, with how the request stands;
  nil for an answer that is not a hold.
  """
  @spec waiting(term()) :: String.t() | nil
  def waiting(%{"waiting" => true} = answer) do
    said =
      answer["reason"] ||
        "This session is sensitive, so sharing it wider is waiting on a team administrator"

    state =
      case get_in(answer, ["share_request", "state"]) do
        "pending" -> " (it waits)"
        "approved" -> " (a team administrator said yes)"
        "declined" -> " (a team administrator said no)"
        _ -> ""
      end

    sentence(said <> state)
  end

  def waiting(_answer), do: nil

  defp sentence(text), do: if(String.ends_with?(text, [".", "!", "?"]), do: text, else: text <> ".")

  # When, as a clock says it, in UTC as the harness's sentences say it: `10:14 UTC`.
  defp clock(at) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, dt, _offset} -> Calendar.strftime(dt, "%H:%M UTC")
      _ -> at
    end
  end

  defp clock(_none), do: "some point"
end
