defmodule Troupe.Client.Marks do
  @moduledoc """
  A session's name and whether it is kept at the top of the session list, in the sentences
  `/rename` and `/keep` say, whichever side the session lives on. Both are the owner's, and
  both are the session's for everyone who sees it. Kept, a session is listed first, and a
  plane does not clear it away under its retention (`session.pin`).
  """

  @doc "The sentence for a session just named, or whose name was taken off (`nil`)."
  @spec renamed(String.t() | nil) :: String.t()
  def renamed(nil), do: "The name is off: the session list shows it by where it works."
  def renamed(title), do: "Renamed: the session list shows it as “#{title}”."

  @doc "The sentence for a session just kept at the top (`true`) or let go from it."
  @spec kept(boolean()) :: String.t()
  def kept(true),
    do: "Kept at the top of the session list, for everyone who sees it. /keep off lets it go."

  def kept(false), do: "Let go from the top: it is listed by when it was last active."

  @doc "The wire method for keeping a session at the top (`true`) or letting it go."
  @spec keep_method(boolean()) :: String.t()
  def keep_method(true), do: "session.pin"
  def keep_method(false), do: "session.unpin"

  @doc "What `/keep` names after the command: nothing to keep it, `off` to let it go."
  @spec keep_args(String.t()) :: {:ok, boolean()} | {:error, String.t()}
  def keep_args(args) do
    case String.trim(args) do
      "" -> {:ok, true}
      "off" -> {:ok, false}
      other -> {:error, "unknown /keep #{other}; use /keep or /keep off"}
    end
  end

  @doc "What a person who is not the session's owner is told when they try."
  @spec not_owner(:rename | :keep) :: String.t()
  def not_owner(:rename), do: "only the session's owner can rename it"
  def not_owner(:keep), do: "only the session's owner can keep it at the top"

  @doc "What a `forbidden` answer says, from its `data`: whose it is, or the reason given."
  @spec forbidden(map() | nil, :rename | :keep) :: String.t()
  def forbidden(%{"required_role" => "owner"}, what), do: not_owner(what)
  def forbidden(%{"reason" => reason}, _what) when is_binary(reason), do: reason
  def forbidden(_data, what), do: not_owner(what)
end
