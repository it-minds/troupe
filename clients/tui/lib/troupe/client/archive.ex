defmodule Troupe.Client.Archive do
  @moduledoc """
  A session archived by its owner, in the sentences `/archive` and `/unarchive` say,
  whichever side the session lives on. Archived, it is hidden from the session list for
  everyone who can see it and kept whole; anybody who could open it still can, and only
  `/unarchive` brings it back to the list: work in it does not.
  """

  @doc "The sentence for a session just archived (`true`) or brought back (`false`)."
  @spec said(boolean()) :: String.t()
  def said(true) do
    "Archived: it sleeps, kept whole, and is hidden from the session list for everyone " <>
      "who can see it. It stays open here; /sessions archived lists it, /unarchive brings it back."
  end

  def said(false), do: "Unarchived: it is back in the session list."

  @doc "What a person who is not the session's owner is told when they try."
  @spec not_owner(boolean()) :: String.t()
  def not_owner(true), do: "only the session's owner can archive it"
  def not_owner(false), do: "only the session's owner can unarchive it"

  @doc """
  What a `forbidden` answer to an archive says, from its `data`: the owner's refusal names
  whose it is to archive; one for another reason, such as a pod session's being the
  plane's to archive, says that reason.
  """
  @spec forbidden(map() | nil, boolean()) :: String.t()
  def forbidden(%{"required_role" => "owner"}, archived?), do: not_owner(archived?)
  def forbidden(%{"reason" => reason}, _archived?) when is_binary(reason), do: reason
  def forbidden(_data, archived?), do: not_owner(archived?)

  @doc "The wire method for archiving (`true`) or bringing back (`false`)."
  @spec method(boolean()) :: String.t()
  def method(true), do: "session.archive"
  def method(false), do: "session.unarchive"
end
