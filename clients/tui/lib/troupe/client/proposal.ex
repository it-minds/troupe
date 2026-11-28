defmodule Troupe.Client.Proposal do
  @moduledoc """
  What the harness proposes in a session on the platform, in the lines the terminal says
  (root #1208): `proposal_made` as a line naming the question, why, and how to answer it,
  and `proposal_answered` as a line saying what was done. `/proposal` answers the open one:
  `yes` turns it on at the plane as the person, `later` and `never` tell the session. Only
  the session's owner answers.
  """

  @typedoc "What `/proposal` asks: what is open, or an answer to it."
  @type verb :: :status | :yes | :later | :never

  @doc "What `/proposal` names after the command: nothing, `yes`, `later` or `never`."
  @spec parse(String.t()) :: {:ok, verb()} | {:error, String.t()}
  def parse(args) do
    case String.trim(args) do
      "" ->
        {:ok, :status}

      "yes" ->
        {:ok, :yes}

      "later" ->
        {:ok, :later}

      "never" ->
        {:ok, :never}

      other ->
        {:error,
         "/proposal yes, /proposal later, /proposal never, or /proposal alone: not #{other}"}
    end
  end

  @doc "The line a `proposal_made` is said as."
  @spec made(map()) :: String.t()
  def made(data) do
    ask =
      case data["mode"] do
        "unavailable" ->
          "It cannot run here unattended: #{data["reason"] || "the profile would stop it"}. " <>
            "/proposal later or /proposal never answers it."

        "gitops" ->
          "Triggers here are kept in a repository: /proposal yes gives you the file to commit. " <>
            "/proposal later or /proposal never says no."

        _direct ->
          "#{runs(data["draft"] || %{})} /proposal yes turns it on, /proposal later or /proposal never says no."
      end

    Enum.join(
      Enum.reject(["Troupe asks: #{data["title"]}", data["why"], ask], &(&1 in [nil, ""])),
      " "
    )
  end

  @doc "What `/proposal` alone says of the open one, or that none is open."
  @spec status(map() | nil) :: String.t()
  def status(nil), do: "nothing is proposed in this session now"
  def status(data), do: made(data)

  @doc "The line a `proposal_answered` is said as, `title` the report's."
  @spec answered(map(), String.t() | nil) :: String.t()
  def answered(%{"decision" => "accepted", "result" => %{"yaml" => _} = result}, title),
    do:
      "#{by(result)}took the Trigger file that reruns #{quoted(title)}: commit it as #{result["path"] || "a file of the repository"}."

  def answered(%{"decision" => "accepted"} = data, title) do
    result = data["result"] || %{}

    # The log holds what the yes made, not how it stands since: the line says where to ask.
    {where, stands} =
      if result["team"],
        do:
          {" as the trigger #{result["name"]} of #{result["team"]}",
           " /triggers says whether it is on now."},
        else: {"", ""}

    "#{by(data)}turned on a rerun of #{quoted(title)}#{where}; each run asks to be reviewed.#{stands}"
  end

  def answered(%{"decision" => "later"} = data, title),
    do: "#{by(data)}said not now to rerunning #{quoted(title)}."

  def answered(%{"decision" => "never"} = data, title),
    do: "#{by(data)}said never for rerunning #{quoted(title)}."

  def answered(data, title), do: "#{by(data)}answered the proposal about #{quoted(title)}."

  @doc "The sentence a yes the plane carried out is said in."
  @spec accepted(map()) :: String.t()
  def accepted(%{"yaml" => yaml} = answer),
    do:
      "Commit this as #{answer["path"] || "a file of the repository"}; a team admin names its principal:\n#{yaml}"

  def accepted(answer),
    do:
      "Turned on: the trigger #{answer["name"]} of #{answer["team"]} reruns it as you; " <>
        "/trigger off #{answer["name"]} switches it off, and /triggers lists yours."

  @doc "Why a session on this computer has nothing proposed."
  @spec not_here() :: String.t()
  def not_here,
    do: "only a session on the platform proposes a schedule: nothing on this computer runs one"

  defp runs(draft) do
    budget = get_in(draft, ["terms", "budget_micros"])

    cost =
      if is_integer(budget),
        do: ", up to #{"$" <> :erlang.float_to_binary(budget / 1_000_000, decimals: 2)} a run",
        else: ""

    title = get_in(draft, ["artifact", "title"])

    "Runs as you, on #{draft["profile"] || "this session's profile"}#{cost}; each run is a new version of #{quoted(title)}."
  end

  defp by(%{"by_name" => name}) when is_binary(name) and name != "", do: "#{name} "
  defp by(_data), do: "The owner "

  defp quoted(nil), do: "the report"
  defp quoted(title), do: "\"#{title}\""
end
