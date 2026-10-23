defmodule Troupe.Keyring.Steering do
  @moduledoc """
  The daemon's own sign-in for steering a laptop session from another device (#58), as
  the operating system's credential store keeps it (`Troupe.Keyring`).

  One entry per state directory, `steering-<hash of the directory>`, so a second daemon
  with homes of its own (a test, a scratch install) keeps a sign-in of its own. Its value
  is the plane, the person and the grant the plane gave this device, as base64 of JSON:
  printable, so every platform's tool takes it as it is.

  `Troupe.Gateway.Remote` writes it at the first offer and deletes it when the last is
  withdrawn or the person signs out. `forget/3` is the same delete from outside a running
  daemon, for `troupe logout` when none runs: a daemon that starts later must not offer
  again for somebody who signed out.
  """

  alias Troupe.Keyring

  @type t :: %{url: String.t(), subject: String.t(), grant: String.t()}

  @doc "The entry's name for a state directory, this daemon's by default."
  @spec name(Path.t()) :: String.t()
  def name(state_dir \\ Troupe.Paths.state_dir()) do
    hash =
      :crypto.hash(:sha256, Path.expand(state_dir))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 12)

    "steering-" <> hash
  end

  @doc "The sign-in kept under `name`, `:none`, or why the store could not say."
  @spec read(String.t()) :: {:ok, t()} | :none | {:error, term()}
  def read(name) do
    with {:ok, text} <- Keyring.get(name) do
      with {:ok, json} <- Base.url_decode64(text, padding: false),
           {:ok, %{"plane_url" => url, "subject" => subject, "grant" => grant}}
           when is_binary(url) and is_binary(subject) and is_binary(grant) <- Jason.decode(json) do
        {:ok, %{url: url, subject: subject, grant: grant}}
      else
        _unreadable -> {:error, :unreadable}
      end
    end
  end

  @doc "Keeps the sign-in under `name`, replacing what was there."
  @spec write(String.t(), t()) :: :ok | {:error, term()}
  def write(name, %{url: url, subject: subject, grant: grant}) do
    json = Jason.encode!(%{"plane_url" => url, "subject" => subject, "grant" => grant})
    Keyring.put(name, Base.url_encode64(json, padding: false))
  end

  @doc "Takes the sign-in out of the store."
  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(name), do: Keyring.delete(name)

  @doc """
  Takes the sign-in out of the store where it is for `plane_url` and `subject` (nil is
  whoever it is for), answering it where it was, so the caller can release its grant at
  the plane, and `:none` otherwise.
  """
  @spec forget(String.t(), String.t() | nil, String.t()) :: {:ok, t()} | :none | {:error, term()}
  def forget(plane_url, subject, name \\ name()) do
    with {:ok, sign_in} <- read(name),
         true <- (same_plane?(sign_in.url, plane_url) and subject in [nil, sign_in.subject]) || :none,
         :ok <- delete(name) do
      {:ok, sign_in}
    end
  end

  defp same_plane?(a, b), do: String.trim_trailing(a, "/") == String.trim_trailing(b, "/")
end
