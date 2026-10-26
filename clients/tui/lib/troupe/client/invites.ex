defmodule Troupe.Client.Invites do
  @moduledoc """
  A person invited into a session by name (root #765), in the sentences `/invite` and
  `/uninvite` say: whom it is shared with and at what, an invitation made, one taken back.
  The desktop app says the same in a session's head.
  """

  @doc "What `/invite` alone says of a session's invitations, as `session.invites` lists them."
  @spec line([map()]) :: String.t()
  def line([]),
    do: "Shared with nobody by name. /invite <email> [observe|control] invites somebody."

  def line(invites) when is_list(invites) do
    "Shared with " <>
      Enum.map_join(invites, ", ", &"#{name(&1)} (#{role_words(&1["role"])})") <> "."
  end

  @doc "The sentence for an invitation just made."
  @spec invited(map(), String.t()) :: String.t()
  def invited(answer, role) do
    who = answer |> Map.get("invite", %{}) |> then(&(&1 && name(&1))) || "them"
    verb = if role == "control", do: "steer", else: "follow"

    "Invited #{who} to #{verb} it: they see it in their list. /uninvite #{subject(answer) || who} takes it back."
  end

  @doc "The sentence for an invitation taken back, and for a private session whether it is sealed forward yet."
  @spec uninvited(map(), String.t()) :: String.t()
  def uninvited(answer, person) do
    who = answer["subject"] || person

    case answer["rekey_due"] do
      true ->
        "Took back #{who}'s invitation. What follows is sealed under a new key once this " <>
          "computer can reach the key manager and the plane; what they read before stays read."

      false ->
        if answer["key_version"],
          do:
            "Took back #{who}'s invitation: what follows is sealed under a new key they are " <>
              "never given, and what they read before stays read.",
          else: "Took back #{who}'s invitation: their open views close."

      _ ->
        "Took back #{who}'s invitation: their open views close."
    end
  end

  @doc """
  What `/invite` names: a person and, after them, `observe` (the default) or `control`.
  Anything else after the person is refused, saying which.
  """
  @spec parse(String.t()) :: {:ok, String.t(), String.t()} | {:error, String.t()}
  def parse(text) do
    case String.split(text, ~r/\s+/, trim: true) do
      [person] ->
        {:ok, person, "observe"}

      [person, role] when role in ["observe", "control"] ->
        {:ok, person, role}

      [_person, other] ->
        {:error, "/invite <email> observe or /invite <email> control: not #{other}"}

      _ ->
        {:error, "/invite <email> [observe|control] invites one person at a time"}
    end
  end

  defp name(%{} = person), do: person["display_name"] || person["email"] || person["subject"]
  defp subject(%{"invite" => %{"subject" => subject}}), do: subject
  defp subject(_answer), do: nil

  defp role_words("control"), do: "steers"
  defp role_words(_observe), do: "follows"
end
