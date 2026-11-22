defmodule Troupe.Client.Share do
  @moduledoc """
  Whose a session on the platform is, in the sentences `/share` says (root #1169): the
  team's, which every member of it may open and steer where the team allows, or its
  owner's, which only they and the people they invited may open. Only the owner gives it to
  the team or takes it back, and invitations stay as they are either way.
  """

  @typedoc "What `/share` asks: whose it is, or to give it to the team or take it back."
  @type verb :: :status | {:set, String.t()}

  @doc "What `/share` names after the command: nothing, `team` or `me`."
  @spec parse(String.t()) :: {:ok, verb()} | {:error, String.t()}
  def parse(args) do
    case String.trim(args) do
      "" -> {:ok, :status}
      "team" -> {:ok, {:set, "team"}}
      "me" -> {:ok, {:set, "private"}}
      other -> {:error, "/share team, /share me, or /share alone: not #{other}"}
    end
  end

  @doc "The wire visibility a status line's mark is drawn from, in its words."
  @spec mark(String.t() | nil, boolean()) :: String.t() | nil
  def mark("team", _owner?), do: "the team's"
  def mark("private", true), do: "only you"
  def mark("private", false), do: "by invitation"
  def mark(_other, _owner?), do: nil

  @doc "What `/share` alone says of a session row: whose it is, and to its owner what changes it."
  @spec status(map()) :: String.t()
  def status(%{"visibility" => "team"} = row) do
    "Given to #{team(row)}: everyone on it can open it, and steer it where the team allows." <>
      if(owner?(row), do: " /share me takes it back.", else: "")
  end

  def status(row) do
    if owner?(row) do
      "Only you and the people you invited can open it. /share team gives it to #{team(row)}."
    else
      "Only its owner and the people they invited can open it."
    end
  end

  @doc "The sentence for a session just given to the team or taken back."
  @spec set(map()) :: String.t()
  def set(%{"visibility" => "team"} = row),
    do: "Given to #{team(row)}: everyone on it can open it, and steer it where the team allows."

  def set(_row),
    do: "Only you again: only you and the people you invited can open it; the invitations stay."

  @doc "What a `forbidden` answer says: whose it is to change, or the reason given."
  @spec forbidden(map() | nil) :: String.t()
  def forbidden(%{"required_role" => "owner"}), do: not_owner()
  def forbidden(%{"reason" => reason}) when is_binary(reason), do: reason
  def forbidden(_data), do: not_owner()

  @doc "Why a session that is not on the platform cannot be given to a team."
  @spec not_here() :: String.t()
  def not_here,
    do:
      "only a session on the platform is given to a team: this one is on this computer, " <>
        "and /invite shares it with a person"

  defp not_owner, do: "only the session's owner gives it to the team or takes it back"

  defp owner?(row), do: row["your_role"] == "owner"

  defp team(%{"team" => team}) when is_binary(team) and team != "", do: "the #{team} team"
  defp team(_row), do: "the team"
end
