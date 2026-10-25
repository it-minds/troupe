defmodule Troupe.Client.Steering do
  @moduledoc """
  A session offered to the plane for steering from another device (root #58), in the
  sentences `/steer` says: whether it is offered, to whom, whether the plane has it now,
  and who is steering it from elsewhere. The desktop app says the same.

  A private session is offered only after its person says yes to its passing through the
  plane unsealed while it is (root #765): `/steer on` asks it in the words every client
  shows (`consent_question/0`), drawn in the colour that means a person is needed, and
  `/steer on yes` offers it.
  """

  # The daemon's own words (its refusal carries them), which the desktop app says too; the
  # terminal keeps a copy, since it reaches the harness only through the daemon.
  @private_consent "This session is private: while it is offered, what it says and does passes " <>
                     "through the plane unsealed, and the plane relays it to whoever you invited " <>
                     "with control. The plane keeps none of it. Offer it?"

  @doc "What `/steer` says of a session's offer, as the daemon's `session.get` has it."
  @spec line(map() | nil) :: String.t()
  def line(nil),
    do: "Not offered to the plane. /steer on offers it, to steer it from another device."

  def line(%{} = remote) do
    [said(remote), steering(remote["steering"])]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  @doc """
  The sentence for an offer just made, and once, where nothing starts the daemon at login,
  what keeps it offered after a restart.
  """
  @spec offered(map() | nil) :: String.t()
  def offered(nil), do: line(nil)

  def offered(%{} = remote) do
    if remote["lasts"] == "until_restart",
      do: said(remote) <> " " <> restart_sentence(),
      else: said(remote)
  end

  defp said(%{"private" => true} = remote) do
    "Offered to the plane, private#{shared(remote["shares"])} (#{state(remote)}): what it says " <>
      "passes through the plane unsealed while it is offered. /steer off withdraws it and " <>
      "keeps it sealed only."
  end

  defp said(remote),
    do:
      "Offered to the plane#{shared(remote["shares"])} (#{state(remote)}). /steer off withdraws it."

  @doc """
  What `/steer on` asks of a private session's person before it is offered: the daemon's
  refusal says it needs this yes, and `/steer on yes` gives it.
  """
  @spec consent_question() :: String.t()
  def consent_question,
    do: @private_consent <> " /steer on yes offers it; anything else keeps it sealed only."

  @doc "The sentence the daemon refuses an offer of a private session with until its yes."
  @spec private_consent() :: String.t()
  def private_consent, do: @private_consent

  @doc "Whether a notice is the question above, which is drawn as a person being needed."
  @spec asks?(term()) :: boolean()
  def asks?(text) when is_binary(text), do: String.starts_with?(text, @private_consent)
  def asks?(_text), do: false

  @doc """
  The yes `/steer on yes` gives, taken off the words that follow it: `{"private", rest}`,
  or `{nil, words}` for none.
  """
  @spec consent(String.t()) :: {String.t() | nil, String.t()}
  def consent(words) do
    case String.split(String.trim(words), [" ", ","], parts: 2, trim: true) do
      ["yes" | rest] -> {"private", Enum.join(rest)}
      _other -> {nil, words}
    end
  end

  @doc """
  What `/steer on` says once of an offer that lasts until this machine restarts. The
  desktop app says the same.
  """
  @spec restart_sentence() :: String.t()
  def restart_sentence,
    do:
      "It stays offered until this machine restarts: troupe-daemon login on starts the " <>
        "daemon when you log in, and the offer comes back with it."

  @doc """
  An offer's state in words: whether the plane has it, then whether it came back after a
  restart or lasts only until one. The desktop app's *Offered* pill says the same.
  """
  @spec state(map()) :: String.t()
  def state(%{} = remote) do
    [
      presence(remote),
      remote["restored"] == true && "back after a restart",
      remote["lasts"] == "until_restart" && "until this machine restarts"
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(", ")
  end

  @doc """
  The people `/steer on` names: each `email` steers it, `email:observe` only follows it.
  A word that is neither a person nor a role is refused, saying which.
  """
  @spec share(String.t()) :: {:ok, [map()]} | {:error, String.t()}
  def share(text) do
    text
    |> String.split([",", " "], trim: true)
    |> Enum.reduce_while({:ok, []}, fn word, {:ok, acc} ->
      case String.split(word, ":", parts: 2) do
        [person] ->
          {:cont, {:ok, acc ++ [%{"person" => person, "role" => "control"}]}}

        [person, role] when role in ["observe", "control"] and person != "" ->
          {:cont, {:ok, acc ++ [%{"person" => person, "role" => role}]}}

        _ ->
          {:halt,
           {:error,
            "#{word}: name a person as an email, and add :observe for one who only follows it"}}
      end
    end)
  end

  defp shared([]), do: ", for you alone"
  defp shared(nil), do: ", for you alone"

  defp shared(shares) when is_list(shares) do
    names =
      Enum.map(shares, fn s ->
        name = s["email"] || s["display_name"] || s["subject"]
        if s["role"] == "observe", do: "#{name} to follow", else: name
      end)

    ", shared with " <> Enum.join(names, ", ")
  end

  defp presence(%{"state" => "online"}), do: "online"
  defp presence(%{"state" => "connecting"}), do: "connecting to the plane"
  defp presence(%{"since" => since}) when is_binary(since), do: "offline since #{since}"
  defp presence(_remote), do: "offline"

  defp steering(list) when is_list(list) and list != [] do
    case Enum.map(list, &(&1["display_name"] || &1["subject"])) do
      [one] -> "#{one} is steering it from another device."
      names -> Enum.join(names, ", ") <> " are steering it from other devices."
    end
  end

  defp steering(_none), do: nil
end
