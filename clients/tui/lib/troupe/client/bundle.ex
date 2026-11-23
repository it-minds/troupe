defmodule Troupe.Client.Bundle do
  @moduledoc """
  Which configuration a session on the platform runs on, in the sentences `/bundle` says
  (root #1177): the bundle version it is pinned to and, where its channel has published a
  newer one, that one. Its owner raises it with `/bundle update`: at once when its agent is
  at rest, and when the agent is done otherwise. A session on this computer has no bundle.
  """

  @typedoc "What `/bundle` asks: which version, or to raise it to the current one."
  @type verb :: :status | :update

  @doc "What `/bundle` names after the command: nothing or `update`."
  @spec parse(String.t()) :: {:ok, verb()} | {:error, String.t()}
  def parse(args) do
    case String.trim(args) do
      "" -> {:ok, :status}
      "update" -> {:ok, :update}
      other -> {:error, "/bundle or /bundle update: not #{other}"}
    end
  end

  @doc "What `/bundle` alone says of a session row."
  @spec status(map()) :: String.t()
  def status(row) do
    case {version(row["bundle_version"]), version(row["bundle_current"]),
          version(row["bundle_raise_to"])} do
      {nil, _current, _owed} ->
        "This session is pinned to no bundle version: nothing was published on its channel when it started."

      {pinned, _current, owed} when is_integer(owed) and owed > pinned ->
        "Configuration v#{pinned}; it moves to v#{owed} when the agent is done."

      {pinned, current, _owed} when is_integer(current) and current > pinned ->
        "Configuration v#{pinned}; v#{current} is current." <>
          if(owner?(row), do: " /bundle update moves it there; the conversation stays.", else: "")

      {pinned, _current, _owed} ->
        "Configuration v#{pinned}, the current one."
    end
  end

  @doc "The sentence for a session just raised."
  @spec raised(map()) :: String.t()
  def raised(row),
    do:
      "Configuration v#{version(row["bundle_version"])} now: its tools, skills and servers are the new version's."

  @doc "The sentence for a raise the plane keeps while the agent works."
  @spec kept(term()) :: String.t()
  def kept(to), do: "The agent is working: it moves to v#{to} when the agent is done."

  @doc "What a `forbidden` answer says."
  @spec forbidden(map() | nil) :: String.t()
  def forbidden(%{"reason" => reason}) when is_binary(reason), do: reason
  def forbidden(_data), do: "only the session's owner updates its configuration"

  @doc "Why a session on this computer has no configuration to update."
  @spec not_here() :: String.t()
  def not_here,
    do: "a session on this computer has no bundle: its agents are this computer's own"

  defp owner?(row), do: row["your_role"] == "owner"

  defp version(v) when is_integer(v) and v > 0, do: v

  defp version(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} when n > 0 -> n
      _ -> nil
    end
  end

  defp version(_v), do: nil
end
